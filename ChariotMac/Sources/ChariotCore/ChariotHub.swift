import Foundation
import CryptoKit
import AgentLinkKit
import AgentLinkCloudKit

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

/// Central Mac-side coordinator: owns the Mac identity, pairing sessions,
/// the mailbox, and the VM/agent bridge. Both the SwiftUI app and the headless
/// daemon drive everything through this type.
public final class ChariotHub: @unchecked Sendable {
    public let paths: ChariotPaths
    public let backend: VirtualMachineBackend
    let mailbox: MailboxStore
    private var httpServer: HTTPServer?
    public private(set) var mailboxPort: UInt16 = 0

    let identity: DeviceIdentity
    public var macDisplayName: String
    private var registry: DeviceRegistry
    private let lock = NSRecursiveLock()

    // Pairing sessions keyed by rendezvous ID.
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

    /// External diagnostics (e.g. the app delegate's APNs callbacks).
    public func note(_ message: String) {
        event(message)
    }

    // CloudKit transport state (see ChariotHubCloudKit.swift).
    var cloudMailbox: CloudKitMailbox?
    var cloudContainerID: String?
    var syncInbox: CloudKitSyncInbox?
    var cloudReconcileTask: Task<Void, Never>?
    /// Set when a CloudKit container is configured but not yet connected;
    /// pairing must not mint localhost QR codes in that window.
    public var cloudDesired = false

    func setCloudKit(mailbox: CloudKitMailbox, containerID: String) {
        lock.lock(); defer { lock.unlock() }
        cloudMailbox = mailbox
        cloudContainerID = containerID
    }

