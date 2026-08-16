import Foundation
import SwiftUI
import CryptoKit
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

enum AppPhase {
    case welcome, scanner, pairing, paired, revoked
}

struct PhoneChatMessage: Identifiable, Codable {
    var id: String
    var role: String   // "user" | "agent" | "system"
    var text: String
    var pending: Bool = false
    var at: Date = Date()
}

/// Everything the phone persists about its paired Mac (design §13.10).
struct ConnectionRecord: Codable {
    var macIdentity: PublicDeviceIdentity
    var macDisplayName: String
    var mailboxURL: String     // "cloudkit:<container>" or "http://127.0.0.1:…"
    var credential: DeviceCredential
    var epoch: UInt32
    var cursor: UInt64         // legacy local-mailbox cursor (kept for migration)
    var outboundSequence: UInt64
    var replayWindow: ReplayWindow
    var pairedAt: Date
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var phase: AppPhase = .welcome
    @Published var pairingStatus = ""
    @Published var chat: [PhoneChatMessage] = []
    @Published var connectionMode = "Connecting…"
    @Published var lastActivity: Date?
    @Published var lastPushAt: Date?
    @Published var macOnline = false
    @Published var sandboxState = "unknown"

    private(set) var identity: DeviceIdentity?
    private(set) var record: ConnectionRecord?
    private var transport: PhoneTransport?
    private var pollTask: Task<Void, Never>?
    /// Streamed agent output keyed by originating request/message ID.
    private var activeAgentMessages: [String: String] = [:]

    private let store = LocalStore()

