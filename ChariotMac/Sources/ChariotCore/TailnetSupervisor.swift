import Foundation

/// Observable state of the embedded Tailscale node, mapped from the helper's
/// structured events (never from log text).
public enum TailnetStatus: Equatable, Sendable {
    case stopped
    case launching
    case connecting
    case needsLogin(authURL: String)
    case ready(TailnetInfo)
    case keyExpired
    case error(String)

    public var label: String {
        switch self {
        case .stopped: return "stopped"
        case .launching: return "launching"
        case .connecting: return "connecting"
        case .needsLogin: return "needs login"
        case .ready: return "ready"
        case .keyExpired: return "key expired"
        case .error(let message): return "error: \(message)"
        }
    }
}

/// Facts about the authenticated node, taken from Tailscale state (the MagicDNS
/// name is never guessed or constructed from user input).
public struct TailnetInfo: Equatable, Sendable {
    public let dnsName: String
    public let tailnet: String
    /// True when the tailnet has HTTPS certificates enabled and the node
    /// serves a Tailscale-issued certificate; false means the helper serves
    /// the per-installation self-signed certificate pinned via the QR payload.
    public let tailscaleTLS: Bool
    /// Base64 SHA-256 of the self-signed certificate's SPKI (nil when
    /// Tailscale-issued TLS is in use).
    public let tlsPublicKeyHash: String?
    public let keyExpiry: Date?
    public let addresses: [String]

    public var serviceURL: String { "https://\(dnsName)" }
}

/// Supervises the bundled agent-tailnet helper: launches it, restarts it after
/// crashes with bounded exponential backoff, exchanges versioned NDJSON frames
/// over stdin/stdout, and exposes login/logout/reset controls. One helper —
/// one Tailscale identity — per app installation, shared by all sandboxes.
public final class TailnetSupervisor: @unchecked Sendable {
    public private(set) var status: TailnetStatus = .stopped
    public var onStatusChange: (@Sendable (TailnetStatus) -> Void)?
    public var onEvent: (@Sendable (String) -> Void)?

    private let helperURL: URL
    private let stateDirectory: URL
    private let hostnameFile: URL
    private let upstreamPort: UInt16
    private let lock = NSRecursiveLock()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var desired = false          // should the helper be running?
    private var restartAttempts = 0
    private var lastLaunch = Date.distantPast
    private var lineBuffer = Data()

    public init(helperURL: URL, dataDirectory: URL, identityDirectory: URL, upstreamPort: UInt16) {
        self.helperURL = helperURL
        self.stateDirectory = dataDirectory.appendingPathComponent("tailnet-state", isDirectory: true)
        self.hostnameFile = identityDirectory.appendingPathComponent("tailnet-hostname")
        self.upstreamPort = upstreamPort
    }

    /// Stable per-installation hostname, e.g. `agentbox-3f9c`. Persisted so the
    /// node keeps its identity across launches.
    public func hostname() -> String {
        if let existing = try? String(contentsOf: hostnameFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, 2, &bytes)
        let name = "agentbox-" + bytes.map { String(format: "%02x", $0) }.joined()
        try? name.write(to: hostnameFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hostnameFile.path)
        return name
    }

    public var info: TailnetInfo? {
        lock.lock(); defer { lock.unlock() }
        if case .ready(let info) = status { return info }
        return nil
    }

    // MARK: Lifecycle

    public func start() {
        lock.lock()
        desired = true
        restartAttempts = 0
        let alreadyRunning = process?.isRunning ?? false
        lock.unlock()
        guard !alreadyRunning else { return }
        launch()
    }

    public func stop() {
        lock.lock()
        desired = false
        let proc = process
        process = nil
        let stdin = stdinPipe
        stdinPipe = nil
        lock.unlock()
        if let stdin { sendCommand("shutdown", to: stdin) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc?.isRunning == true { proc?.terminate() }
        }
        setStatus(.stopped)
    }

    /// Log the node out of the tailnet (state directory is kept; Reauthenticate
    /// triggers a fresh interactive login URL).
    public func logout() {
        lock.lock()
        let stdin = stdinPipe
        lock.unlock()
        if let stdin { sendCommand("logout", to: stdin) }
    }

