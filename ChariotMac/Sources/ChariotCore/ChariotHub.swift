import Foundation
import CryptoKit
import AgentLinkKit

/// Registry of paired mobile devices plus the active session epoch. One per
/// agent instance (Milestone 1): pairing is per agent, so each agent carries
/// its own device list and epoch — the credential relationship IS the grant.
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
/// tailnet node, the WebSocket transport service, and the agent fleet — a
/// registry of { instance UUID → VM/bridge } contexts, each with its own
/// device registry, epoch, guest bridge, and Codex login state. Both the
/// SwiftUI app and the headless daemon drive everything through this type.
///
/// Transport layout: a loopback-only HTTP/WebSocket service carries pairing
/// and the encrypted message protocol. In production the bundled agent-tailnet
/// helper exposes that service on the Mac's Tailscale node (TCP 443, TLS) and
/// proxies to loopback; the development harness connects to loopback directly.
/// Admin/diagnostic endpoints live on a second, never-proxied loopback server.
public final class ChariotHub: @unchecked Sendable {
    /// Context key for the pre-fleet single-VM/loopback development flow.
    static let legacyContextKey = "default"

    public let paths: ChariotPaths
    public let backend: VirtualMachineBackend
    let mailbox: MailboxStore
    private var transportServer: HTTPServer?
    private var adminServer: HTTPServer?
    public private(set) var transportPort: UInt16 = 0
    public private(set) var adminPort: UInt16 = 0

    let identity: DeviceIdentity
    public var macDisplayName: String
    /// Base image used when creating agents (and the legacy instance).
    public var defaultBaseImagePath: String?
    private let lock = NSRecursiveLock()

    // Fleet: canonical context key (instance UUID or "default") → context.
    private var contexts: [String: AgentContext] = [:]
    private var agentIndex: [AgentRecord] = []

    /// Feature flag `tailscale_transport`: when true (the default), pairing QR
    /// codes carry the tailnet service URL and require the embedded node to be
    /// authenticated. When false the hub runs in loopback development mode.
    /// Temporary migration/rollback control (env `CHARIOT_TAILSCALE=0`).
    public var tailscaleEnabled: Bool =
        (ProcessInfo.processInfo.environment["CHARIOT_TAILSCALE"] ?? "1") != "0"
    public private(set) var tailnet: TailnetSupervisor?