    init() {
        identity = store.loadIdentity()
        record = store.loadConnection()
        chat = store.loadChat()
        if let record {
            transport = makeTransport(mailbox: record.mailboxURL)
            phase = .paired
            startPolling()
            flushOutbox()
            Task { await transport?.registerForWake(deviceID: identity?.deviceID ?? "") }
        }
        // Automated-pairing hook for the E2E harness (simulator).
        let arguments = ProcessInfo.processInfo.arguments
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

    // MARK: Pairing (design §13.7)

    func pair(payloadJSON: String) {
        phase = .pairing
        pairingStatus = "Validating code…"
        Task {
            do {
                try await performPairing(payloadJSON: payloadJSON)
                self.phase = .paired
                self.startPolling()
                await self.transport?.registerForWake(deviceID: self.identity?.deviceID ?? "")
            } catch {
                self.pairingStatus = "Pairing failed: \(describe(error))"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.phase = self.record == nil ? .scanner : .paired
            }
        }
    }

    private func performPairing(payloadJSON: String) async throws {
        let payload = try PairingPayload.validate(json: Data(payloadJSON.utf8))
        guard let transport = makeTransport(mailbox: payload.mailbox) else {
            throw AgentLinkError.malformedMessage("unsupported mailbox: \(payload.mailbox)")
        }

        // Fetch the rendezvous record and confirm it matches the QR (steps 2–3).
        // The record may lag the QR display briefly on CloudKit; retry.
        pairingStatus = "Contacting \(payload.macDisplayName)…"
        var rendezvous: PairingRendezvous?
        for _ in 0..<10 {
            do {
                rendezvous = try await transport.fetchPairingRecord(rendezvousID: payload.rendezvousID)
                break
            } catch TransportError.notFound {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        guard let rendezvous else {
            throw AgentLinkError.malformedMessage("rendezvous record not found — is the Mac online?")
        }
        guard rendezvous.macDeviceID == payload.macDeviceID,
              rendezvous.macSigningPublicKey == payload.macSigningPublicKey,
              rendezvous.macPairingPublicKey == payload.macPairingPublicKey else {
            throw AgentLinkError.malformedMessage("rendezvous record does not match QR payload")
        }
        guard rendezvous.state == "waiting" else {
            throw AgentLinkError.malformedMessage("pairing code already used")
        }

        // Long-lived identity (step 4).
        let identity = self.identity ?? DeviceIdentity()
        self.identity = identity
        store.saveIdentity(identity)

        // Ephemeral key + encrypted, signed response (steps 5–8).
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
        try await transport.claimPairing(rendezvousID: payload.rendezvousID,
                                         ephemeralPublicKey: ephemeral.publicKey.rawRepresentation,
                                         encryptedResponse: sealed)

        // Wait for approval + credential (steps 9–10).
        pairingStatus = "Waiting for approval on the Mac…"
        var credentialData: (ciphertext: Data, epoch: UInt32)?
        for _ in 0..<45 {
            if let result = try? await transport.fetchCredential(rendezvousID: payload.rendezvousID) {
                credentialData = result
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard let credentialData else {
            throw AgentLinkError.malformedMessage("Mac did not approve in time")
        }
        let credential = try PairingCrypto.open(DeviceCredential.self,
                                                combined: credentialData.ciphertext, key: pairingKey)
        try credential.verify(pinnedMacSigningKey: payload.macSigningPublicKey)
        guard credential.mobile.deviceID == identity.deviceID else {
            throw AgentLinkError.malformedMessage("credential bound to a different device")
        }

        // Persist; ephemeral state drops out of scope (steps 11–12).
        let connection = ConnectionRecord(macIdentity: credential.mac,
                                          macDisplayName: payload.macDisplayName,
                                          mailboxURL: payload.mailbox,
                                          credential: credential,
                                          epoch: credentialData.epoch,
                                          cursor: 0,
                                          outboundSequence: 0,
                                          replayWindow: ReplayWindow(),
                                          pairedAt: Date())
        self.record = connection
        self.transport = transport
        store.saveConnection(connection)
        appendSystemMessage("Paired with \(payload.macDisplayName) via \(transport.modeDescription). Fingerprints — Mac: \(credential.mac.fingerprint), phone: \(identity.publicIdentity.fingerprint)")
    }

    // MARK: Conversation

    func send(_ text: String) {
        guard record != nil, identity != nil else { return }
        let messageID = UUID().uuidString.lowercased()
        chat.append(PhoneChatMessage(id: messageID, role: "user", text: text, pending: true))
        store.saveChat(chat)
        // Durable local outbox (design §13.10): committed before any network.
        store.enqueueOutbox(OutboxItem(messageID: messageID, text: text, createdAt: Date()))
        flushOutbox()
    }

    func flushOutbox() {
        Task { await drainOutbox() }
    }

    private func drainOutbox() async {
        guard var record, let identity, let transport else { return }
        for item in store.pendingOutbox() {
            do {
                record.outboundSequence += 1
                let message = AgentMessage(messageID: item.messageID,
                                           conversationID: "default",
                                           senderDeviceID: identity.deviceID,
                                           sequence: record.outboundSequence,
                                           type: .conversationSend,
                                           body: .object(["text": .string(item.text)]))
                let session = try SessionCrypto(localIdentity: identity,
                                                peerPublicIdentity: record.macIdentity,
                                                epoch: record.epoch)
                try await transport.send(session.seal(message))
                self.record = record
                store.saveConnection(record)
                store.removeOutbox(item.messageID)
                if let index = chat.firstIndex(where: { $0.id == item.messageID }) {
                    chat[index].pending = false
                }
                store.saveChat(chat)
                lastActivity = Date()
            } catch TransportError.revoked {
                enterRevokedState()
                return
            } catch {
                break  // keep queued; retry on next flush
            }
        }
    }

    // MARK: Polling (push notifications accelerate this; design §13.12)

    func startPolling() {
        // Steady reconcile cadence: silent pushes proved too deferred to carry
        // latency alone, so poll while foregrounded (iOS suspends this loop in
        // the background; push + foreground reconcile cover the rest).
        guard pollTask == nil else { return }
        let interval: UInt64 = transport is CloudKitPhoneTransport ? 10_000_000_000 : 2_500_000_000
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func pollOnce() async {
        guard var record, let identity, let transport else { return }

        if let status = await transport.macStatus() {
            macOnline = status.reachable
            if let vmState = status.vmState { sandboxState = vmState }
            connectionMode = status.reachable ? transport.modeDescription
                                              : "\(transport.modeDescription) — unreachable, queuing"
            if let epoch = status.epoch, epoch != record.epoch {
                record.epoch = epoch
                self.record = record
                store.saveConnection(record)
            }
        }

        do {
            let envelopes = try await transport.fetchInbox(recipient: identity.deviceID)
            var processedIDs: [String] = []
            for envelope in envelopes {
                do {
                    let session = try SessionCrypto(localIdentity: identity,
                                                    peerPublicIdentity: record.macIdentity,
                                                    epoch: record.epoch)
                    let message = try session.open(envelope)
                    try record.replayWindow.accept(messageID: message.messageID, sequence: message.sequence)
                    handleIncoming(message)
                } catch {
                    // Undecryptable (foreign epoch, tamper) — drop but ack so it
                    // doesn't wedge the mailbox.
                }
                processedIDs.append(envelope.messageID)
            }
            self.record = record
            store.saveConnection(record)
            if !processedIDs.isEmpty {
                lastActivity = Date()
                try? await transport.acknowledge(recipient: identity.deviceID, messageIDs: processedIDs)
                store.saveChat(chat)
            }
        } catch TransportError.revoked {
            enterRevokedState()
        } catch {
            // transient; next poll retries
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

    /// Ask the Mac for sandbox status (works over any transport).
    func requestSandboxStatus() {
        guard var record, let identity, let transport else { return }
        record.outboundSequence += 1
        let message = AgentMessage(conversationID: "control",
                                   senderDeviceID: identity.deviceID,
                                   sequence: record.outboundSequence,
                                   type: .sandboxStatus, body: .object([:]))
        self.record = record
        store.saveConnection(record)
        Task {
            if let session = try? SessionCrypto(localIdentity: identity,
                                                peerPublicIdentity: record.macIdentity,
                                                epoch: record.epoch),
               let envelope = try? session.seal(message) {
                try? await transport.send(envelope)
            }
        }
    }

    // MARK: Revocation / unpair

    private func enterRevokedState() {
        appendSystemMessage("This device was revoked by the Mac. Pair again to reconnect.")
        phase = .revoked
        pollTask?.cancel()
        pollTask = nil
    }

    func unpair() {
        pollTask?.cancel()
        pollTask = nil
        record = nil
        transport = nil
        activeAgentMessages = [:]
        chat = []
        store.clearConnection()
        store.saveChat([])
        phase = .welcome
    }

    private func appendSystemMessage(_ text: String) {
        chat.append(PhoneChatMessage(id: UUID().uuidString, role: "system", text: text))
        store.saveChat(chat)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case TransportError.conflict: return "this code was already used"
        case TransportError.notFound: return "pairing session not found"
        case AgentLinkError.payloadExpired: return "the code has expired — show a fresh one on the Mac"
        default: return "\(error)"
        }
    }
}
