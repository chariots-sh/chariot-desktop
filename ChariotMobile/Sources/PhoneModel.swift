import Foundation
import SwiftUI
import CryptoKit
import Network
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

enum AppPhase {
    case welcome, scanner, pairing, paired, revoked
}

/// Connection detail while paired. Tailscale gives reachability, not a promise
/// of an eternally open socket: iOS suspends the app, so the WebSocket is
/// re-established on foregrounding and network changes, resuming from the
/// last acknowledged message.
enum ConnectionState: Equatable {
    case unpaired
    case tailscaleUnavailable
    case connecting
    case pairing
    case connected
    case macOffline
    case accessDenied
    case revoked

    var label: String {
        switch self {
        case .unpaired: return "Not paired"
        case .tailscaleUnavailable: return "Tailscale unavailable"
        case .connecting: return "Connecting…"
        case .pairing: return "Pairing…"
        case .connected: return "Connected"
        case .macOffline: return "Mac offline"
        case .accessDenied: return "Access denied"
        case .revoked: return "Revoked"
        }
    }
}

struct PhoneChatMessage: Identifiable, Codable {
    var id: String
    var role: String   // "user" | "agent" | "system"
    var text: String
    var pending: Bool = false
    var at: Date = Date()
}

/// Everything the phone persists about its paired Mac.
struct ConnectionRecord: Codable {
    var macIdentity: PublicDeviceIdentity
    var macDisplayName: String
    var serviceURL: String     // https://agentbox-….ts.net (or loopback in dev)
    var instanceID: String
    var tlsPublicKeyHash: String?
    var credential: DeviceCredential
    var epoch: UInt32
    var outboundSequence: UInt64
    var replayWindow: ReplayWindow
    var pairedAt: Date
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var connectionState: ConnectionState = .unpaired
    @Published var connectionDetail = ""   // actionable guidance for failures
    @Published var pairingStatus = ""
    @Published var chat: [PhoneChatMessage] = []
    @Published var lastActivity: Date?
    @Published var macOnline = false
    @Published var sandboxState = "unknown"

    private(set) var identity: DeviceIdentity?
    private(set) var record: ConnectionRecord?
    private var transport: TailscaleTransport?
    /// Streamed agent output keyed by originating request/message ID.
    private var activeAgentMessages: [String: String] = [:]

    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()

    private let store = LocalStore()

    var connectionMode: String {
        guard let transport else { return "—" }
        return "\(transport.modeDescription) — \(connectionState.label)"
    }

