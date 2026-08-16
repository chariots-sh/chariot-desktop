import Foundation
import CryptoKit
import AgentLinkKit

/// Registry of paired mobile devices plus the active session epoch.
struct DeviceRegistry: Codable {
    struct Entry: Codable {
        var identity: PublicDeviceIdentity
        var displayName: String
        var pairedAt: Date
        var revokedAt: Date?
        var lastOutboundSequence: UInt64
    }
    var epoch: UInt32 = 1
    var devices: [Entry] = []
}

/// Central Mac-side coordinator: owns the Mac identity, pairing sessions, the
/// tailnet node, the WebSocket transport service, and the VM/agent bridge.
/// Both the SwiftUI app and the headless daemon drive everything through this
/// type.
///
/// Transport layout: a loopback-only HTTP/WebSocket service carries pairing
/// and the encrypted message protocol. In production the bundled agent-tailnet
/// helper exposes that service on the Mac's Tailscale node (TCP 443, TLS) and
/// proxies to loopback; the development harness connects to loopback directly.
/// Admin/diagnostic endpoints live on a second, never-proxied loopback server.
public final class ChariotHub: @unchecked Sendable {
    public let paths: ChariotPaths
    public let backend: VirtualMachineBackend
    let mailbox: MailboxStore
    private var transportServer: HTTPServer?
    private var adminServer: HTTPServer?
    public private(set) var transportPort: UInt16 = 0
    public private(set) var adminPort: UInt16 = 0

    let identity: DeviceIdentity
    public var macDisplayName: String
    private var registry: DeviceRegistry
    private let lock = NSRecursiveLock()

    /// Feature flag `tailscale_transport`: when true (the default), pairing QR
    /// codes carry the tailnet service URL and require the embedded node to be
    /// authenticated. When false the hub runs in loopback development mode.
    /// Temporary migration/rollback control (env `CHARIOT_TAILSCALE=0`).
    public var tailscaleEnabled: Bool =
        (ProcessInfo.processInfo.environment["CHARIOT_TAILSCALE"] ?? "1") != "0"
    public private(set) var tailnet: TailnetSupervisor?

    // Pairing sessions keyed by single-use pairing ID.
    private struct PairingSession {
        let payload: PairingPayload
        let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
        var state: String  // "waiting" | "responded" | "consumed" | "expired"
        var pairingKey: SymmetricKey?
        var encryptedCredential: Data?
    }
    private var pairingSessions: [String: PairingSession] = [:]

    /// Approve new devices without UI (used by the daemon; the app can set
    /// this false and approve interactively).
    public var autoApprovePairing = true
    public var onDeviceApprovalRequest: (@Sendable (PairingResponse, @escaping @Sendable (Bool) -> Void) -> Void)?
    public var onEvent: (@Sendable (String) -> Void)?
    let eventBuffer = EventBuffer()

    /// All hub events flow through here: kept in a ring buffer for the
    /// /admin/events diagnostics endpoint and forwarded to the UI callback.
    func event(_ message: String) {
        eventBuffer.append(message)
        onEvent?(message)
    }

    /// External diagnostics (e.g. tailnet status changes surfaced by the app).
    public func note(_ message: String) {
        event(message)
    }

    // Live WebSocket sessions, one per authenticated device.
    private final class WSSession {
        let connection: WebSocketConnection
        let nonce: String
        var deviceID: String?
        var instanceID: String?
        init(connection: WebSocketConnection, nonce: String) {
            self.connection = connection
            self.nonce = nonce
        }
    }
    private var wsSessions: [ObjectIdentifier: WSSession] = [:]
    private var wsByDevice: [String: ObjectIdentifier] = [:]
    private var statusTimer: DispatchSourceTimer?

    // Active VM/bridge.
    public private(set) var activeInstance: SandboxID?
    private var bridge: BridgeClient?
    private var developerAccess: DeveloperAccess?
    public private(set) var lastGuestStatus: (state: String, kernel: String, hostname: String)?

    // Codex agent state + brokered login (design §3.1).
    public private(set) var agentStatus: AgentRuntimeStatus?
    private var loginTunnel: VsockPortForwarder?
    private var pendingAuthURLWaiters: [(String) -> Void] = []
    /// UI hook: called with the auth URL so the app can open the browser.
    public var onOAuthRequest: (@Sendable (String) -> Void)?

    // Streaming state: conversation → destination phone + batching buffer.
    private struct Stream {
        var recipientDeviceID: String
        var buffer: String = ""
        var flushScheduled = false
    }
    private var streams: [String: Stream] = [:]  // key: requestID
    private var replayWindows: [String: ReplayWindow] = [:]
    private var localStreams: [String: (@Sendable (String) -> Void, @Sendable (Int) -> Void)] = [:]
    private let flushQueue = DispatchQueue(label: "chariot.hub.flush")

    private var registryURL: URL { paths.identityDirectory.appendingPathComponent("devices.json") }

