import Foundation
import CloudKit
import AgentLinkKit

/// CloudKit implementation of the encrypted mailbox (design §4.6, §13.9).
/// Uses a custom zone in the private database of the shared container — both
/// devices are signed into the same iCloud account (design §4.7 initial
/// assumption). CloudKit only ever sees routing metadata and ciphertext.
public final class CloudKitMailbox: @unchecked Sendable {
    public static let zoneName = "AgentLinkZone"
    public static let envelopeType = "Envelope"
    public static let pairingType = "PairingSession"

    public let container: CKContainer
    public let database: CKDatabase
    let zoneID: CKRecordZone.ID

    public enum MailboxError: Error {
        case notSignedIn(String)
        case conflict          // atomic-claim lost (design §13.7 step 8)
        case recordMissing
        case underlying(Error)
    }

    public init(containerIdentifier: String) {
        self.container = CKContainer(identifier: containerIdentifier)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Verify the iCloud account, create the custom zone, and bootstrap the
    /// record schema (idempotent). CloudKit's development environment creates
    /// record types just-in-time on first save; queries against a type that has
    /// never been saved fail, so we save-and-delete a marker envelope once.
    public func prepare() async throws {
        let status = try await container.accountStatus()
        guard status == .available else {
            throw MailboxError.notSignedIn("iCloud account status: \(status.rawValue)")
        }
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

        let marker = EncryptedEnvelope.schemaBootstrapMarker
        try await deposit(marker)
        try await acknowledge(messageIDs: [marker.messageID])
    }

    // MARK: Envelopes

    public func deposit(_ envelope: EncryptedEnvelope) async throws {
        let recordID = CKRecord.ID(recordName: "env-\(envelope.messageID)", zoneID: zoneID)
        let record = CKRecord(recordType: Self.envelopeType, recordID: recordID)
        record["protocolVersion"] = envelope.version as CKRecordValue
        record["messageID"] = envelope.messageID as CKRecordValue
        record["conversationID"] = envelope.conversationID as CKRecordValue
        record["senderDeviceID"] = envelope.senderDeviceID as CKRecordValue
        record["recipientDeviceID"] = envelope.recipientDeviceID as CKRecordValue
        record["sequence"] = Int64(envelope.sequence) as CKRecordValue
        record["epoch"] = Int64(envelope.epoch) as CKRecordValue
        record["createdAt"] = envelope.createdAt as CKRecordValue
        record["expiresAt"] = envelope.expiresAt as CKRecordValue
        record["nonce"] = envelope.nonce as CKRecordValue
        record["ciphertext"] = envelope.ciphertext as CKRecordValue
        record["signature"] = envelope.signature as CKRecordValue
        do {
            // Deduplicate by message ID: an existing record wins (design §4.6).
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return
        }
    }

    /// Fetch pending envelopes addressed to a device, oldest first.
    public func fetchEnvelopes(recipient: String, limit: Int = 50) async throws -> [EncryptedEnvelope] {
        let predicate = NSPredicate(format: "recipientDeviceID == %@", recipient)
        let query = CKQuery(recordType: Self.envelopeType, predicate: predicate)
        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (results, _) = try await database.records(matching: query, inZoneWith: zoneID,
                                                      desiredKeys: nil, resultsLimit: limit)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return []  // record type not created yet — an empty mailbox
        }
        var envelopes: [EncryptedEnvelope] = []
        for (_, result) in results {
            guard let record = try? result.get(), let envelope = Self.envelope(from: record) else { continue }
            if envelope.expiresAt <= Date() { continue }
            envelopes.append(envelope)
        }
        return envelopes.sorted {
            $0.sequence != $1.sequence ? $0.sequence < $1.sequence : $0.createdAt < $1.createdAt
        }
    }

    /// Acknowledge processed envelopes by deleting their records (design §13.9).
    public func acknowledge(messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let ids = messageIDs.map { CKRecord.ID(recordName: "env-\($0)", zoneID: zoneID) }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
    }

    static func envelope(from record: CKRecord) -> EncryptedEnvelope? {
        guard let json = try? JSONSerialization.data(withJSONObject: [
            "version": record["protocolVersion"] as? Int ?? 1,
            "message_id": record["messageID"] as? String ?? "",
            "conversation_id": record["conversationID"] as? String ?? "",
            "sender_device_id": record["senderDeviceID"] as? String ?? "",
            "recipient_device_id": record["recipientDeviceID"] as? String ?? "",
            "sequence": (record["sequence"] as? Int64).map(UInt64.init) ?? 0,
            "epoch": (record["epoch"] as? Int64).map(UInt32.init) ?? 0,
            "created_at": ISO8601DateFormatter().string(from: record["createdAt"] as? Date ?? .distantPast),
            "expires_at": ISO8601DateFormatter().string(from: record["expiresAt"] as? Date ?? .distantPast),
            "nonce": Base64URL.encode(record["nonce"] as? Data ?? Data()),
            "ciphertext": Base64URL.encode(record["ciphertext"] as? Data ?? Data()),
            "signature": Base64URL.encode(record["signature"] as? Data ?? Data())
        ]) else { return nil }
        return try? CanonicalCoding.decoder().decode(EncryptedEnvelope.self, from: json)
    }