    // Pairing sessions keyed by single-use pairing ID. Each session targets
    // exactly one agent context: scanning the QR binds the device to THAT
    // instance only.
    private struct PairingSession {
        let payload: PairingPayload
        let ephemeralKey: Curve25519.KeyAgreement.PrivateKey
        let targetContextKey: String
        var state: String  // "waiting" | "responded" | "consumed" | "expired"
        var pairingKey: SymmetricKey?
        var encryptedCredential: Data?
    }
    private var pairingSessions: [String: PairingSession] = [:]
    /// Responders for pairings waiting on interactive device approval.
    private var pendingApprovals: [String: @Sendable (Bool) -> Void] = [:]

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
        var instanceID: String?      // as sent by the phone (signed)
        var contextKey: String?      // resolved agent context
        init(connection: WebSocketConnection, nonce: String) {
            self.connection = connection
            self.nonce = nonce
        }
    }
    private var wsSessions: [ObjectIdentifier: WSSession] = [:]
    private var wsByDevice: [String: ObjectIdentifier] = [:]
    private var statusTimer: DispatchSourceTimer?

    // Legacy single-VM instance (pre-pack flow, kept for the dev harness).
    public private(set) var activeInstance: SandboxID?

    // Codex brokered login (design §3.1): the OAuth callback tunnel listens
    // on the fixed localhost:1455 redirect, so one sign-in runs at a time
    // across the fleet ("one broker dance per agent").
    private var pendingAuthURLWaiters: [(String) -> Void] = []
    /// UI hook: called with the auth URL so the app can open the browser.
    public var onOAuthRequest: (@Sendable (String) -> Void)?

    // Streaming state: request → destination phone + owning agent + buffer.
    private struct Stream {
        var recipientDeviceID: String
        var contextKey: String
        var conversationID: String
        var buffer: String = ""
        var flushScheduled = false
    }
    private var streams: [String: Stream] = [:]  // key: requestID
    private var localStreams: [String: (@Sendable (String) -> Void, @Sendable (Int) -> Void)] = [:]
    private let flushQueue = DispatchQueue(label: "chariot.hub.flush")

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

        // Fleet index: recreate a context per created agent.
        if let data = try? Data(contentsOf: paths.agentsIndex),
           let loaded = try? decoder().decode([AgentRecord].self, from: data) {
            agentIndex = loaded
        }
        for record in agentIndex {
            let instance = InstancePaths(directory: paths.instanceDirectory(record.instanceID))
            contexts[record.instanceID] = AgentContext(key: record.instanceID,
                                                       record: record,
                                                       vmInstanceID: record.instanceID,
                                                       registryURL: instance.deviceRegistry,
                                                       packStateURL: instance.packState)
        }

        // Phone-bound envelopes stay durably queued here until acknowledged;
        // a live WebSocket session gets them pushed immediately on deposit.
        mailbox.onDeposit = { [weak self] envelope, instanceID in
            self?.pushEnvelopeIfConnected(envelope, instanceID: instanceID)
        }
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Scoped locking usable from async contexts (NSRecursiveLock's raw
    /// lock/unlock are compile-time-restricted to synchronous code).
    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    public var macPublicIdentity: PublicDeviceIdentity { identity.publicIdentity }

    // MARK: Agent contexts

    /// The legacy pre-fleet context ("default"): loopback development pairing
    /// and the single-VM flow. Its device registry stays at the pre-fleet
    /// location so existing installs keep their pairings.
    private func legacyContext() -> AgentContext {
        lock.lock(); defer { lock.unlock() }
        if let existing = contexts[Self.legacyContextKey] { return existing }
        let context = AgentContext(key: Self.legacyContextKey,
                                   record: nil,
                                   vmInstanceID: activeInstance,
                                   registryURL: paths.identityDirectory.appendingPathComponent("devices.json"),
                                   packStateURL: nil)
        contexts[Self.legacyContextKey] = context
        return context
    }

    private func context(forKey key: String) -> AgentContext? {
        lock.lock(); defer { lock.unlock() }
        return contexts[key]
    }

    /// Resolve the context a phone-supplied instance ID refers to: an agent's
    /// instance UUID, or the legacy context under its historical names.
    private func resolveContext(instanceID: String) -> AgentContext? {
        lock.lock(); defer { lock.unlock() }
        if let context = contexts[instanceID], context.record != nil { return context }
        if instanceID == Self.legacyContextKey || instanceID == currentInstanceID {
            return legacyContext()
        }
        return nil
    }

    /// Context for public API calls: nil targets the legacy context.
    private func requireContext(_ instanceID: String?) throws -> AgentContext {
        guard let instanceID, instanceID != Self.legacyContextKey else { return legacyContext() }
        lock.lock(); defer { lock.unlock() }
        if let context = contexts[instanceID] { return context }
        if instanceID == activeInstance { return legacyContext() }
        throw ChariotError.instanceNotFound(instanceID)
    }

    private func persistRegistry(_ context: AgentContext) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(context.registry) {
            try? data.write(to: context.registryURL, options: .atomic)
        }
    }

    private func persistAgentIndex() {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(agentIndex) {
            try? data.write(to: paths.agentsIndex, options: .atomic)
        }
    }

    // MARK: Fleet lifecycle (Milestone 1)

    /// Create an agent from a pack: mint the instance UUID (the durable
    /// identity), clone the base image with the pack's VM sizing, and record
    /// it in the fleet index. The VM is not started here.
    public func createAgent(fromPackDirectory packDirectoryName: String,
                            displayName: String? = nil) async throws -> AgentRecord {
        guard let baseImage = defaultBaseImagePath, !baseImage.isEmpty else {
            throw ChariotError.invalidState("no base image configured")
        }
        let pack = try PackLoader.load(at: paths.packsDirectory.appendingPathComponent(packDirectoryName))
        let instanceID = UUID().uuidString.lowercased()
        _ = try await backend.createInstance(configuration: pack.configuration(baseImagePath: baseImage),
                                             id: instanceID)
        let record = AgentRecord(instanceID: instanceID,
                                 packID: pack.manifest.id,
                                 displayName: displayName ?? pack.manifest.name,
                                 packDirectoryName: packDirectoryName,
                                 createdAt: Date())
        let instance = InstancePaths(directory: paths.instanceDirectory(instanceID))
        synchronized {
            agentIndex.append(record)
            contexts[instanceID] = AgentContext(key: instanceID,
                                                record: record,
                                                vmInstanceID: instanceID,
                                                registryURL: instance.deviceRegistry,
                                                packStateURL: instance.packState)
        }
        persistAgentIndex()
        event("agent \(record.displayName) created from \(packDirectoryName) (instance \(instanceID.prefix(8)))")
        return record
    }

    public func agentRecords() -> [AgentRecord] {
        lock.lock(); defer { lock.unlock() }
        return agentIndex
    }

    public func agentSummaries() -> [AgentSummary] {
        lock.lock(); defer { lock.unlock() }
        return agentIndex.compactMap { record in
            guard let context = contexts[record.instanceID] else { return nil }
            return AgentSummary(record: record,
                                vmState: vmState(of: record.instanceID),
                                bridgeConnected: context.bridge != nil,
                                agentStatus: context.agentStatus,
                                epoch: context.registry.epoch,
                                pairedDeviceCount: context.registry.devices.filter { $0.revokedAt == nil }.count)
        }
    }

    public func startAgent(_ instanceID: String) async throws {
        let context = try requireContext(instanceID)
        try await start(context)
    }

    public func stopAgent(_ instanceID: String) async throws {
        let context = try requireContext(instanceID)
        try await stop(context)
    }

    public func resetAgent(_ instanceID: String) async throws {
        let context = try requireContext(instanceID)
        try await reset(context)
    }

    public func vmState(of instanceID: String) -> SandboxState {
        guard let context = try? requireContext(instanceID),
              let vm = context.vmInstanceID else { return .notCreated }
        return backend.state(of: vm)
    }

    public func agentStatus(of instanceID: String) -> AgentRuntimeStatus? {
        (try? requireContext(instanceID))?.agentStatus
    }

    public func bridgeConnected(of instanceID: String) -> Bool {
        (try? requireContext(instanceID))?.bridge != nil
    }

    private func start(_ context: AgentContext) async throws {
        guard let vm = context.vmInstanceID else { throw ChariotError.invalidState("no instance") }
        try await backend.start(vm)
        try await connectBridge(context)
        await syncPack(context)
    }

    private func stop(_ context: AgentContext) async throws {
        guard let vm = context.vmInstanceID else { return }
        synchronized { disconnectRuntime(context) }
        try await backend.stop(vm)
    }

    private func reset(_ context: AgentContext) async throws {
        guard let vm = context.vmInstanceID else { throw ChariotError.invalidState("no instance") }
        synchronized {
            disconnectRuntime(context)
            context.agentStatus = nil    // Reset wipes the disk: Codex returns signed out.
            context.packInstalled = [:]  // Full pack replay on the next boot.
        }
        try await backend.reset(vm)
    }

    /// Caller holds the lock.
    private func disconnectRuntime(_ context: AgentContext) {
        context.bridge?.close()
        context.bridge = nil
        context.developerAccess?.disable()
        context.developerAccess = nil
        context.loginTunnel?.stop()
        context.loginTunnel = nil
    }

    private func connectBridge(_ context: AgentContext) async throws {
        guard let vm = context.vmInstanceID else { throw ChariotError.invalidState("no instance") }
        let controller = try backend.controller(for: vm)
        event("\(displayName(of: context)): waiting for guest bridge…")
        let connection = try await controller.connectSocket(port: 1024)
        let bridge = BridgeClient(connection: connection) { [weak self, weak context] event in
            guard let self, let context else { return }
            self.handleBridgeEvent(context, event)
        }
        synchronized { context.bridge = bridge }
        event("\(displayName(of: context)): guest bridge connected")
    }

    private func displayName(of context: AgentContext) -> String {
        context.record?.displayName ?? "sandbox"
    }

    // MARK: Pack populate + hot re-push (Milestone 1)

    /// Install the pack's workspace content into the guest: everything whose
    /// checksum differs from what this instance last received. Runs after
    /// boot and before every turn, so pack edits land on the next turn with
    /// no rebuild; after Reset the install state is empty and the whole
    /// workspace replays. Seed-only files are pushed with `if_absent`, so the
    /// guest never overwrites one that already exists.
    func syncPack(_ context: AgentContext) async {
        let (record, bridge, installed) = synchronized {
            (context.record, context.bridge, context.packInstalled)
        }
        guard let record, let bridge else { return }
        do {
            let pack = try PackLoader.load(
                at: paths.packsDirectory.appendingPathComponent(record.packDirectoryName))
            var pushed = 0
            for file in try pack.workspaceFiles() {
                let data = try Data(contentsOf: file.source)
                let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if installed[file.destination] == sum { continue }
                let written = try await bridge.putFile(path: file.destination,
                                                       contents: data,
                                                       mode: file.executable ? 0o755 : 0o644,
                                                       ifAbsent: file.seedOnly)
                if written { pushed += 1 }
                synchronized { context.packInstalled[file.destination] = sum }
            }
            persistPackState(context)
            if pushed > 0 {
                event("\(record.displayName): installed \(pushed) pack file(s) into /workspace")
            }
        } catch {
            event("\(record.displayName): pack sync failed: \(error)")
        }
    }

    private func persistPackState(_ context: AgentContext) {
        let (url, state) = synchronized {
            (context.packStateURL, PackInstallState(checksums: context.packInstalled))
        }
        guard let url else { return }
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// One agent turn: hot-sync pack edits, then hand the prompt to the
    /// guest. `failure` fires instead of the normal completion path when the
    /// bridge is gone or the send fails.
    private func dispatchTurn(_ context: AgentContext, requestID: String, conversationID: String,
                              text: String, failure: @escaping @Sendable (String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            await self.syncPack(context)
            guard let bridge = self.synchronized({ context.bridge }) else {
                failure("sandbox is not running")
                return
            }
            do {
                try bridge.sendConversation(requestID: requestID,
                                            conversationID: conversationID, text: text)
            } catch {
                failure("\(error)")
            }
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

    // MARK: Legacy single-VM lifecycle (pre-pack dev flow)

    /// Adopt or create the legacy non-agent instance. Agent instances are
    /// excluded: they belong to their own contexts.
    public func ensureInstance(configuration: SandboxConfiguration) async throws -> SandboxID {
        let agentIDs = synchronized { Set(agentIndex.map(\.instanceID)) }
        if let existing = backend.existingInstanceIDs().first(where: { !agentIDs.contains($0) }) {
            activeInstance = existing
            legacyContext().vmInstanceID = existing
            return existing
        }
        let id = try await backend.create(configuration: configuration)
        activeInstance = id
        legacyContext().vmInstanceID = id
        return id
    }

    public func startVM() async throws {
        guard activeInstance != nil else { throw ChariotError.invalidState("no instance") }
        try await start(legacyContext())
    }

    public func stopVM() async throws {
        guard activeInstance != nil else { return }
        try await stop(legacyContext())
    }

    public func resetVM() async throws {
        guard activeInstance != nil else { throw ChariotError.invalidState("no instance") }
        try await reset(legacyContext())
    }

    public func restartVM() async throws {
        try await stopVM()
        try await startVM()
    }

    public var vmState: SandboxState {
        guard let id = activeInstance else { return .notCreated }
        return backend.state(of: id)
    }

    public var bridgeConnected: Bool { legacyContext().bridge != nil }
    public var agentStatus: AgentRuntimeStatus? { legacyContext().agentStatus }
    public var lastGuestStatus: (state: String, kernel: String, hostname: String)? {
        legacyContext().lastGuestStatus
    }
    public var currentEpoch: UInt32 { legacyContext().registry.epoch }

    // MARK: Codex sign-in (design §3.1 brokered browser flow)

    /// Start the guest's `codex login` and the localhost:1455 → vsock:1022
    /// callback tunnel. The auth URL arrives via `.oauthRequested`. Sign-in
    /// is per agent (each guest holds its own credential), but only one
    /// brokered dance runs at a time: the OAuth redirect port is fixed.
    public func startCodexLogin(instanceID: String? = nil) throws {
        let context = try requireContext(instanceID)
        lock.lock()
        let bridge = context.bridge
        let busy = contexts.values.contains { $0 !== context && $0.loginTunnel != nil }
        lock.unlock()
        guard let bridge else { throw ChariotError.bridgeUnavailable("sandbox not running") }
        guard !busy else {
            throw ChariotError.invalidState("another agent's Codex sign-in is in progress — finish or cancel it first")
        }
        guard let vm = context.vmInstanceID else { throw ChariotError.invalidState("no instance") }
        lock.lock()
        if context.loginTunnel == nil {
            if let controller = try? backend.controller(for: vm) {
                context.loginTunnel = VsockPortForwarder(controller: controller,
                                                         listenPort: 1455, vsockPort: 1022)
            }
        }
        let tunnel = context.loginTunnel
        lock.unlock()
        try tunnel?.start()
        try bridge.startLogin()
        event("\(displayName(of: context)): codex sign-in started; waiting for auth URL from guest")
    }

    public func cancelCodexLogin(instanceID: String? = nil) {
        guard let context = try? requireContext(instanceID) else { return }
        lock.lock()
        let bridge = context.bridge
        let tunnel = context.loginTunnel
        context.loginTunnel = nil
        lock.unlock()
        try? bridge?.cancelLogin()
        tunnel?.stop()
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

    public func enableDeveloperAccess(instanceID: String? = nil) throws -> (port: UInt16, command: String, instructions: String) {
        let context = try requireContext(instanceID)
        guard let vm = context.vmInstanceID else { throw ChariotError.invalidState("no instance") }
        let controller = try backend.controller(for: vm)
        let instance = InstancePaths(directory: paths.instanceDirectory(vm))
        lock.lock()
        if context.developerAccess == nil {
            context.developerAccess = DeveloperAccess(controller: controller, instance: instance)
        }
        let access = context.developerAccess!
        lock.unlock()
        let info = try access.enable()
        event("\(displayName(of: context)): developer access unlocked on 127.0.0.1:\(info.port)")
        return (info.port, info.command, info.codexInstructions)
    }

    public func disableDeveloperAccess(instanceID: String? = nil) {
        guard let context = try? requireContext(instanceID) else { return }
        lock.lock()
        let access = context.developerAccess
        context.developerAccess = nil
        lock.unlock()
        access?.disable()
    }

    // MARK: Local conversation (Mac UI → agent)

    public func sendLocalPrompt(_ text: String, instanceID: String? = nil,
                                conversationID: String = "local",
                                onDelta: @escaping @Sendable (String) -> Void,
                                onCompleted: @escaping @Sendable (Int) -> Void) throws {
        let context = try requireContext(instanceID)
        lock.lock()
        let hasBridge = context.bridge != nil
        lock.unlock()
        guard hasBridge else { throw ChariotError.bridgeUnavailable("not connected") }
        let requestID = UUID().uuidString.lowercased()
        lock.lock()
        localStreams[requestID] = (onDelta, onCompleted)
        lock.unlock()
        dispatchTurn(context, requestID: requestID, conversationID: conversationID,
                     text: text) { [weak self] message in
            guard let self else { return }
            self.lock.lock()
            let handlers = self.localStreams.removeValue(forKey: requestID)
            self.lock.unlock()
            handlers?.0(message + "\n")
            handlers?.1(-1)
        }
    }

    public func cancelConversation(_ conversationID: String, instanceID: String? = nil) {
        guard let context = try? requireContext(instanceID) else { return }
        lock.lock()
        let bridge = context.bridge
        lock.unlock()
        try? bridge?.cancel(conversationID: conversationID)
    }

    // MARK: Pairing

    public var currentInstanceID: String { activeInstance ?? Self.legacyContextKey }

    public func pairedDevices(instanceID: String? = nil) -> [(id: String, name: String, pairedAt: Date, revoked: Bool, fingerprint: String)] {
        guard let context = try? requireContext(instanceID) else { return [] }
        lock.lock(); defer { lock.unlock() }
        return context.registry.devices.map {
            ($0.identity.deviceID, $0.displayName, $0.pairedAt, $0.revokedAt != nil, $0.identity.fingerprint)
        }
    }

    /// Mint a pairing QR for one agent. The payload's instance ID is the
    /// agent's instance UUID — the phone signs it into its transport hello,
    /// and the resulting credential lives in that agent's registry only.
    public func startPairingSession(instanceID: String? = nil) throws -> PairingPayload {
        guard transportPort != 0 else { throw ChariotError.invalidState("transport not started") }
        let context = try requireContext(instanceID)

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

        let advertisedInstanceID = context.record?.instanceID ?? currentInstanceID
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var secret = Data(count: 32)
        secret.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let payload = PairingPayload(
            serviceURL: serviceURL,
            instanceID: advertisedInstanceID,
            macDeviceID: identity.deviceID,
            macDisplayName: context.record.map { "\($0.displayName) — \(macDisplayName)" } ?? macDisplayName,
            macSigningPublicKey: identity.signingKey.publicKey.rawRepresentation,
            macPairingPublicKey: ephemeral.publicKey.rawRepresentation,
            tlsPublicKeyHash: tlsPin,
            pairingID: UUID().uuidString.lowercased(),
            pairingSecret: secret,
            expiresAt: Date().addingTimeInterval(120)
        )
        lock.lock()
        pairingSessions[payload.pairingID] = PairingSession(payload: payload, ephemeralKey: ephemeral,
                                                            targetContextKey: context.key, state: "waiting")
        lock.unlock()
        event("pairing session \(payload.pairingID.prefix(8)) created for \(displayName(of: context)) (\(serviceURL))")
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
                // Interactive approval races the admin surface (see
                // resolvePendingPairing); whoever takes the responder out of
                // pendingApprovals first decides, the other no-ops.
                lock.lock()
                pendingApprovals[pairingID] = approve
                lock.unlock()
                let guarded: @Sendable (Bool) -> Void = { [weak self] approved in
                    guard let self else { return }
                    self.lock.lock()
                    let responder = self.pendingApprovals.removeValue(forKey: pairingID)
                    self.lock.unlock()
                    responder?(approved)
                }
                ask(response, guarded)
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

    /// Approve or reject a pairing that is waiting on interactive device
    /// approval — the loopback admin surface's stand-in for clicking the
    /// GUI alert (used by automated end-to-end tests). Returns false when
    /// nothing is waiting (already resolved, expired, or unknown).
    @discardableResult
    public func resolvePendingPairing(pairingID: String, approved: Bool) -> Bool {
        lock.lock()
        let responder = pendingApprovals.removeValue(forKey: pairingID)
        lock.unlock()
        guard let responder else { return false }
        responder(approved)
        return true
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
        guard let context = contexts[session.targetContextKey] else {
            session.state = "consumed"
            pairingSessions[pairingID] = session
            event("pairing target agent no longer exists")
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

        context.registry.devices.removeAll { $0.identity.deviceID == response.mobile.deviceID }
        context.registry.devices.append(DeviceRegistry.Entry(identity: response.mobile,
                                                             displayName: response.mobileDisplayName,
                                                             pairedAt: Date(),
                                                             revokedAt: nil,
                                                             lastOutboundSequence: 0))
        persistRegistry(context)
        event("paired device \(response.mobileDisplayName) (\(response.mobile.fingerprint)) to \(displayName(of: context))")
    }

    /// Revoke a device: reject its credential and advance the agent's session
    /// epoch so it cannot decrypt future envelopes (design §8.1). A signed
    /// `device.revoked` notice is sealed with the *old* epoch first — the last
    /// message the revoked device can still read — then any live WebSocket
    /// session is told and closed. Revocation is per agent; with no instance
    /// given, every agent that knows the device revokes it.
    public func revokeDevice(_ deviceID: String, instanceID: String? = nil) {
        lock.lock()
        let targets: [AgentContext]
        if let instanceID, let context = contexts[instanceID] {
            targets = [context]
        } else {
            targets = contexts.values.filter { context in
                context.registry.devices.contains { $0.identity.deviceID == deviceID }
            }
        }
        lock.unlock()
        for context in targets {
            revoke(deviceID, in: context)
        }
    }

    private func revoke(_ deviceID: String, in context: AgentContext) {
        lock.lock()
        guard let index = context.registry.devices.firstIndex(where: { $0.identity.deviceID == deviceID }),
              context.registry.devices[index].revokedAt == nil else {
            lock.unlock()
            return
        }
        let peer = context.registry.devices[index].identity
        context.registry.devices[index].lastOutboundSequence += 1
        let sequence = context.registry.devices[index].lastOutboundSequence
        let oldEpoch = context.registry.epoch
        context.registry.devices[index].revokedAt = Date()
        context.registry.epoch += 1
        let newEpoch = context.registry.epoch
        lock.unlock()
        persistRegistry(context)
        do {
            let notice = AgentMessage(conversationID: "control", senderDeviceID: identity.deviceID,
                                      sequence: sequence, type: .deviceRevoked,
                                      body: .object(["reason": .string("revoked by Mac user")]))
            let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: peer, epoch: oldEpoch)
            deliver(envelope: try session.seal(notice), from: context)
        } catch {
            event("revocation notice failed: \(error)")
        }
        // Tell the live session (if any) and drop it.
        lock.lock()
        let sessionID = wsByDevice[deviceID]
        let ws = sessionID.flatMap { wsSessions[$0] }
        let connection = (ws?.contextKey == context.key) ? ws?.connection : nil
        lock.unlock()
        if let connection {
            sendFrame(TransportFrame(type: .revoked), over: connection)
            connection.close()
        }
        broadcastStatus()
        event("revoked device \(deviceID.prefix(8)) on \(displayName(of: context)); epoch advanced to \(newEpoch)")
    }

    /// Queue an outbound envelope durably; a live session gets it immediately.
    /// Envelopes stay in the mailbox until the recipient acknowledges them.
    func deliver(envelope: EncryptedEnvelope, from context: AgentContext) {
        mailbox.deposit(envelope, instanceID: context.record != nil ? context.key : nil)
    }

    private func deviceEntry(_ deviceID: String, in context: AgentContext) -> DeviceRegistry.Entry? {
        lock.lock(); defer { lock.unlock() }
        return context.registry.devices.first { $0.identity.deviceID == deviceID }
    }

    // MARK: Envelope handling (phone → Mac)

    /// Decrypt, replay-check, and dispatch an inbound envelope within one
    /// agent's context. Returns true when the envelope should be acknowledged
    /// to the sender (processed now or a duplicate of something already
    /// processed).
    @discardableResult
    func processInboundEnvelope(_ envelope: EncryptedEnvelope, context: AgentContext) -> Bool {
        guard envelope.recipientDeviceID == identity.deviceID else { return false }
        guard let entry = deviceEntry(envelope.senderDeviceID, in: context), entry.revokedAt == nil else {
            event("dropped envelope from device not paired to \(displayName(of: context))")
            return false
        }
        lock.lock()
        let epoch = context.registry.epoch
        lock.unlock()
        do {
            let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: entry.identity,
                                            epoch: epoch)
            let message = try session.open(envelope)
            lock.lock()
            var window = context.replayWindows[envelope.senderDeviceID] ?? ReplayWindow()
            do {
                try window.accept(messageID: message.messageID, sequence: message.sequence)
            } catch AgentLinkError.replayDetected {
                lock.unlock()
                return true  // duplicate delivery — ack again, don't reprocess
            }
            context.replayWindows[envelope.senderDeviceID] = window
            lock.unlock()
            try handleAgentMessage(message, from: entry, context: context)
            return true
        } catch {
            event("envelope rejected: \(error)")
            return false
        }
    }

    private func handleAgentMessage(_ message: AgentMessage, from entry: DeviceRegistry.Entry,
                                    context: AgentContext) throws {
        switch message.type {
        case .conversationSend:
            let text = message.body["text"]?.stringValue ?? ""
            event("prompt from \(entry.displayName) → \(displayName(of: context)): \(text.prefix(80))")
            lock.lock()
            let hasBridge = context.bridge != nil
            lock.unlock()
            guard hasBridge else {
                try sendToDevice(entry.identity.deviceID, context: context, type: .outputCompleted,
                                 conversationID: message.conversationID,
                                 body: .object(["exit_code": .number(-1),
                                                "error": .string("sandbox is not running")]))
                return
            }
            lock.lock()
            streams[message.messageID] = Stream(recipientDeviceID: entry.identity.deviceID,
                                                contextKey: context.key,
                                                conversationID: message.conversationID)
            lock.unlock()
            dispatchTurn(context, requestID: message.messageID,
                         conversationID: message.conversationID, text: text) { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                let stream = self.streams.removeValue(forKey: message.messageID)
                self.lock.unlock()
                guard let stream else { return }
                try? self.sendToDevice(stream.recipientDeviceID, context: context, type: .outputCompleted,
                                       conversationID: message.conversationID,
                                       body: .object(["exit_code": .number(-1),
                                                      "error": .string(error)]))
            }
        case .conversationCancel:
            lock.lock()
            let bridge = context.bridge
            lock.unlock()
            try? bridge?.cancel(conversationID: message.conversationID)
        case .fileWrite:
            // Phone → workspace data upload (design: phone is the source of
            // truth; the VM replica is disposable). Same path discipline as
            // pack populate: the guest bridge only writes under /workspace.
            let path = message.body["path"]?.stringValue ?? ""
            let deviceID = entry.identity.deviceID
            let conversationID = message.conversationID
            guard path.hasPrefix("/workspace/"), !path.contains(".."),
                  let encoded = message.body["contents_b64"]?.stringValue,
                  let contents = Data(base64Encoded: encoded) else {
                try sendToDevice(deviceID, context: context, type: .fileWriteResult,
                                 conversationID: conversationID,
                                 body: .object(["request_id": .string(message.messageID),
                                                "path": .string(path),
                                                "ok": .bool(false),
                                                "error": .string("invalid path or contents")]))
                return
            }
            lock.lock()
            let bridge = context.bridge
            lock.unlock()
            guard let bridge else {
                try sendToDevice(deviceID, context: context, type: .fileWriteResult,
                                 conversationID: conversationID,
                                 body: .object(["request_id": .string(message.messageID),
                                                "path": .string(path),
                                                "ok": .bool(false),
                                                "error": .string("sandbox is not running")]))
                return
            }
            event("file from \(entry.displayName) → \(displayName(of: context)): \(path) (\(contents.count) bytes)")
            Task { [weak self] in
                guard let self else { return }
                var failure: String?
                do {
                    _ = try await bridge.putFile(path: path, contents: contents,
                                                 mode: 0o644, ifAbsent: false)
                } catch {
                    failure = "\(error)"
                }
                var body: [String: JSONValue] = ["request_id": .string(message.messageID),
                                                 "path": .string(path),
                                                 "ok": .bool(failure == nil)]
                if let failure { body["error"] = .string(failure) }
                try? self.sendToDevice(deviceID, context: context, type: .fileWriteResult,
                                       conversationID: conversationID, body: .object(body))
            }
        case .sandboxStatus:
            lock.lock()
            let status = context.lastGuestStatus
            let bridgeUp = context.bridge != nil
            lock.unlock()
            let state = context.vmInstanceID.map { backend.state(of: $0) } ?? .notCreated
            try sendToDevice(entry.identity.deviceID, context: context, type: .sandboxStatus,
                             conversationID: message.conversationID,
                             body: .object([
                                "state": .string(state.rawValue),
                                "bridge": .bool(bridgeUp),
                                "kernel": .string(status?.kernel ?? ""),
                                "hostname": .string(status?.hostname ?? "")
                             ]))
        default:
            event("unhandled message type \(message.type.rawValue) from phone")
        }
    }

    /// Seal and queue an outbound message for a device paired to one agent.
    func sendToDevice(_ deviceID: String, context: AgentContext, type: AgentMessageType,
                      conversationID: String, body: JSONValue) throws {
        lock.lock()
        guard let index = context.registry.devices.firstIndex(where: { $0.identity.deviceID == deviceID }),
              context.registry.devices[index].revokedAt == nil else {
            lock.unlock()
            throw ChariotError.notPaired
        }
        context.registry.devices[index].lastOutboundSequence += 1
        let sequence = context.registry.devices[index].lastOutboundSequence
        let peer = context.registry.devices[index].identity
        let epoch = context.registry.epoch
        lock.unlock()
        persistRegistry(context)

        let message = AgentMessage(conversationID: conversationID,
                                   senderDeviceID: identity.deviceID,
                                   sequence: sequence, type: type, body: body)
        let session = try SessionCrypto(localIdentity: identity, peerPublicIdentity: peer, epoch: epoch)
        deliver(envelope: try session.seal(message), from: context)
    }

    // MARK: Bridge events → streams

    private func handleBridgeEvent(_ context: AgentContext, _ bridgeEvent: BridgeEvent) {
        switch bridgeEvent {
        case .status(let state, _, let kernel, let hostname, let agent):
            lock.lock()
            context.lastGuestStatus = (state, kernel, hostname)
            if let agent { context.agentStatus = agent }
            lock.unlock()
            if let agent {
                event("\(displayName(of: context)): \(agent.name) \(agent.version ?? "?") installed=\(agent.installed) signedIn=\(agent.loggedIn)")
            } else {
                event("\(displayName(of: context)): guest status \(state), kernel \(kernel)")
            }
            broadcastStatus()
        case .oauthRequested(let provider, let purpose, let authURL):
            event("oauth requested by \(displayName(of: context)) (\(provider)): \(purpose)")
            lock.lock()
            let waiters = pendingAuthURLWaiters
            pendingAuthURLWaiters = []
            lock.unlock()
            waiters.forEach { $0(authURL) }
            onOAuthRequest?(authURL)
        case .oauthCompleted(let success, let message):
            event("\(displayName(of: context)): codex sign-in \(success ? "succeeded" : "failed"): \(message)")
            lock.lock()
            let tunnel = context.loginTunnel
            if success { context.loginTunnel = nil }
            let bridge = context.bridge
            lock.unlock()
            if success {
                // Callback served; the tunnel has no further purpose.
                tunnel?.stop()
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
            let stream = streams.removeValue(forKey: requestID)
            lock.unlock()
            if let stream, let streamContext = self.context(forKey: stream.contextKey) {
                try? sendToDevice(stream.recipientDeviceID, context: streamContext,
                                  type: .outputCompleted, conversationID: conversationID,
                                  body: .object(["exit_code": .number(Double(exitCode)),
                                                 "request_id": .string(requestID)]))
            }
        case .pong:
            break
        case .error(let message):
            event("\(displayName(of: context)): bridge error: \(message)")
        case .disconnected(let reason):
            event("\(displayName(of: context)): bridge disconnected: \(reason)")
            lock.lock()
            context.bridge = nil
            lock.unlock()
            // Reconnect while the VM is still running (e.g. guest service restart).
            if let vm = context.vmInstanceID, backend.state(of: vm) == .running {
                Task { [weak self, weak context] in
                    guard let self, let context else { return }
                    try? await self.connectBridge(context)
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
        guard let context = context(forKey: stream.contextKey) else { return }
        try? sendToDevice(stream.recipientDeviceID, context: context, type: .outputDelta,
                          conversationID: stream.conversationID,
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
        let contextKey = session.contextKey
        lock.unlock()

        guard let frame = try? TransportFrame.decode(Data(text.utf8)) else {
            var error = TransportFrame(type: .error)
            error.message = "malformed frame"
            sendFrame(error, over: connection)
            return
        }

        // Tailnet membership is transport only — nothing is served before the
        // device proves possession of a key paired to the target agent.
        guard let deviceID = authenticatedDevice,
              let contextKey, let context = context(forKey: contextKey) else {
            handleWSHello(frame, session: sessionFor(connection), connection: connection)
            return
        }

        switch frame.type {
        case .envelope:
            guard let envelope = frame.envelope, envelope.senderDeviceID == deviceID else { return }
            if processInboundEnvelope(envelope, context: context) {
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
        // The instance ID names the agent this session talks to — and only
        // devices paired to THAT agent get in. A device paired to a different
        // agent is indistinguishable from an unpaired one here.
        guard let context = resolveContext(instanceID: instanceID) else {
            sendFrame(TransportFrame(type: .denied), over: connection)
            connection.close()
            return
        }
        guard let entry = deviceEntry(deviceID, in: context), entry.revokedAt == nil else {
            // Revoked and unknown devices are distinguishable on purpose: the
            // phone shows "revoked" only when this agent actually revoked it.
            if deviceEntry(deviceID, in: context) != nil {
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
        session.contextKey = context.key
        // One live session per device: a reconnect supersedes the old socket.
        if let previous = wsByDevice[deviceID], previous != ObjectIdentifier(connection),
           let stale = wsSessions[previous]?.connection {
            stale.close()
        }
        wsByDevice[deviceID] = ObjectIdentifier(connection)
        let epoch = context.registry.epoch
        lock.unlock()

        var welcome = TransportFrame(type: .welcome)
        welcome.epoch = epoch
        welcome.macDeviceID = identity.deviceID
        sendFrame(welcome, over: connection)
        sendStatusFrame(over: connection, context: context)
        event("device \(entry.displayName) connected to \(displayName(of: context))")

        // Replay this agent's queued mail for the device; the phone acks and
        // deduplicates via its replay window.
        let scope = context.record != nil ? context.key : nil
        for stored in mailbox.fetch(recipient: deviceID, instanceID: scope, after: 0, limit: 500) {
            var envelopeFrame = TransportFrame(type: .envelope)
            envelopeFrame.envelope = stored.envelope
            sendFrame(envelopeFrame, over: connection)
        }
        startStatusTimerIfNeeded()
    }

    private func pushEnvelopeIfConnected(_ envelope: EncryptedEnvelope, instanceID: String?) {
        lock.lock()
        let session = wsByDevice[envelope.recipientDeviceID].flatMap { wsSessions[$0] }
        // Only the session bound to the owning agent gets the live push.
        let connection = (instanceID == nil || session?.contextKey == instanceID) ? session?.connection : nil
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

    private func sendStatusFrame(over connection: WebSocketConnection, context: AgentContext) {
        var status = TransportFrame(type: .status)
        let state = context.vmInstanceID.map { backend.state(of: $0) } ?? .notCreated
        status.vmState = state.rawValue
        lock.lock()
        status.bridgeConnected = context.bridge != nil
        status.epoch = context.registry.epoch
        lock.unlock()
        sendFrame(status, over: connection)
    }

    /// Push current sandbox status to every authenticated session, each in
    /// terms of its own agent.
    func broadcastStatus() {
        lock.lock()
        let live = wsByDevice.values.compactMap { wsSessions[$0] }
            .compactMap { session -> (WebSocketConnection, String)? in
                guard let key = session.contextKey else { return nil }
                return (session.connection, key)
            }
        lock.unlock()
        for (connection, key) in live {
            guard let context = context(forKey: key) else { continue }
            sendStatusFrame(over: connection, context: context)
        }
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
                "epoch": Int(currentEpoch),
                "instance_id": currentInstanceID,
                "agents": agentRecords().count,
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
            lock.lock()
            let session = pairingSessions[parts[1]]
            let epoch = session.flatMap { contexts[$0.targetContextKey]?.registry.epoch } ?? 1
            lock.unlock()
            guard let session else { return .error(404, "unknown pairing id") }
            guard let credential = session.encryptedCredential else { return .error(404, "not issued yet") }
            return .json(["ciphertext": Base64URL.encode(credential), "epoch": Int(epoch)])
        default:
            return .error(404, "not found")
        }
    }

    /// Synchronously run an async lifecycle operation for an admin route.
    private func runBlocking(timeout: TimeInterval = 300,
                             _ operation: @escaping @Sendable () async -> String) -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutputCollector()
        Task {
            box.append(await operation())
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return "error: timed out" }
        return box.text
    }

    /// Local-only admin endpoints used by the E2E harness and the GUI. This
    /// server is never exposed through the tailnet proxy.
    private func routeAdmin(_ request: HTTPServer.Request) -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == "admin" else { return .error(404, "not found") }
        let rest = Array(parts.dropFirst())
        switch (request.method, rest.first ?? "") {
        case ("GET", "packs"):
            let packs = PackLoader.availablePacks(in: paths.packsDirectory).map { pack -> [String: Any] in
                ["dir": pack.directoryName, "id": pack.manifest.id,
                 "name": pack.manifest.name, "version": pack.manifest.version]
            }
            return .json(["packs": packs])
        case ("POST", "agents") where rest.count == 1:
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let packDir = object["pack_dir"] else { return .error(400, "pack_dir required") }
            let name = object["name"]
            let collector = OutputCollector()
            let result = runBlocking { [weak self] in
                guard let self else { return "error: hub gone" }
                do {
                    let record = try await self.createAgent(fromPackDirectory: packDir, displayName: name)
                    collector.append(record.instanceID)
                    return "ok"
                } catch {
                    return "error: \(error)"
                }
            }
            guard result == "ok" else { return .error(500, result) }
            return .json(["instance_id": collector.text])
        case ("GET", "agents"):
            let agents = agentSummaries().map { summary -> [String: Any] in
                var payload: [String: Any] = [
                    "instance_id": summary.record.instanceID,
                    "pack_id": summary.record.packID,
                    "name": summary.record.displayName,
                    "pack_dir": summary.record.packDirectoryName,
                    "vm_state": summary.vmState.rawValue,
                    "bridge_connected": summary.bridgeConnected,
                    "epoch": Int(summary.epoch),
                    "devices": pairedDevices(instanceID: summary.record.instanceID).map { device -> [String: Any] in
                        ["id": device.id, "name": device.name, "revoked": device.revoked,
                         "fingerprint": device.fingerprint]
                    }
                ]
                if let status = summary.agentStatus {
                    payload["codex_installed"] = status.installed
                    payload["codex_logged_in"] = status.loggedIn
                    payload["codex_version"] = status.version ?? ""
                }
                return payload
            }
            return .json(["agents": agents])
        case (_, "agents") where rest.count == 3:
            return routeAgentAdmin(request, instanceID: rest[1], action: rest[2])
        case ("POST", "pairing") where rest.count == 3 && rest[2] == "approve":
            return resolvePendingPairing(pairingID: rest[1], approved: true)
                ? .json(["result": "ok"])
                : .error(404, "no pairing awaiting approval")
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
                "epoch": Int(currentEpoch),
                "devices": devices,
                "agents": agentRecords().count,
                "mac_fingerprint": identity.publicIdentity.fingerprint,
                "tailnet": tailnetStatus.label
            ])
        case ("POST", "revoke"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let deviceID = object["device_id"] else { return .error(400, "device_id required") }
            revokeDevice(deviceID, instanceID: object["instance_id"])
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
            let baseImage = defaultBaseImagePath
                ?? ProcessInfo.processInfo.environment["CHARIOT_BASE_IMAGE"] ?? ""
            let result = runBlocking { [weak self] in
                guard let self else { return "error: hub gone" }
                do {
                    switch action {
                    case "start":
                        _ = try await self.ensureInstance(configuration: SandboxConfiguration(
                            baseImagePath: baseImage))
                        try await self.startVM()
                    case "stop": try await self.stopVM()
                    case "reset": try await self.resetVM()
                    default: return "unknown action"
                    }
                    return "ok"
                } catch {
                    return "error: \(error)"
                }
            }
            return .json(["result": result, "vm_state": vmState.rawValue])
        case ("GET", "agent"):
            return .json([
                "installed": agentStatus?.installed ?? false,
                "version": agentStatus?.version ?? "",
                "logged_in": agentStatus?.loggedIn ?? false,
                "install_error": agentStatus?.installError ?? ""
            ])
        case ("POST", "agent") where rest.count == 2 && rest[1] == "login":
            return startLoginAndAwaitURL(instanceID: nil)
        case ("POST", "devaccess"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let action = object["action"] else { return .error(400, "action required") }
            if action == "enable" {
                do {
                    let info = try enableDeveloperAccess(instanceID: object["instance_id"])
                    return .json(["port": Int(info.port), "command": info.command,
                                  "instructions": info.instructions])
                } catch {
                    return .error(500, "\(error)")
                }
            } else {
                disableDeveloperAccess(instanceID: object["instance_id"])
                return .json(["disabled": true])
            }
        case ("POST", "conversation"):
            return runConversation(request, instanceID: nil)
        default:
            return .error(404, "not found")
        }
    }

    /// Per-agent admin: /admin/agents/<instance-uuid>/<action>.
    private func routeAgentAdmin(_ request: HTTPServer.Request, instanceID: String,
                                 action: String) -> HTTPServer.Response {
        guard let _ = try? requireContext(instanceID) else { return .error(404, "unknown agent") }
        switch (request.method, action) {
        case ("POST", "vm"):
            guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
                  let vmAction = object["action"] else { return .error(400, "action required") }
            let result = runBlocking { [weak self] in
                guard let self else { return "error: hub gone" }
                do {
                    switch vmAction {
                    case "start": try await self.startAgent(instanceID)
                    case "stop": try await self.stopAgent(instanceID)
                    case "reset": try await self.resetAgent(instanceID)
                    default: return "unknown action"
                    }
                    return "ok"
                } catch {
                    return "error: \(error)"
                }
            }
            return .json(["result": result, "vm_state": vmState(of: instanceID).rawValue])
        case ("POST", "pairing"):
            do {
                let payload = try startPairingSession(instanceID: instanceID)
                return .data(try CanonicalCoding.encode(payload))
            } catch {
                return .error(500, "\(error)")
            }
        case ("POST", "conversation"):
            return runConversation(request, instanceID: instanceID)
        case ("POST", "login"):
            return startLoginAndAwaitURL(instanceID: instanceID)
        default:
            return .error(404, "not found")
        }
    }

    /// Synchronous local prompt for testing the bridge path.
    private func runConversation(_ request: HTTPServer.Request, instanceID: String?) -> HTTPServer.Response {
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String],
              let text = object["text"] else { return .error(400, "text required") }
        let conversationID = object["conversation_id"] ?? "local"
        let semaphore = DispatchSemaphore(value: 0)
        let collector = OutputCollector()
        do {
            try sendLocalPrompt(text, instanceID: instanceID, conversationID: conversationID,
                                onDelta: { collector.append($0) },
                                onCompleted: { code in collector.finish(code); semaphore.signal() })
        } catch {
            return .error(503, "\(error)")
        }
        if semaphore.wait(timeout: .now() + 180) == .timedOut {
            return .error(504, "agent timed out")
        }
        return .json(["output": collector.text, "exit_code": collector.exitCode])
    }

    private func startLoginAndAwaitURL(instanceID: String?) -> HTTPServer.Response {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutputCollector()
        waitForAuthURL(timeout: 25) { url in
            box.append(url ?? "")
            semaphore.signal()
        }
        do {
            try startCodexLogin(instanceID: instanceID)
        } catch {
            return .error(503, "\(error)")
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return box.text.isEmpty ? .error(504, "no auth URL from guest")
                                : .json(["auth_url": box.text])
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