    func pendingCloudPairingIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return pairingSessions.filter { $0.value.state == "waiting" }.map(\.key)
    }

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

        mailbox.onDeposit = { [weak self] envelope in
            self?.handleDeposit(envelope)
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

    public func startPairingSession() throws -> PairingPayload {
        guard mailboxPort != 0 || cloudMailbox != nil else { throw ChariotError.invalidState("no transport started") }
        if cloudDesired && cloudMailbox == nil {
            throw ChariotError.invalidState("CloudKit is still connecting — wait for the transport to show ready, then try again")
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var secret = Data(count: 32)
        secret.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let mailbox = cloudContainerID.map { "cloudkit:\($0)" } ?? "http://127.0.0.1:\(mailboxPort)"
        let payload = PairingPayload(
            rendezvousID: UUID().uuidString.lowercased(),
            macDeviceID: identity.deviceID,
            macDisplayName: macDisplayName,
            macSigningPublicKey: identity.signingKey.publicKey.rawRepresentation,
            macPairingPublicKey: ephemeral.publicKey.rawRepresentation,
            pairingSecret: secret,
            expiresAt: Date().addingTimeInterval(120),
            mailbox: mailbox
        )
        lock.lock()
        pairingSessions[payload.rendezvousID] = PairingSession(payload: payload, ephemeralKey: ephemeral, state: "waiting")
        lock.unlock()
        if let cloud = cloudMailbox {
            let epoch = registry.epoch
            let rendezvousID = payload.rendezvousID
            let expiresAt = payload.expiresAt
            Task {
                do {
                    try await cloud.createPairingSession(from: payload, epoch: epoch)
                    self.event("pairing rendezvous published to CloudKit")
                } catch {
                    self.event("cloudkit pairing record failed: \(error)")
                    return
                }
                // Bounded handshake watcher: while this QR is valid, nudge the
                // sync loop every few seconds so the approval prompt appears
                // even if the wake push is late. Ends with the session — part
                // of the handshake, not steady-state polling.
                while Date() < expiresAt {
                    if self.pairingSessionState(rendezvousID) != "waiting" { return }
                    self.pokeCloudPoll()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        event("pairing session \(payload.rendezvousID.prefix(8)) created")
        return payload
    }

    func pairingSessionState(_ rendezvousID: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return pairingSessions[rendezvousID]?.state ?? "unknown"
    }

    private func handlePairingResponse(rendezvousID: String, phoneEphemeral: Data, ciphertext: Data) -> HTTPServer.Response {
        switch acceptPairingResponse(rendezvousID: rendezvousID, phoneEphemeral: phoneEphemeral, ciphertext: ciphertext) {
        case .success: return .json(["state": "responded"])
        case .failure(let code): return .error(code.status, code.message)
        }
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
            case .unknown: return "unknown rendezvous"
            case .replay: return "pairing session already claimed"
            case .expired: return "pairing session expired"
            case .invalid: return "invalid pairing response"
            }
        }
    }

    /// Shared pairing-response validation used by both transports.
    func acceptPairingResponse(rendezvousID: String, phoneEphemeral: Data,
                               ciphertext: Data) -> Result<Void, PairingRejection> {
        lock.lock()
        guard var session = pairingSessions[rendezvousID] else {
            lock.unlock()
            return .failure(.unknown)
        }
        guard session.state == "waiting" else {
            lock.unlock()
            return .failure(.replay)  // QR replay rejection
        }
        guard session.payload.expiresAt > Date() else {
            pairingSessions[rendezvousID]?.state = "expired"
            lock.unlock()
            return .failure(.expired)
        }
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
            session.state = "responded"
            session.pairingKey = key
            lock.lock()
            pairingSessions[rendezvousID] = session
            lock.unlock()

            let approve: @Sendable (Bool) -> Void = { [weak self] approved in
                self?.completePairing(rendezvousID: rendezvousID, response: response, approved: approved)
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
            event("pairing response rejected: \(error)")
            return .failure(.invalid)
        }
    }

    private func completePairing(rendezvousID: String, response: PairingResponse, approved: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var session = pairingSessions[rendezvousID], let key = session.pairingKey else { return }
        guard approved else {
            session.state = "consumed"
            pairingSessions[rendezvousID] = session
            event("pairing rejected by user")
            if let cloud = cloudMailbox {
                Task { await cloud.deletePairingSession(rendezvousID: rendezvousID) }
            }
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
        pairingSessions[rendezvousID] = session
        if let cloud = cloudMailbox, let encrypted = session.encryptedCredential {
            Task {
                do {
                    let (_, record) = try await cloud.fetchPairingSession(rendezvousID: rendezvousID)
                    try await cloud.completePairingSession(record: record, encryptedCredential: encrypted)
                } catch {
                    self.event("cloudkit credential publish failed: \(error)")
                }
            }
        }

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
    /// message the revoked device can still read.
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
        event("revoked device \(deviceID.prefix(8)); epoch advanced to \(registry.epoch)")
    }

    /// Route an outbound envelope through the active transport.
    func deliver(envelope: EncryptedEnvelope) {
        if let cloud = cloudMailbox {
            Task {
                do { try await cloud.deposit(envelope) }
                catch { self.event("cloudkit deposit failed: \(error)") }
            }
        } else {
            mailbox.deposit(envelope)
        }
    }

    private func deviceEntry(_ deviceID: String) -> DeviceRegistry.Entry? {
        lock.lock(); defer { lock.unlock() }
        return registry.devices.first { $0.identity.deviceID == deviceID }
    }

    // MARK: Envelope handling (phone → Mac)

    private func handleDeposit(_ envelope: EncryptedEnvelope) {
        guard envelope.recipientDeviceID == identity.deviceID else { return }  // phone-bound mail stays queued
        defer { mailbox.acknowledge(recipient: identity.deviceID, messageIDs: [envelope.messageID]) }
        processInboundEnvelope(envelope)
    }

    /// Decrypt, replay-check, and dispatch an inbound envelope (any transport).
    func processInboundEnvelope(_ envelope: EncryptedEnvelope) {
        guard envelope.recipientDeviceID == identity.deviceID else { return }
        guard let entry = deviceEntry(envelope.senderDeviceID), entry.revokedAt == nil else {
            event("dropped envelope from unknown/revoked device")
            return
        }
        do {
            let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: entry.identity,
                                            epoch: registry.epoch)
            let message = try session.open(envelope)
            lock.lock()
            var window = replayWindows[envelope.senderDeviceID] ?? ReplayWindow()
            try window.accept(messageID: message.messageID, sequence: message.sequence)
            replayWindows[envelope.senderDeviceID] = window
            lock.unlock()
            try handleAgentMessage(message, from: entry)
        } catch {
            event("envelope rejected: \(error)")
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

    // MARK: HTTP surface (CloudKit stand-in + local admin)

    public func startMailboxServer(port: UInt16 = 8787) throws {
        let server = HTTPServer { [weak self] request in
            self?.route(request) ?? .error(500, "hub gone")
        }
        try server.start(port: port)
        httpServer = server
        mailboxPort = server.port
        event("mailbox listening on 127.0.0.1:\(server.port)")
    }

    private func route(_ request: HTTPServer.Request) -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.first ?? "") {
        case ("GET", "status"):
            return .json([
                "mac_device_id": identity.deviceID,
                "mac_display_name": macDisplayName,
                "vm_state": vmState.rawValue,
                "bridge_connected": bridgeConnected,
                "epoch": Int(registry.epoch),
                "mode": "cloud-fallback"
            ])
        case ("GET", "pairing") where parts.count == 2:
            guard let session = pairingSessions[parts[1]] else { return .error(404, "unknown rendezvous") }
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
            return handlePairingResponse(rendezvousID: parts[1], phoneEphemeral: ephemeral, ciphertext: ciphertext)
        case ("GET", "pairing") where parts.count == 3 && parts[2] == "credential":
            guard let session = pairingSessions[parts[1]] else { return .error(404, "unknown rendezvous") }
            guard let credential = session.encryptedCredential else { return .error(404, "not issued yet") }
            return .json(["ciphertext": Base64URL.encode(credential), "epoch": Int(registry.epoch)])
        case ("POST", "envelopes"):
            guard let envelope = try? CanonicalCoding.decoder().decode(EncryptedEnvelope.self, from: request.body) else {
                return .error(400, "malformed envelope")
            }
            if let entry = deviceEntry(envelope.senderDeviceID), entry.revokedAt != nil {
                return .error(403, "device revoked")
            }
            let serial = mailbox.deposit(envelope)
            return .json(["serial": Int(serial)])
        case ("GET", "envelopes"):
            guard let recipient = request.query["recipient"] else { return .error(400, "recipient required") }
            if let entry = deviceEntry(recipient), entry.revokedAt != nil {
                return .error(403, "device revoked")
            }
            let after = UInt64(request.query["after"] ?? "0") ?? 0
            let stored = mailbox.fetch(recipient: recipient, after: after)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let items: [[String: Any]] = stored.compactMap { item in
                guard let data = try? encoder.encode(item.envelope),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return ["serial": Int(item.serial), "envelope": object]
            }
            return .json(["envelopes": items, "epoch": Int(registry.epoch)])
        case ("POST", "receipts"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let recipient = object["recipient"] as? String,
                  let ids = object["message_ids"] as? [String] else {
                return .error(400, "malformed receipt")
            }
            mailbox.acknowledge(recipient: recipient, messageIDs: ids)
            return .json(["acknowledged": ids.count])
        default:
            return routeAdmin(request, parts: parts)
        }
    }

    /// Local-only admin endpoints used by the E2E harness (and available to
    /// the GUI). The mailbox itself is localhost-only, so these are too.
    private func routeAdmin(_ request: HTTPServer.Request, parts: [String]) -> HTTPServer.Response {
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
                "mac_fingerprint": identity.publicIdentity.fingerprint
            ])
        case ("POST", "revoke"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let deviceID = object["device_id"] else { return .error(400, "device_id required") }
            revokeDevice(deviceID)
            return .json(["revoked": deviceID])
        case ("GET", "events"):
            return .json(["events": eventBuffer.recent()])
        case ("POST", "testpush"):
            guard let cloud = cloudMailbox else { return .error(400, "cloudkit not enabled") }
            let semaphore = DispatchSemaphore(value: 0)
            let box = OutputCollector()
            Task {
                do {
                    try await cloud.triggerTestPush()
                    box.append("zone change written — other devices should receive a push now")
                } catch {
                    box.append("test write failed: \(error)")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15)
            return .json(["result": box.text])
        case ("GET", "sessions"):
            lock.lock()
            let sessions = pairingSessions.map { ["rendezvous_id": $0.key, "state": $0.value.state,
                                                  "has_credential": $0.value.encryptedCredential != nil] }
            lock.unlock()
            return .json(["sessions": sessions])
        case ("GET", "cloudkit") where rest.count == 3 && rest[1] == "pairing":
            // Debug probe: does the pairing record exist in CloudKit as this
            // Mac sees it?
            guard let cloud = cloudMailbox else { return .error(400, "cloudkit not enabled") }
            let rendezvousID = rest[2]
            let semaphore = DispatchSemaphore(value: 0)
            let box = OutputCollector()
            Task {
                do {
                    let (pairing, _) = try await cloud.fetchPairingSession(rendezvousID: rendezvousID)
                    box.append("state=\(pairing.state) epoch=\(pairing.epoch) hasResponse=\(pairing.encryptedMobileResponse != nil) hasCredential=\(pairing.encryptedCredential != nil)")
                } catch {
                    box.append("error: \(error)")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15)
            return .json(["probe": box.text])
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
        case ("GET", "cloudkit") where rest.count == 3 && rest[1] == "inbox":
            guard let cloud = cloudMailbox else { return .error(400, "cloudkit not enabled") }
            let recipient = rest[2]
            let semaphore = DispatchSemaphore(value: 0)
            let box = OutputCollector()
            Task {
                do {
                    let envelopes = try await cloud.fetchEnvelopes(recipient: recipient)
                    box.append("\(envelopes.count)")
                } catch {
                    box.append("error: \(error)")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 20)
            return .json(["pending": box.text])
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

final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
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