    /// Delete the local node identity entirely. The node disappears from the
    /// tailnet's device list only via the admin console; locally this requires
    /// a full re-authentication afterwards. Destructive — the UI warns first.
    public func reset() throws {
        lock.lock()
        let proc = process
        lock.unlock()
        stop()
        // Wait for the helper to actually exit so it cannot rewrite state
        // files after the delete.
        let deadline = Date().addingTimeInterval(3)
        while proc?.isRunning == true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc?.isRunning == true { proc?.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        if FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
        onEvent?("tailscale state deleted — node identity reset")
        start()
    }

    public func requestStatus() {
        lock.lock()
        let stdin = stdinPipe
        lock.unlock()
        if let stdin { sendCommand("status", to: stdin) }
    }

    // MARK: Process management

    private func launch() {
        lock.lock()
        guard desired else { lock.unlock(); return }
        lastLaunch = Date()
        lock.unlock()

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            setStatus(.error("agent-tailnet helper not found at \(helperURL.path)"))
            return
        }
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            setStatus(.error("cannot create tailnet state dir: \(error)"))
            return
        }

        let proc = Process()
        proc.executableURL = helperURL
        proc.arguments = [
            "--state-dir", stateDirectory.path,
            "--hostname", hostname(),
            "--upstream", "127.0.0.1:\(upstreamPort)",
            "--listen-port", "443"
        ]
        let stdout = Pipe()
        let stdin = Pipe()
        proc.standardOutput = stdout
        proc.standardInput = stdin
        proc.standardError = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.ingest(data) }
        }
        proc.terminationHandler = { [weak self] _ in
            self?.handleExit()
        }

        do {
            try proc.run()
        } catch {
            setStatus(.error("failed to launch helper: \(error)"))
            scheduleRestart()
            return
        }
        lock.lock()
        process = proc
        stdinPipe = stdin
        lock.unlock()
        setStatus(.launching)
        onEvent?("agent-tailnet launched (pid \(proc.processIdentifier))")
    }

    private func handleExit() {
        lock.lock()
        process = nil
        stdinPipe = nil
        let wantRestart = desired
        lock.unlock()
        guard wantRestart else {
            setStatus(.stopped)
            return
        }
        onEvent?("agent-tailnet exited unexpectedly")
        scheduleRestart()
    }

    private func scheduleRestart() {
        lock.lock()
        // A helper that stayed up for a while earns a fresh backoff ladder.
        if Date().timeIntervalSince(lastLaunch) > 120 { restartAttempts = 0 }
        restartAttempts += 1
        let delay = min(60.0, pow(2.0, Double(min(restartAttempts, 6))))
        lock.unlock()
        onEvent?("restarting agent-tailnet in \(Int(delay))s (attempt \(restartAttempts))")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launch()
        }
    }

    // MARK: NDJSON protocol

    private struct HelperEvent: Decodable {
        let v: Int
        let event: String
        let auth_url: String?
        let dns_name: String?
        let tailnet: String?
        let https: Bool?
        let tls_spki_sha256: String?
        let key_expiry: String?
        let addrs: [String]?
        let addr: String?
        let login: String?
        let node: String?
        let message: String?
    }

    private func ingest(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer.subdata(in: lineBuffer.startIndex..<newline))
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            guard let event = try? JSONDecoder().decode(HelperEvent.self, from: line), event.v == 1 else {
                onEvent?("unrecognized helper frame")
                continue
            }
            handle(event)
        }
    }

    private func handle(_ event: HelperEvent) {
        switch event.event {
        case "connecting":
            setStatus(.connecting)
        case "needs_login":
            if let url = event.auth_url, !url.isEmpty {
                setStatus(.needsLogin(authURL: url))
            }
        case "ready":
            lock.lock()
            restartAttempts = 0
            lock.unlock()
            let expiry = event.key_expiry.flatMap { ISO8601DateFormatter().date(from: $0) }
            let info = TailnetInfo(dnsName: event.dns_name ?? "",
                                   tailnet: event.tailnet ?? "",
                                   tailscaleTLS: event.https ?? false,
                                   tlsPublicKeyHash: (event.tls_spki_sha256?.isEmpty == false) ? event.tls_spki_sha256 : nil,
                                   keyExpiry: expiry,
                                   addresses: event.addrs ?? [])
            setStatus(.ready(info))
        case "key_expired":
            setStatus(.keyExpired)
        case "stopped":
            lock.lock()
            let wanted = desired
            lock.unlock()
            if !wanted { setStatus(.stopped) }
        case "peer":
            onEvent?("tailnet connection from \(event.node ?? event.addr ?? "?") (\(event.login ?? "unknown user"))")
        case "error":
            onEvent?("tailnet helper: \(event.message ?? "unknown error")")
        default:
            break
        }
    }

    private func sendCommand(_ cmd: String, to pipe: Pipe) {
        let frame = "{\"v\":1,\"cmd\":\"\(cmd)\"}\n"
        pipe.fileHandleForWriting.write(Data(frame.utf8))
    }

    private func setStatus(_ new: TailnetStatus) {
        lock.lock()
        let changed = status != new
        status = new
        lock.unlock()
        if changed { onStatusChange?(new) }
    }
}