    // MARK: Pairing sessions (design §13.7)

    public struct PairingRecord {
        public var rendezvousID: String
        public var macDeviceID: String
        public var macSigningPublicKey: Data
        public var macPairingPublicKey: Data
        public var state: String
        public var expiresAt: Date
        public var mobileEphemeralPublicKey: Data?
        public var encryptedMobileResponse: Data?
        public var encryptedCredential: Data?
        public var epoch: Int
    }

    private func recordID(forRendezvous id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "pair-\(id)", zoneID: zoneID)
    }

    public func createPairingSession(from payload: PairingPayload, epoch: UInt32) async throws {
        let record = CKRecord(recordType: Self.pairingType, recordID: recordID(forRendezvous: payload.rendezvousID))
        record["rendezvousID"] = payload.rendezvousID as CKRecordValue
        record["macDeviceID"] = payload.macDeviceID as CKRecordValue
        record["macSigningPublicKey"] = payload.macSigningPublicKey as CKRecordValue
        record["macPairingPublicKey"] = payload.macPairingPublicKey as CKRecordValue
        record["state"] = "waiting" as CKRecordValue
        record["expiresAt"] = payload.expiresAt as CKRecordValue
        record["epoch"] = Int64(epoch) as CKRecordValue
        _ = try await database.save(record)
    }

    public func fetchPairingSession(rendezvousID: String) async throws -> (PairingRecord, CKRecord) {
        let record: CKRecord
        do {
            record = try await database.record(for: recordID(forRendezvous: rendezvousID))
        } catch {
            throw MailboxError.recordMissing
        }
        let pairing = PairingRecord(
            rendezvousID: record["rendezvousID"] as? String ?? "",
            macDeviceID: record["macDeviceID"] as? String ?? "",
            macSigningPublicKey: record["macSigningPublicKey"] as? Data ?? Data(),
            macPairingPublicKey: record["macPairingPublicKey"] as? Data ?? Data(),
            state: record["state"] as? String ?? "",
            expiresAt: record["expiresAt"] as? Date ?? .distantPast,
            mobileEphemeralPublicKey: record["mobileEphemeralPublicKey"] as? Data,
            encryptedMobileResponse: record["encryptedMobileResponse"] as? Data,
            encryptedCredential: record["encryptedCredential"] as? Data,
            epoch: (record["epoch"] as? Int64).map(Int.init) ?? 1
        )
        return (pairing, record)
    }

    /// Phone: atomically claim the session by writing its response. The save
    /// uses the fetched record's change tag, so a raced duplicate claim fails
    /// with `.conflict` — QR replay rejection (design §13.7 step 8).
    public func claimPairingSession(record: CKRecord, mobileEphemeral: Data, response: Data) async throws {
        guard record["state"] as? String == "waiting" else { throw MailboxError.conflict }
        record["state"] = "responded" as CKRecordValue
        record["mobileEphemeralPublicKey"] = mobileEphemeral as CKRecordValue
        record["encryptedMobileResponse"] = response as CKRecordValue
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [],
                                                 savePolicy: .ifServerRecordUnchanged)
                .saveResults.values.map { try $0.get() }
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw MailboxError.conflict
        } catch {
            throw MailboxError.underlying(error)
        }
    }

    /// Mac: issue the credential and consume the session.
    public func completePairingSession(record: CKRecord, encryptedCredential: Data) async throws {
        record["state"] = "consumed" as CKRecordValue
        record["encryptedCredential"] = encryptedCredential as CKRecordValue
        _ = try await database.save(record)
    }

    public func deletePairingSession(rendezvousID: String) async {
        _ = try? await database.deleteRecord(withID: recordID(forRendezvous: rendezvousID))
    }

    // MARK: Push wake (design §13.12)

    /// Zone-wide silent-push subscription: any change in the zone wakes the
    /// device, which then fetches. Notifications are only a signal; polling
    /// remains the correctness path.
    public func registerZoneSubscription(subscriptionID: String) async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already exists with same ID — fine.
        }
    }

    /// Server-side truth: which subscriptions actually exist for this user.
    public func listSubscriptions() async throws -> [String] {
        try await database.allSubscriptions().map(\.subscriptionID)
    }

    /// Trigger a zone change (deposit + delete a marker) so every *other*
    /// device of this user should receive a subscription push. Pure diagnostics.
    public func triggerTestPush() async throws {
        let marker = EncryptedEnvelope.schemaBootstrapMarker
        try await deposit(marker)
        try await acknowledge(messageIDs: [marker.messageID])
    }
}
