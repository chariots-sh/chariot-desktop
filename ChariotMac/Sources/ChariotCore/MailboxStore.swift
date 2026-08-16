import Foundation
import AgentLinkKit

/// Durable outbound queue for phone-bound envelopes: opaque encrypted
/// envelopes, per-recipient fetch, acknowledgement deletes, expiry. Persisted
/// as JSON on disk so a restart never loses queued messages; envelopes leave
/// the queue only when the recipient acknowledges them over the WebSocket.
public final class MailboxStore: @unchecked Sendable {
    public struct StoredEnvelope: Codable {
        public let serial: UInt64
        public let envelope: EncryptedEnvelope
        /// Which agent instance queued this envelope (Milestone 1: per-agent
        /// sessions replay only their own instance's mail). Optional so
        /// mailboxes written before the fleet existed still decode.
        public let instanceID: String?

        init(serial: UInt64, envelope: EncryptedEnvelope, instanceID: String? = nil) {
            self.serial = serial
            self.envelope = envelope
            self.instanceID = instanceID
        }
    }

    private struct State: Codable {
        var nextSerial: UInt64 = 1
        var envelopes: [StoredEnvelope] = []
    }

    private var state = State()
    private let lock = NSLock()
    private let fileURL: URL
    public var onDeposit: (@Sendable (EncryptedEnvelope, String?) -> Void)?

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("mailbox.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? CanonicalCoding.decoder().decode(State.self, from: data) {
            state = loaded
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    @discardableResult
    public func deposit(_ envelope: EncryptedEnvelope, instanceID: String? = nil) -> UInt64 {
        lock.lock()
        // Deduplicate by message ID (design §4.6).
        if let existing = state.envelopes.first(where: { $0.envelope.messageID == envelope.messageID }) {
            lock.unlock()
            return existing.serial
        }
        let serial = state.nextSerial
        state.nextSerial += 1
        state.envelopes.append(StoredEnvelope(serial: serial, envelope: envelope, instanceID: instanceID))
        persistLocked()
        lock.unlock()
        onDeposit?(envelope, instanceID)
        return serial
    }

    /// Envelopes queued for a recipient. `instanceID` scopes the replay to
    /// one agent's mail; envelopes stored without an instance (pre-fleet)
    /// match any instance.
    public func fetch(recipient: String, instanceID: String? = nil,
                      after serial: UInt64, limit: Int = 50) -> [StoredEnvelope] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return state.envelopes
            .filter { $0.envelope.recipientDeviceID == recipient && $0.serial > serial && $0.envelope.expiresAt > now }
            .filter { instanceID == nil || $0.instanceID == nil || $0.instanceID == instanceID }
            .sorted { $0.serial < $1.serial }
            .prefix(limit)
            .map { $0 }
    }

    /// Acknowledge processed messages: delete them from the mailbox.
    public func acknowledge(recipient: String, messageIDs: [String]) {
        lock.lock(); defer { lock.unlock() }
        state.envelopes.removeAll {
            $0.envelope.recipientDeviceID == recipient && messageIDs.contains($0.envelope.messageID)
        }
        persistLocked()
    }

    public func expireStale() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        state.envelopes.removeAll { $0.envelope.expiresAt <= now }
        persistLocked()
    }

    public func pendingCount(recipient: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return state.envelopes.filter { $0.envelope.recipientDeviceID == recipient }.count
    }
}