    public init(paths: ChariotPaths, displayName: String = Host.current().localizedName ?? "Mac") throws {
        self.paths = paths
        try paths.ensureDirectories()
        self.backend = VirtualMachineBackend(paths: paths)
        self.mailbox = MailboxStore(directory: paths.mailboxDirectory)
        self.macDisplayName = displayName

        // Identity: production stores this in the macOS Keychain (design §3.1);
        // the sample persists it as a 0600 file so the ad-hoc-signed daemon and
        // app can share it without keychain ACL prompts.
        let identityURL = paths.identityDirectory.appendingPathComponent("mac-identity.json")
        if let data = try? Data(contentsOf: identityURL),
           let stored = try? JSONDecoder().decode(DeviceIdentity.Stored.self, from: data),
           let loaded = try? DeviceIdentity(stored: stored) {
            self.identity = loaded
        } else {
            let created = DeviceIdentity()
            let data = try JSONEncoder().encode(created.stored())
            try data.write(to: identityURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
            self.identity = created
        }

        let registryFile = paths.identityDirectory.appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: registryFile),
           let loaded = try? CanonicalCoding.decoder().decode(DeviceRegistry.self, from: data) {
            self.registry = loaded
        } else {
            self.registry = DeviceRegistry()
        }

        // Phone-bound envelopes stay durably queued here until acknowledged;
        // a live WebSocket session gets them pushed immediately on deposit.
        mailbox.onDeposit = { [weak self] envelope in
            self?.pushEnvelopeIfConnected(envelope)
        }
    }

    private func persistRegistry() {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(registry) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    public var macPublicIdentity: PublicDeviceIdentity { identity.publicIdentity }
    public var currentEpoch: UInt32 { registry.epoch }

    public func pairedDevices() -> [(id: String, name: String, pairedAt: Date, revoked: Bool, fingerprint: String)] {
        lock.lock(); defer { lock.unlock() }
        return registry.devices.map {
            ($0.identity.deviceID, $0.displayName, $0.pairedAt, $0.revokedAt != nil, $0.identity.fingerprint)
        }
    }

    // MARK: Tailscale node

    /// Start supervising the bundled agent-tailnet helper. One node per app
    /// installation; all sandbox instances share it.
    public func enableTailscale(helperURL: URL) {
        guard tailscaleEnabled else {
            event("tailscale_transport flag off — loopback development mode")
            return
        }
        guard transportPort != 0 else {
            event("transport server must start before the tailnet helper")
            return
        }
        let supervisor = TailnetSupervisor(helperURL: helperURL,
                                           dataDirectory: paths.dataDirectory,
                                           identityDirectory: paths.identityDirectory,
                                           upstreamPort: transportPort)
        supervisor.onEvent = { [weak self] message in self?.event(message) }
        supervisor.onStatusChange = { [weak self] status in
            self?.event("tailnet: \(status.label)")
        }
        tailnet = supervisor
        supervisor.start()
    }

    public var tailnetStatus: TailnetStatus { tailnet?.status ?? .stopped }

    // MARK: VM lifecycle

    public func ensureInstance(configuration: SandboxConfiguration) async throws -> SandboxID {
        if let existing = backend.existingInstanceIDs().first {
            activeInstance = existing
            return existing
        }
        let id = try await backend.create(configuration: configuration)
        activeInstance = id
        return id
    }

    public func startVM() async throws {
        guard let id = activeInstance else { throw ChariotError.invalidState("no instance") }
        try await backend.start(id)
        try await connectBridge()
    }

    public func stopVM() async throws {
        guard let id = activeInstance else { return }
        bridge?.close()
        bridge = nil
        developerAccess?.disable()
        loginTunnel?.stop()
        loginTunnel = nil
        try await backend.stop(id)
    }

    public func resetVM() async throws {
        guard let id = activeInstance else { throw ChariotError.invalidState("no instance") }
        bridge?.close()
        bridge = nil
        developerAccess?.disable()
        loginTunnel?.stop()
        loginTunnel = nil
        agentStatus = nil  // Reset wipes the disk: Codex returns signed out.
        try await backend.reset(id)
    }

    public func restartVM() async throws {
        try await stopVM()
        try await startVM()
    }

    public var vmState: SandboxState {
        guard let id = activeInstance else { return .notCreated }
        return backend.state(of: id)
    }

    public var bridgeConnected: Bool { bridge != nil }

    private func connectBridge() async throws {
        guard let id = activeInstance else { throw ChariotError.invalidState("no instance") }
        let controller = try backend.controller(for: id)
        event("waiting for guest bridge…")
        let connection = try await controller.connectSocket(port: 1024)
        bridge = BridgeClient(connection: connection) { [weak self] event in
            self?.handleBridgeEvent(event)
        }
        event("guest bridge connected")
    }

    // MARK: Codex sign-in (design §3.1 brokered browser flow)

    /// Start the guest's `codex login` and the localhost:1455 → vsock:1022
    /// callback tunnel. The auth URL arrives via `.oauthRequested`.
    public func startCodexLogin() throws {
        guard let bridge else { throw ChariotError.bridgeUnavailable("sandbox not running") }
        guard let id = activeInstance else { throw ChariotError.invalidState("no instance") }
        if loginTunnel == nil {
            let controller = try backend.controller(for: id)
            loginTunnel = VsockPortForwarder(controller: controller, listenPort: 1455, vsockPort: 1022)
        }
        try loginTunnel?.start()
        try bridge.startLogin()
        event("codex sign-in started; waiting for auth URL from guest")
    }

    public func cancelCodexLogin() {
        try? bridge?.cancelLogin()
        loginTunnel?.stop()
        loginTunnel = nil
    }

    /// Await the next auth URL (admin/testing convenience).
    func waitForAuthURL(timeout: TimeInterval, completion: @escaping (String?) -> Void) {
        lock.lock()
        pendingAuthURLWaiters.append(completion)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // If still pending, fire nil (waiters cleared on delivery).
            let stillWaiting = !self.pendingAuthURLWaiters.isEmpty
            if stillWaiting { self.pendingAuthURLWaiters.removeAll() }
            self.lock.unlock()
            if stillWaiting { completion(nil) }
        }
    }