    init() {
        identity = store.loadIdentity()
        record = store.loadConnection()
        chat = store.loadChat()
        if let record {
            transport = TailscaleTransport(serviceURL: record.serviceURL,
                                           tlsPublicKeyHash: record.tlsPublicKeyHash)
            phase = .paired
            wireTransport()
            connect()
        } else if store.hasLegacyConnection() {
            // Migration from the CloudKit transport: message history is kept,
            // but trust is never transferred silently — one new Tailscale QR
            // pairing is required.
            store.clearConnection()
            appendSystemMessage("Chariot now connects over Tailscale. Your history is preserved, but you need to pair once more: install the Tailscale app on this phone, then scan a fresh QR code from the Mac.")
            phase = .welcome
        }

        // Reconnect on network path changes (Wi-Fi ↔ cellular, VPN up/down).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.record != nil else { return }
                if path.status == .satisfied, self.connectionState != .connected {
                    self.reconnectAttempts = 0
                    self.connect()
                }
            }
        }
        pathMonitor.start(queue: .global())

        // Automated-pairing hook for the E2E harness (simulator).
        let arguments = ProcessInfo.processInfo.arguments
        // Diagnostic probe: --tls-probe <url> <pin|-> exercises the pinned TLS
        // path and prints the outcome to the attached console.
        if let index = arguments.firstIndex(of: "--tls-probe"), arguments.count > index + 2 {
            let urlString = arguments[index + 1]
            let pin = arguments[index + 2] == "-" ? nil : arguments[index + 2]
            Task.detached {
                let session = URLSession(configuration: .default,
                                         delegate: TransportSessionDelegate(pinnedSPKIHash: pin),
                                         delegateQueue: nil)
                do {
                    let (data, response) = try await session.data(from: URL(string: urlString)!)
                    print("[chariot-tls] PROBE \(urlString) ok status=\((response as? HTTPURLResponse)?.statusCode ?? 0) body=\(String(data: data.prefix(120), encoding: .utf8) ?? "")")
                } catch {
                    let ns = error as NSError
                    print("[chariot-tls] PROBE \(urlString) FAIL domain=\(ns.domain) code=\(ns.code)")
                    var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                    while let u = underlying {
                        print("[chariot-tls] PROBE underlying: \(u.domain) \(u.code) ssl=\(u.userInfo["_kCFNetworkCFStreamSSLErrorOriginalValue"] ?? "-")")
                        underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
                    }
                }
            }
        }
        if let index = arguments.firstIndex(of: "--pair-with"), arguments.count > index + 1 {
            pair(payloadJSON: arguments[index + 1])
        } else if let payload = ProcessInfo.processInfo.environment["CHARIOT_PAIRING_JSON"] {
            pair(payloadJSON: payload)
        }
        if let index = arguments.firstIndex(of: "--send"), arguments.count > index + 1 {
            let text = arguments[index + 1]
            Task { @MainActor in
                while self.phase != .paired { try? await Task.sleep(nanoseconds: 500_000_000) }
                self.send(text)
            }
        }
    }

    var fingerprint: String {
        identity?.publicIdentity.fingerprint ?? "—"
    }

    // MARK: Pairing

    func pair(payloadJSON: String) {
        phase = .pairing
        connectionState = .pairing
        pairingStatus = "Validating code…"
        Task {
            do {
                try await performPairing(payloadJSON: payloadJSON)
                self.phase = .paired
                self.connect()
            } catch {
                self.pairingStatus = "Pairing failed: \(describe(error))"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.phase = self.record == nil ? .scanner : .paired
                self.connectionState = self.record == nil ? .unpaired : .connecting
            }
        }
    }

    private func performPairing(payloadJSON: String) async throws {
        // Step 1: validate type, version, expiry, entropy, and service URL.
        let payload = try PairingPayload.validate(json: Data(payloadJSON.utf8))
        guard let transport = TailscaleTransport(serviceURL: payload.serviceURL,
                                                 tlsPublicKeyHash: payload.tlsPublicKeyHash) else {
            throw AgentLinkError.malformedMessage("unsupported service URL")
        }

        // Step 2: reach the service over the phone's Tailscale VPN and confirm
        // the pairing session matches the QR.
        pairingStatus = "Contacting \(payload.macDisplayName) over Tailscale…"
        let rendezvous = try await transport.fetchPairingRecord(pairingID: payload.pairingID)
        guard rendezvous.macDeviceID == payload.macDeviceID,
              rendezvous.macSigningPublicKey == payload.macSigningPublicKey,
              rendezvous.macPairingPublicKey == payload.macPairingPublicKey else {
            throw AgentLinkError.malformedMessage("pairing session does not match QR payload")
        }
        guard rendezvous.state == "waiting" else {
            throw TransportError.conflict
        }

        // Long-lived identity.
        let identity = self.identity ?? DeviceIdentity()
        self.identity = identity
        store.saveIdentity(identity)

        // Ephemeral key + encrypted, signed response.
        pairingStatus = "Exchanging keys…"
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let pairingKey = try PairingCrypto.deriveKey(ephemeralPrivate: ephemeral,
                                                     peerEphemeralPublic: payload.macPairingPublicKey,
                                                     pairingSecret: payload.pairingSecret)
        var response = PairingResponse(mobile: identity.publicIdentity,
                                       mobileDisplayName: UIDevice.current.name,
                                       mobileEphemeralPublicKey: ephemeral.publicKey.rawRepresentation)
        try response.sign(with: identity.signingKey)
        let sealed = try PairingCrypto.seal(response, key: pairingKey)
        try await transport.claimPairing(pairingID: payload.pairingID,
                                         ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                                         encryptedResponse: sealed)

        // Wait for approval + credential.
        pairingStatus = "Waiting for approval on the Mac…"
        var credentialData: (ciphertext: Data, epoch: UInt32)?
        for _ in 0..<45 {
            if let result = try? await transport.fetchCredential(pairingID: payload.pairingID) {
                credentialData = result
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard let credentialData else {
            throw AgentLinkError.malformedMessage("Mac did not approve in time")
        }
        // Pin and verify the Mac application identity (independent of the
        // network: tailnet membership is never treated as authorization).
        let credential = try PairingCrypto.open(DeviceCredential.self,
                                                combined: credentialData.ciphertext, key: pairingKey)
        try credential.verify(pinnedMacSigningKey: payload.macSigningPublicKey)
        guard credential.mobile.deviceID == identity.deviceID else {
            throw AgentLinkError.malformedMessage("credential bound to a different device")
        }

        // Persist; ephemeral state drops out of scope.
        let connection = ConnectionRecord(macIdentity: credential.mac,
                                          macDisplayName: payload.macDisplayName,
                                          serviceURL: payload.serviceURL,
                                          instanceID: payload.instanceID,
                                          tlsPublicKeyHash: payload.tlsPublicKeyHash,
                                          credential: credential,
                                          epoch: credentialData.epoch,
                                          outboundSequence: 0,
                                          replayWindow: ReplayWindow(),
                                          pairedAt: Date())
        self.record = connection
        self.transport = transport
        store.saveConnection(connection)
        wireTransport()
        appendSystemMessage("Paired with \(payload.macDisplayName) via \(transport.modeDescription). Fingerprints — Mac: \(credential.mac.fingerprint), phone: \(identity.publicIdentity.fingerprint)")
    }

    // MARK: WebSocket lifecycle

    private func wireTransport() {
        transport?.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handleFrame(frame) }
        }
        transport?.onDisconnect = { [weak self] error in
            Task { @MainActor in self?.handleDisconnect(error) }
        }
    }

    func connect() {
        guard record != nil, let transport else { return }
        guard connectionState != .revoked, connectionState != .accessDenied else { return }
        connectionState = .connecting
        connectionDetail = ""
        transport.connectWebSocket()
    }

    /// Foreground reconnect hook (scene became active).
    func reconnectIfNeeded() {
        guard record != nil else { return }
        if connectionState != .connected {
            reconnectAttempts = 0
            connect()
        }
    }

    private func handleDisconnect(_ error: TransportError?) {
        guard record != nil else { return }
        macOnline = false
        switch error {
        case .revoked:
            enterRevokedState()
            return
        case .denied, .tlsPinMismatch:
            connectionState = .accessDenied
            connectionDetail = describeTransportFailure(error!, host: transport?.serviceURL.host ?? "")
            return
        case .unreachable(let code):
            switch code {
            case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .dataNotAllowed:
                connectionState = .tailscaleUnavailable
            default:
                connectionState = .macOffline
            }
            connectionDetail = describeTransportFailure(error!, host: transport?.serviceURL.host ?? "")
        default:
            connectionState = .macOffline
            connectionDetail = "Connection lost. Retrying…"
        }
        scheduleReconnect()
    }

    /// Bounded exponential backoff with jitter; iOS suspends this in the
    /// background, and foreground/network-change hooks reset it.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        let base = min(30.0, pow(2.0, Double(min(reconnectAttempts, 5))))
        let jittered = base * Double.random(in: 0.8...1.2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(jittered * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.connect() }
        }
    }

    private func handleFrame(_ frame: TransportFrame) {
        switch frame.type {
        case .challenge:
            guard let record, let identity, let nonce = frame.nonce else { return }
            var hello = TransportFrame(type: .hello)
            hello.deviceID = identity.deviceID
            hello.instanceID = record.instanceID
            hello.signature = try? TransportAuth.signature(nonce: nonce,
                                                           deviceID: identity.deviceID,
                                                           instanceID: record.instanceID,
                                                           signingKey: identity.signingKey)
            transport?.sendFrame(hello)
        case .welcome:
            reconnectAttempts = 0
            connectionState = .connected
            connectionDetail = ""
            macOnline = true
            if var record, let epoch = frame.epoch, epoch != record.epoch {
                record.epoch = epoch
                self.record = record
                store.saveConnection(record)
            }
            flushOutbox()
        case .envelope:
            if let envelope = frame.envelope { handleEnvelope(envelope) }
        case .ack:
            // The Mac holds our message durably now; clear it from the outbox.
            for id in frame.messageIDs ?? [] {
                store.removeOutbox(id)
                if let index = chat.firstIndex(where: { $0.id == id }) {
                    chat[index].pending = false
                }
            }
            store.saveChat(chat)
            lastActivity = Date()
        case .status:
            macOnline = true
            if let vm = frame.vmState { sandboxState = vm }
            if var record, let epoch = frame.epoch, epoch != record.epoch {
                record.epoch = epoch
                self.record = record
                store.saveConnection(record)
            }
        case .revoked:
            enterRevokedState()
        case .denied:
            connectionState = .accessDenied
            connectionDetail = describeTransportFailure(.denied, host: transport?.serviceURL.host ?? "")
        case .error:
            connectionDetail = frame.message ?? ""
        default:
            break
        }
    }

    private func handleEnvelope(_ envelope: EncryptedEnvelope) {
        guard var record, let identity else { return }
        var ackable = true
        do {
            let session = try SessionCrypto(localIdentity: identity,
                                            peerPublicIdentity: record.macIdentity,
                                            epoch: record.epoch)
            let message = try session.open(envelope)
            do {
                try record.replayWindow.accept(messageID: message.messageID, sequence: message.sequence)
                handleIncoming(message)
                self.record = record
                store.saveConnection(record)
                store.saveChat(chat)
            } catch {
                // Duplicate delivery (ack was lost) — ack again, don't re-apply.
            }
        } catch {
            // Undecryptable (foreign epoch, tamper): drop without ack so the
            // envelope survives until the epoch settles.
            ackable = false
        }
        if ackable {
            var ack = TransportFrame(type: .ack)
            ack.messageIDs = [envelope.messageID]
            transport?.sendFrame(ack)
            lastActivity = Date()
        }
    }

    // MARK: Conversation

    func send(_ text: String) {
        guard record != nil, identity != nil else { return }
        let messageID = UUID().uuidString.lowercased()
        chat.append(PhoneChatMessage(id: messageID, role: "user", text: text, pending: true))
        store.saveChat(chat)
        // Durable local outbox: committed before any network. Cleared only by
        // the Mac's acknowledgment; duplicates are deduplicated by message ID.
        store.enqueueOutbox(OutboxItem(messageID: messageID, text: text, createdAt: Date()))
        flushOutbox()
    }

    func flushOutbox() {
        guard var record, let identity, let transport, transport.isConnected else { return }
        for item in store.pendingOutbox() {
            record.outboundSequence += 1
            let message = AgentMessage(messageID: item.messageID,
                                       conversationID: "default",
                                       senderDeviceID: identity.deviceID,
                                       sequence: record.outboundSequence,
                                       type: .conversationSend,
                                       body: .object(["text": .string(item.text)]))
            guard let session = try? SessionCrypto(localIdentity: identity,
                                                   peerPublicIdentity: record.macIdentity,
                                                   epoch: record.epoch),
                  let envelope = try? session.seal(message) else { continue }
            var frame = TransportFrame(type: .envelope)
            frame.envelope = envelope
            transport.sendFrame(frame)
        }
        self.record = record
        store.saveConnection(record)
    }

    /// Ask the Mac for sandbox status.
    func requestSandboxStatus() {
        guard var record, let identity, let transport, transport.isConnected else { return }
        record.outboundSequence += 1
        let message = AgentMessage(conversationID: "control",
                                   senderDeviceID: identity.deviceID,
                                   sequence: record.outboundSequence,
                                   type: .sandboxStatus, body: .object([:]))
        self.record = record
        store.saveConnection(record)
        if let session = try? SessionCrypto(localIdentity: identity,
                                            peerPublicIdentity: record.macIdentity,
                                            epoch: record.epoch),
           let envelope = try? session.seal(message) {
            var frame = TransportFrame(type: .envelope)
            frame.envelope = envelope
            transport.sendFrame(frame)
        }
    }

    private func handleIncoming(_ message: AgentMessage) {
        switch message.type {
        case .outputDelta:
            let requestID = message.body["request_id"]?.stringValue ?? "unknown"
            let text = message.body["text"]?.stringValue ?? ""
            if let chatID = activeAgentMessages[requestID],
               let index = chat.firstIndex(where: { $0.id == chatID }) {
                chat[index].text += text
            } else {
                let chatMessage = PhoneChatMessage(id: UUID().uuidString, role: "agent", text: text)
                activeAgentMessages[requestID] = chatMessage.id
                chat.append(chatMessage)
            }
        case .outputCompleted:
            let requestID = message.body["request_id"]?.stringValue ?? "unknown"
            let exitCode = Int(message.body["exit_code"]?.numberValue ?? 0)
            if exitCode != 0, let chatID = activeAgentMessages[requestID],
               let index = chat.firstIndex(where: { $0.id == chatID }) {
                chat[index].text += "\n[exit code \(exitCode)]"
            }
            if let error = message.body["error"]?.stringValue {
                appendSystemMessage(error)
            }
            activeAgentMessages[requestID] = nil
        case .sandboxStatus:
            sandboxState = message.body["state"]?.stringValue ?? "unknown"
        case .deviceRevoked:
            enterRevokedState()
        default:
            break
        }
    }

    // MARK: Revocation / unpair

    private func enterRevokedState() {
        appendSystemMessage("This device was revoked by the Mac. Pair again to reconnect.")
        phase = .revoked
        connectionState = .revoked
        reconnectTask?.cancel()
        transport?.disconnect()
    }

    func unpair() {
        reconnectTask?.cancel()
        transport?.disconnect()
        record = nil
        transport = nil
        activeAgentMessages = [:]
        chat = []
        store.clearConnection()
        store.saveChat([])
        phase = .welcome
        connectionState = .unpaired
    }

    private func appendSystemMessage(_ text: String) {
        chat.append(PhoneChatMessage(id: UUID().uuidString, role: "system", text: text))
        store.saveChat(chat)
    }

    private func describe(_ error: Error) -> String {
        if let transportError = error as? TransportError {
            return describeTransportFailure(transportError, host: "the Mac")
        }
        switch error {
        case AgentLinkError.payloadExpired: return "this pairing code has expired — show a fresh one on the Mac"
        case AgentLinkError.unsupportedVersion:
            return "this QR code is from an older Chariot version — update the Mac app and show a fresh code"
        default: return "\(error)"
        }
    }
}