    // MARK: Developer access (design §1.5)

    public func enableDeveloperAccess() throws -> (port: UInt16, command: String, instructions: String) {
        guard let id = activeInstance else { throw ChariotError.invalidState("no instance") }
        let controller = try backend.controller(for: id)
        let instance = InstancePaths(directory: paths.instanceDirectory(id))
        if developerAccess == nil {
            developerAccess = DeveloperAccess(controller: controller, instance: instance)
        }
        let info = try developerAccess!.enable()
        event("developer access unlocked on 127.0.0.1:\(info.port)")
        return (info.port, info.command, info.codexInstructions)
    }

    public func disableDeveloperAccess() {
        developerAccess?.disable()
        developerAccess = nil
    }

    // MARK: Local conversation (Mac UI → agent)

    public func sendLocalPrompt(_ text: String, conversationID: String = "local",
                                onDelta: @escaping @Sendable (String) -> Void,
                                onCompleted: @escaping @Sendable (Int) -> Void) throws {
        guard let bridge else { throw ChariotError.bridgeUnavailable("not connected") }
        let requestID = UUID().uuidString.lowercased()
        lock.lock()
        localStreams[requestID] = (onDelta, onCompleted)
        lock.unlock()
        try bridge.sendConversation(requestID: requestID, conversationID: conversationID, text: text)
    }

    public func cancelConversation(_ conversationID: String) {
        try? bridge?.cancel(conversationID: conversationID)
    }

    // MARK: Pairing

    public var currentInstanceID: String { activeInstance ?? "default" }

    public func startPairingSession() throws -> PairingPayload {
        guard transportPort != 0 else { throw ChariotError.invalidState("transport not started") }

        let serviceURL: String
        let tlsPin: String?
        if tailscaleEnabled {
            guard let info = tailnet?.info else {
                throw ChariotError.invalidState(
                    "Tailscale is not connected yet — sign in to Tailscale first, then pair")
            }
            // The MagicDNS name comes from authenticated Tailscale state only.
            serviceURL = info.serviceURL
            tlsPin = info.tailscaleTLS ? nil : info.tlsPublicKeyHash
            if !info.tailscaleTLS && tlsPin == nil {
                throw ChariotError.invalidState("tailnet TLS not ready — try again in a moment")
            }
        } else {
            serviceURL = "http://127.0.0.1:\(transportPort)"
            tlsPin = nil
        }

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var secret = Data(count: 32)
        secret.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let payload = PairingPayload(
            serviceURL: serviceURL,
            instanceID: currentInstanceID,
            macDeviceID: identity.deviceID,
            macDisplayName: macDisplayName,
            macSigningPublicKey: identity.signingKey.publicKey.rawRepresentation,
            macPairingPublicKey: ephemeral.publicKey.rawRepresentation,
            tlsPublicKeyHash: tlsPin,
            pairingID: UUID().uuidString.lowercased(),
            pairingSecret: secret,
            expiresAt: Date().addingTimeInterval(120)
        )
        lock.lock()
        pairingSessions[payload.pairingID] = PairingSession(payload: payload, ephemeralKey: ephemeral, state: "waiting")
        lock.unlock()
        event("pairing session \(payload.pairingID.prefix(8)) created (\(serviceURL))")
        return payload
    }

    func pairingSessionState(_ pairingID: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return pairingSessions[pairingID]?.state ?? "unknown"
    }

    enum PairingRejection: Error {
        case unknown, replay, expired, invalid
        var status: Int {
            switch self {
            case .unknown: return 404
            case .replay: return 409
            case .expired: return 410
            case .invalid: return 400
            }
        }
        var message: String {
            switch self {
            case .unknown: return "unknown pairing id"
            case .replay: return "pairing session already claimed"
            case .expired: return "pairing session expired"
            case .invalid: return "invalid pairing response"
            }
        }
    }

    /// Validate a phone's pairing response. Claiming the single-use pairing ID
    /// is atomic: the session leaves `waiting` under the lock before any
    /// crypto runs, so a second claim — or a replayed QR — always fails.
    func acceptPairingResponse(pairingID: String, phoneEphemeral: Data,
                               ciphertext: Data) -> Result<Void, PairingRejection> {
        lock.lock()
        guard var session = pairingSessions[pairingID] else {
            lock.unlock()
            return .failure(.unknown)
        }
        guard session.state == "waiting" else {
            lock.unlock()
            return .failure(.replay)  // QR replay rejection
        }
        guard session.payload.expiresAt > Date() else {
            pairingSessions[pairingID]?.state = "expired"
            lock.unlock()
            return .failure(.expired)
        }
        // Atomic consume: no other claim can proceed past this point.
        session.state = "responded"
        pairingSessions[pairingID] = session
        lock.unlock()

        do {
            let key = try PairingCrypto.deriveKey(ephemeralPrivate: session.ephemeralKey,
                                                  peerEphemeralPublic: phoneEphemeral,
                                                  pairingSecret: session.payload.pairingSecret)
            let response = try PairingCrypto.open(PairingResponse.self, combined: ciphertext, key: key)
            try response.verifySignature()
            guard response.mobileEphemeralPublicKey == phoneEphemeral else {
                throw AgentLinkError.signatureInvalid  // outer/inner ephemeral mismatch
            }
            session.pairingKey = key
            lock.lock()
            pairingSessions[pairingID] = session
            lock.unlock()

            let approve: @Sendable (Bool) -> Void = { [weak self] approved in
                self?.completePairing(pairingID: pairingID, response: response, approved: approved)
            }
            event("pairing response from \(response.mobileDisplayName) accepted; awaiting approval")
            if autoApprovePairing {
                approve(true)
            } else if let ask = onDeviceApprovalRequest {
                ask(response, approve)
            } else {
                approve(false)
            }
            return .success(())
        } catch {
            // The single-use ID stays burned even on a bad response.
            lock.lock()
            pairingSessions[pairingID]?.state = "consumed"
            lock.unlock()
            event("pairing response rejected: \(error)")
            return .failure(.invalid)
        }
    }

    private func completePairing(pairingID: String, response: PairingResponse, approved: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var session = pairingSessions[pairingID], let key = session.pairingKey else { return }
        guard approved else {
            session.state = "consumed"
            pairingSessions[pairingID] = session
            event("pairing rejected by user")
            return
        }
        var credential = DeviceCredential(mac: identity.publicIdentity, mobile: response.mobile)
        do {
            try credential.sign(with: identity.signingKey)
            session.encryptedCredential = try PairingCrypto.seal(credential, key: key)
        } catch {
            event("credential issuance failed: \(error)")
            return
        }
        session.state = "consumed"
        pairingSessions[pairingID] = session

        registry.devices.removeAll { $0.identity.deviceID == response.mobile.deviceID }
        registry.devices.append(DeviceRegistry.Entry(identity: response.mobile,
                                                     displayName: response.mobileDisplayName,
                                                     pairedAt: Date(),
                                                     revokedAt: nil,
                                                     lastOutboundSequence: 0))
        persistRegistry()
        event("paired device \(response.mobileDisplayName) (\(response.mobile.fingerprint))")
    }

    /// Revoke a device: reject its credential and advance the session epoch so
    /// it cannot decrypt future envelopes (design §8.1). A signed
    /// `device.revoked` notice is sealed with the *old* epoch first — the last
    /// message the revoked device can still read — then any live WebSocket
    /// session is told and closed.
    public func revokeDevice(_ deviceID: String) {
        lock.lock()
        guard let index = registry.devices.firstIndex(where: { $0.identity.deviceID == deviceID }) else {
            lock.unlock()
            return
        }
        let peer = registry.devices[index].identity
        registry.devices[index].lastOutboundSequence += 1
        let sequence = registry.devices[index].lastOutboundSequence
        let oldEpoch = registry.epoch
        registry.devices[index].revokedAt = Date()
        registry.epoch += 1
        lock.unlock()
        persistRegistry()
        do {
            let notice = AgentMessage(conversationID: "control", senderDeviceID: identity.deviceID,
                                      sequence: sequence, type: .deviceRevoked,
                                      body: .object(["reason": .string("revoked by Mac user")]))
            let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: peer, epoch: oldEpoch)
            deliver(envelope: try session.seal(notice))
        } catch {
            event("revocation notice failed: \(error)")
        }
        // Tell the live session (if any) and drop it.
        lock.lock()
        let sessionID = wsByDevice[deviceID]
        let ws = sessionID.flatMap { wsSessions[$0]?.connection }
        lock.unlock()
        if let ws {
            sendFrame(TransportFrame(type: .revoked), over: ws)
            ws.close()
        }
        broadcastStatus()
        event("revoked device \(deviceID.prefix(8)); epoch advanced to \(registry.epoch)")
    }

    /// Queue an outbound envelope durably; a live session gets it immediately.
    /// Envelopes stay in the mailbox until the recipient acknowledges them.
    func deliver(envelope: EncryptedEnvelope) {
        mailbox.deposit(envelope)
    }

    private func deviceEntry(_ deviceID: String) -> DeviceRegistry.Entry? {
        lock.lock(); defer { lock.unlock() }
        return registry.devices.first { $0.identity.deviceID == deviceID }
    }

    // MARK: Envelope handling (phone → Mac)

    /// Decrypt, replay-check, and dispatch an inbound envelope. Returns true
    /// when the envelope should be acknowledged to the sender (processed now
    /// or a duplicate of something already processed).
    @discardableResult
    func processInboundEnvelope(_ envelope: EncryptedEnvelope) -> Bool {
        guard envelope.recipientDeviceID == identity.deviceID else { return false }
        guard let entry = deviceEntry(envelope.senderDeviceID), entry.revokedAt == nil else {
            event("dropped envelope from unknown/revoked device")
            return false
        }
        do {
            let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: entry.identity,
                                            epoch: registry.epoch)
            let message = try session.open(envelope)
            lock.lock()
            var window = replayWindows[envelope.senderDeviceID] ?? ReplayWindow()
            do {
                try window.accept(messageID: message.messageID, sequence: message.sequence)
            } catch AgentLinkError.replayDetected {
                lock.unlock()
                return true  // duplicate delivery — ack again, don't reprocess
            }
            replayWindows[envelope.senderDeviceID] = window
            lock.unlock()
            try handleAgentMessage(message, from: entry)
            return true
        } catch {
            event("envelope rejected: \(error)")
            return false
        }
    }

    private func handleAgentMessage(_ message: AgentMessage, from entry: DeviceRegistry.Entry) throws {
        switch message.type {
        case .conversationSend:
            let text = message.body["text"]?.stringValue ?? ""
            event("prompt from \(entry.displayName): \(text.prefix(80))")
            guard let bridge else {
                try sendToDevice(entry.identity.deviceID, type: .outputCompleted,
                                 conversationID: message.conversationID,
                                 body: .object(["exit_code": .number(-1),
                                                "error": .string("sandbox is not running")]))
                return
            }
            lock.lock()
            streams[message.messageID] = Stream(recipientDeviceID: entry.identity.deviceID)
            lock.unlock()
            try bridge.sendConversation(requestID: message.messageID,
                                        conversationID: message.conversationID,
                                        text: text)
        case .conversationCancel:
            try? bridge?.cancel(conversationID: message.conversationID)
        case .sandboxStatus:
            let status = lastGuestStatus
            try sendToDevice(entry.identity.deviceID, type: .sandboxStatus,
                             conversationID: message.conversationID,
                             body: .object([
                                "state": .string(vmState.rawValue),
                                "bridge": .bool(bridgeConnected),
                                "kernel": .string(status?.kernel ?? ""),
                                "hostname": .string(status?.hostname ?? "")
                             ]))
        default:
            event("unhandled message type \(message.type.rawValue) from phone")
        }
    }

    /// Seal and queue an outbound message for a paired device.
    func sendToDevice(_ deviceID: String, type: AgentMessageType, conversationID: String,
                      body: JSONValue) throws {
        lock.lock()
        guard let index = registry.devices.firstIndex(where: { $0.identity.deviceID == deviceID }),
              registry.devices[index].revokedAt == nil else {
            lock.unlock()
            throw ChariotError.notPaired
        }
        registry.devices[index].lastOutboundSequence += 1
        let sequence = registry.devices[index].lastOutboundSequence
        let peer = registry.devices[index].identity
        let epoch = registry.epoch
        lock.unlock()
        persistRegistry()

        let message = AgentMessage(conversationID: conversationID,
                                   senderDeviceID: identity.deviceID,
                                   sequence: sequence, type: type, body: body)
        let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: peer, epoch: epoch)
        deliver(envelope: try session.seal(message))
    }

    // MARK: Bridge events → streams

    private func handleBridgeEvent(_ bridgeEvent: BridgeEvent) {
        switch bridgeEvent {
        case .status(let state, _, let kernel, let hostname, let agent):
            lastGuestStatus = (state, kernel, hostname)
            if let agent {
                agentStatus = agent
                event("agent: \(agent.name) \(agent.version ?? "?") installed=\(agent.installed) signedIn=\(agent.loggedIn)")
            } else {
                event("guest status: \(state), kernel \(kernel)")
            }
            broadcastStatus()
        case .oauthRequested(let provider, let purpose, let authURL):
            event("oauth requested by guest (\(provider)): \(purpose)")
            lock.lock()
            let waiters = pendingAuthURLWaiters
            pendingAuthURLWaiters = []
            lock.unlock()
            waiters.forEach { $0(authURL) }
            onOAuthRequest?(authURL)
        case .oauthCompleted(let success, let message):
            event("codex sign-in \(success ? "succeeded" : "failed"): \(message)")
            if success {
                // Callback served; the tunnel has no further purpose.
                loginTunnel?.stop()
                loginTunnel = nil
            }
            try? bridge?.requestStatus()
        case .outputDelta(let requestID, _, let text):
            lock.lock()
            if let (onDelta, _) = localStreams[requestID] {
                lock.unlock()
                onDelta(text)
                return
            }
            if streams[requestID] != nil {
                streams[requestID]!.buffer += text
                let needsFlush = !streams[requestID]!.flushScheduled
                if needsFlush { streams[requestID]!.flushScheduled = true }
                lock.unlock()
                if needsFlush {
                    // Batch streamed tokens into chunked envelopes (design §4.6).
                    flushQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.flushStream(requestID: requestID, final: false)
                    }
                }
                return
            }
            lock.unlock()
        case .outputCompleted(let requestID, let conversationID, let exitCode):
            lock.lock()
            if let (_, onCompleted) = localStreams.removeValue(forKey: requestID) {
                lock.unlock()
                onCompleted(exitCode)
                return
            }
            lock.unlock()
            flushStream(requestID: requestID, final: true)
            lock.lock()
            let recipient = streams.removeValue(forKey: requestID)?.recipientDeviceID
            lock.unlock()
            if let recipient {
                try? sendToDevice(recipient, type: .outputCompleted, conversationID: conversationID,
                                  body: .object(["exit_code": .number(Double(exitCode)),
                                                 "request_id": .string(requestID)]))
            }
        case .pong:
            break
        case .error(let message):
            event("bridge error: \(message)")
        case .disconnected(let reason):
            event("bridge disconnected: \(reason)")
            bridge = nil
            // Reconnect while the VM is still running (e.g. guest service restart).
            if vmState == .running {
                Task { [weak self] in
                    try? await self?.connectBridge()
                }
            }
        }
    }

    private func flushStream(requestID: String, final: Bool) {
        lock.lock()
        guard var stream = streams[requestID] else { lock.unlock(); return }
        let text = stream.buffer
        stream.buffer = ""
        stream.flushScheduled = false
        streams[requestID] = stream
        lock.unlock()
        guard !text.isEmpty else { return }
        try? sendToDevice(stream.recipientDeviceID, type: .outputDelta, conversationID: "default",
                          body: .object(["text": .string(text), "request_id": .string(requestID)]))
    }

    // MARK: WebSocket transport sessions

    private func handleWebSocketUpgrade() -> HTTPServer.Response {
        return .upgrade { [weak self] connection in
            guard let self else { connection.close(); return }
            var nonce = Data(count: 24)
            nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 24, $0.baseAddress!) }
            let session = WSSession(connection: connection, nonce: Base64URL.encode(nonce))
            let id = ObjectIdentifier(connection)
            self.lock.lock()
            self.wsSessions[id] = session
            self.lock.unlock()

            connection.onText = { [weak self, weak connection] text in
                guard let self, let connection else { return }
                self.handleWSFrame(text: text, connection: connection)
            }
            connection.onClose = { [weak self, weak connection] in
                guard let self, let connection else { return }
                let id = ObjectIdentifier(connection)
                self.lock.lock()
                if let deviceID = self.wsSessions[id]?.deviceID,
                   self.wsByDevice[deviceID] == id {
                    self.wsByDevice.removeValue(forKey: deviceID)
                }
                self.wsSessions.removeValue(forKey: id)
                self.lock.unlock()
            }

            var challenge = TransportFrame(type: .challenge)
            challenge.nonce = session.nonce
            self.sendFrame(challenge, over: connection)
        }
    }

    private func handleWSFrame(text: String, connection: WebSocketConnection) {
        let id = ObjectIdentifier(connection)
        lock.lock()
        guard let session = wsSessions[id] else { lock.unlock(); return }
        let authenticatedDevice = session.deviceID
        lock.unlock()

        guard let frame = try? TransportFrame.decode(Data(text.utf8)) else {
            var error = TransportFrame(type: .error)
            error.message = "malformed frame"
            sendFrame(error, over: connection)
            return
        }

        // Tailnet membership is transport only — nothing is served before the
        // device proves possession of a paired signing key.
        guard let deviceID = authenticatedDevice else {
            handleWSHello(frame, session: sessionFor(connection), connection: connection)
            return
        }

        switch frame.type {
        case .envelope:
            guard let envelope = frame.envelope, envelope.senderDeviceID == deviceID else { return }
            if processInboundEnvelope(envelope) {
                var ack = TransportFrame(type: .ack)
                ack.messageIDs = [envelope.messageID]
                sendFrame(ack, over: connection)
            }
        case .ack:
            // Phone confirmed receipt: drop the envelopes from the durable queue.
            if let ids = frame.messageIDs {
                mailbox.acknowledge(recipient: deviceID, messageIDs: ids)
            }
        default:
            break
        }
    }

    private func sessionFor(_ connection: WebSocketConnection) -> WSSession? {
        lock.lock(); defer { lock.unlock() }
        return wsSessions[ObjectIdentifier(connection)]
    }

    private func handleWSHello(_ frame: TransportFrame, session: WSSession?, connection: WebSocketConnection) {
        guard let session else { connection.close(); return }
        guard frame.type == .hello,
              let deviceID = frame.deviceID,
              let signature = frame.signature,
              let instanceID = frame.instanceID else {
            sendFrame(TransportFrame(type: .denied), over: connection)
            connection.close()
            return
        }
        guard let entry = deviceEntry(deviceID), entry.revokedAt == nil else {
            // Revoked and unknown devices are distinguishable on purpose: the
            // phone shows "revoked" only when this Mac actually revoked it.
            if deviceEntry(deviceID) != nil {
                sendFrame(TransportFrame(type: .revoked), over: connection)
            } else {
                sendFrame(TransportFrame(type: .denied), over: connection)
            }
            connection.close()
            return
        }
        guard TransportAuth.verify(nonce: session.nonce, deviceID: deviceID, instanceID: instanceID,
                                   signature: signature,
                                   signingPublicKey: entry.identity.signingPublicKey) else {
            event("ws auth failed for device \(deviceID.prefix(8))")
            sendFrame(TransportFrame(type: .denied), over: connection)
            connection.close()
            return
        }

        lock.lock()
        session.deviceID = deviceID
        session.instanceID = instanceID
        // One live session per device: a reconnect supersedes the old socket.
        if let previous = wsByDevice[deviceID], previous != ObjectIdentifier(connection),
           let stale = wsSessions[previous]?.connection {
            stale.close()
        }
        wsByDevice[deviceID] = ObjectIdentifier(connection)
        let epoch = registry.epoch
        lock.unlock()

        var welcome = TransportFrame(type: .welcome)
        welcome.epoch = epoch
        welcome.macDeviceID = identity.deviceID
        sendFrame(welcome, over: connection)
        sendStatusFrame(over: connection)
        event("device \(entry.displayName) connected (instance \(instanceID))")

        // Replay everything still queued for this device; the phone acks and
        // deduplicates via its replay window.
        for stored in mailbox.fetch(recipient: deviceID, after: 0, limit: 500) {
            var envelopeFrame = TransportFrame(type: .envelope)
            envelopeFrame.envelope = stored.envelope
            sendFrame(envelopeFrame, over: connection)
        }
        startStatusTimerIfNeeded()
    }

    private func pushEnvelopeIfConnected(_ envelope: EncryptedEnvelope) {
        lock.lock()
        let connection = wsByDevice[envelope.recipientDeviceID].flatMap { wsSessions[$0]?.connection }
        lock.unlock()
        guard let connection else { return }
        var frame = TransportFrame(type: .envelope)
        frame.envelope = envelope
        sendFrame(frame, over: connection)
    }

    private func sendFrame(_ frame: TransportFrame, over connection: WebSocketConnection) {
        if let data = try? frame.encoded(), let text = String(data: data, encoding: .utf8) {
            connection.send(text: text)
        }
    }

    private func sendStatusFrame(over connection: WebSocketConnection) {
        var status = TransportFrame(type: .status)
        status.vmState = vmState.rawValue
        status.bridgeConnected = bridgeConnected
        lock.lock()
        status.epoch = registry.epoch
        lock.unlock()
        sendFrame(status, over: connection)
    }

    /// Push current sandbox status to every authenticated session.
    func broadcastStatus() {
        lock.lock()
        let connections = wsByDevice.values.compactMap { wsSessions[$0]?.connection }
        lock.unlock()
        connections.forEach { sendStatusFrame(over: $0) }
    }

    private func startStatusTimerIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard statusTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.broadcastStatus()
            // Envelopes a recipient can never decrypt anymore (old epoch)
            // age out instead of sitting in the queue forever.
            self?.mailbox.expireStale()
        }
        timer.resume()
        statusTimer = timer
    }

    // MARK: HTTP surfaces

    /// Start both servers: the transport surface (loopback; reached over the
    /// tailnet via agent-tailnet's TLS proxy) and the local-only admin surface
    /// (never proxied — one port up from the transport port by default).
    public func startTransportServer(port: UInt16 = 8787, adminPort requestedAdminPort: UInt16? = nil) throws {
        let transport = HTTPServer { [weak self] request in
            self?.routeTransport(request) ?? .error(500, "hub gone")
        }
        try transport.start(port: port)
        transportServer = transport
        transportPort = transport.port

        let admin = HTTPServer { [weak self] request in
            self?.routeAdmin(request) ?? .error(500, "hub gone")
        }
        try admin.start(port: requestedAdminPort ?? (transport.port &+ 1))
        adminServer = admin
        adminPort = admin.port
        event("transport on 127.0.0.1:\(transport.port), admin on 127.0.0.1:\(admin.port)")
    }

    /// Routes reachable through the tailnet proxy. Everything here is either
    /// public identity info, the self-protecting pairing handshake, or the
    /// authenticated WebSocket session — no admin controls.
    private func routeTransport(_ request: HTTPServer.Request) -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.first ?? "") {
        case ("GET", "status"):
            return .json([
                "mac_device_id": identity.deviceID,
                "mac_display_name": macDisplayName,
                "vm_state": vmState.rawValue,
                "bridge_connected": bridgeConnected,
                "epoch": Int(registry.epoch),
                "instance_id": currentInstanceID,
                "mode": tailscaleEnabled ? "tailscale" : "local"
            ])
        case ("GET", "v2") where parts.count == 2 && parts[1] == "ws":
            return handleWebSocketUpgrade()
        case ("GET", "pairing") where parts.count == 2:
            guard let session = pairingSessions[parts[1]] else { return .error(404, "unknown pairing id") }
            return .json([
                "state": session.state,
                "mac_device_id": session.payload.macDeviceID,
                "mac_display_name": session.payload.macDisplayName,
                "mac_signing_public_key": Base64URL.encode(session.payload.macSigningPublicKey),
                "mac_pairing_public_key": Base64URL.encode(session.payload.macPairingPublicKey),
                "expires_at": ISO8601DateFormatter().string(from: session.payload.expiresAt)
            ])
        case ("POST", "pairing") where parts.count == 3 && parts[2] == "response":
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let ephemeralB64 = object["ephemeral_public_key"],
                  let ciphertextB64 = object["ciphertext"],
                  let ephemeral = try? Base64URL.decode(ephemeralB64),
                  let ciphertext = try? Base64URL.decode(ciphertextB64) else {
                return .error(400, "malformed pairing response")
            }
            switch acceptPairingResponse(pairingID: parts[1], phoneEphemeral: ephemeral, ciphertext: ciphertext) {
            case .success: return .json(["state": "responded"])
            case .failure(let code): return .error(code.status, code.message)
            }
        case ("GET", "pairing") where parts.count == 3 && parts[2] == "credential":
            guard let session = pairingSessions[parts[1]] else { return .error(404, "unknown pairing id") }
            guard let credential = session.encryptedCredential else { return .error(404, "not issued yet") }
            return .json(["ciphertext": Base64URL.encode(credential), "epoch": Int(registry.epoch)])
        default:
            return .error(404, "not found")
        }
    }

    /// Local-only admin endpoints used by the E2E harness and the GUI. This
    /// server is never exposed through the tailnet proxy.
    private func routeAdmin(_ request: HTTPServer.Request) -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "admin" else { return .error(404, "not found") }
        let rest = Array(parts.dropFirst())
        switch (request.method, rest.first ?? "") {
        case ("POST", "pairing"):
            do {
                let payload = try startPairingSession()
                return .data(try CanonicalCoding.encode(payload))
            } catch {
                return .error(500, "\(error)")
            }
        case ("GET", "summary"):
            let devices = pairedDevices().map { device -> [String: Any] in
                ["id": device.id, "name": device.name, "revoked": device.revoked,
                 "fingerprint": device.fingerprint]
            }
            return .json([
                "vm_state": vmState.rawValue,
                "bridge_connected": bridgeConnected,
                "epoch": Int(registry.epoch),
                "devices": devices,
                "mac_fingerprint": identity.publicIdentity.fingerprint,
                "tailnet": tailnetStatus.label
            ])
        case ("POST", "revoke"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let deviceID = object["device_id"] else { return .error(400, "device_id required") }
            revokeDevice(deviceID)
            return .json(["revoked": deviceID])
        case ("GET", "events"):
            return .json(["events": eventBuffer.recent()])
        case ("GET", "sessions"):
            lock.lock()
            let sessions = pairingSessions.map { ["pairing_id": $0.key, "state": $0.value.state,
                                                  "has_credential": $0.value.encryptedCredential != nil] }
            lock.unlock()
            return .json(["sessions": sessions])
        case ("GET", "tailnet"):
            var payload: [String: Any] = ["status": tailnetStatus.label]
            if case .needsLogin(let url) = tailnetStatus { payload["auth_url"] = url }
            if let info = tailnet?.info {
                payload["dns_name"] = info.dnsName
                payload["service_url"] = info.serviceURL
                payload["tailscale_tls"] = info.tailscaleTLS
                if let expiry = info.keyExpiry {
                    payload["key_expiry"] = ISO8601DateFormatter().string(from: expiry)
                }
            }
            return .json(payload)
        case ("POST", "tailnet"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let action = object["action"] else { return .error(400, "action required") }
            guard let tailnet else { return .error(400, "tailscale not enabled") }
            switch action {
            case "start": tailnet.start()
            case "stop": tailnet.stop()
            case "logout": tailnet.logout()
            case "reset":
                do { try tailnet.reset() } catch { return .error(500, "\(error)") }
            default: return .error(400, "unknown action")
            }
            return .json(["status": tailnetStatus.label])
        case ("POST", "vm") where rest.count == 2:
            let action = rest[1]
            let semaphore = DispatchSemaphore(value: 0)
            let box = OutputCollector()
            Task {
                do {
                    switch action {
                    case "start":
                        _ = try await ensureInstance(configuration: SandboxConfiguration(
                            baseImagePath: ProcessInfo.processInfo.environment["CHARIOT_BASE_IMAGE"] ?? ""))
                        try await startVM()
                    case "stop": try await stopVM()
                    case "reset": try await resetVM()
                    default: box.append("unknown action")
                    }
                    box.append("ok")
                } catch {
                    box.append("error: \(error)")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 300)
            return .json(["result": box.text, "vm_state": vmState.rawValue])
        case ("GET", "agent"):
            return .json([
                "installed": agentStatus?.installed ?? false,
                "version": agentStatus?.version ?? "",
                "logged_in": agentStatus?.loggedIn ?? false,
                "install_error": agentStatus?.installError ?? ""
            ])
        case ("POST", "agent") where rest.count == 2 && rest[1] == "login":
            let semaphore = DispatchSemaphore(value: 0)
            let box = OutputCollector()
            waitForAuthURL(timeout: 25) { url in
                box.append(url ?? "")
                semaphore.signal()
            }
            do {
                try startCodexLogin()
            } catch {
                return .error(503, "\(error)")
            }
            _ = semaphore.wait(timeout: .now() + 30)
            return box.text.isEmpty ? .error(504, "no auth URL from guest")
                                    : .json(["auth_url": box.text])
        case ("POST", "devaccess"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let action = object["action"] else { return .error(400, "action required") }
            if action == "enable" {
                do {
                    let info = try enableDeveloperAccess()
                    return .json(["port": Int(info.port), "command": info.command,
                                  "instructions": info.instructions])
                } catch {
                    return .error(500, "\(error)")
                }
            } else {
                disableDeveloperAccess()
                return .json(["disabled": true])
            }
        case ("POST", "conversation"):
            // Synchronous local prompt for testing the bridge path.
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let text = object["text"] else { return .error(400, "text required") }
            let semaphore = DispatchSemaphore(value: 0)
            let collector = OutputCollector()
            do {
                try sendLocalPrompt(text, onDelta: { collector.append($0) },
                                    onCompleted: { code in collector.finish(code); semaphore.signal() })
            } catch {
                return .error(503, "\(error)")
            }
            if semaphore.wait(timeout: .now() + 120) == .timedOut {
                return .error(504, "agent timed out")
            }
            return .json(["output": collector.text, "exit_code": collector.exitCode])
        default:
            return .error(404, "not found")
        }
    }
}

final class EventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append("\(stamp) \(line)")
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func recent(_ count: Int = 50) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(count))
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""
    private var _exitCode = 0
    var text: String { lock.lock(); defer { lock.unlock() }; return _text }
    var exitCode: Int { lock.lock(); defer { lock.unlock() }; return _exitCode }
    func append(_ s: String) { lock.lock(); _text += s; lock.unlock() }
    func finish(_ code: Int) { lock.lock(); _exitCode = code; lock.unlock() }
}
