import Foundation
import CloudKit
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

/// Abstraction over the encrypted-mailbox transport (design §6: "a transport
/// abstraction with CloudKit implemented first"). Two implementations: the
/// real CloudKit private-database mailbox, and the localhost HTTP stand-in
/// used for development against a Mac running in local mode.
protocol PhoneTransport: Sendable {
    var modeDescription: String { get }

    // Pairing (design §13.7)
    func fetchPairingRecord(rendezvousID: String) async throws -> PairingRendezvous
    func claimPairing(rendezvousID: String, ephemeralPublicKey: Data, encryptedResponse: Data) async throws
    func fetchCredential(rendezvousID: String) async throws -> (ciphertext: Data, epoch: UInt32)?

    // Envelopes (design §4.6)
    func send(_ envelope: EncryptedEnvelope) async throws
    func fetchInbox(recipient: String) async throws -> [EncryptedEnvelope]
    func acknowledge(recipient: String, messageIDs: [String]) async throws

    /// Presence/status of the Mac, when the transport can know it.
    func macStatus() async -> MacStatus?

    /// Register for push wake, if supported.
    func registerForWake(deviceID: String) async
}

struct PairingRendezvous {
    var macDeviceID: String
    var macSigningPublicKey: Data
    var macPairingPublicKey: Data
    var state: String
}

struct MacStatus {
    var reachable: Bool
    var vmState: String?
    var epoch: UInt32?
}

enum TransportError: Error {
    case revoked           // the Mac refuses this device
    case conflict          // pairing session already claimed
    case notFound
    case http(Int)
    case cloud(Error)
}

func makeTransport(mailbox: String) -> PhoneTransport? {
    if mailbox.hasPrefix("cloudkit:") {
        return CloudKitPhoneTransport(containerID: String(mailbox.dropFirst("cloudkit:".count)))
    }
    if mailbox.hasPrefix("http://127.0.0.1") || mailbox.hasPrefix("http://localhost") {
        return LocalHTTPTransport(baseURL: mailbox)
    }
    return nil
}

// MARK: - CloudKit transport (design §13.9)

final class CloudKitPhoneTransport: PhoneTransport, @unchecked Sendable {
    let containerID: String
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    init(containerID: String) {
        self.containerID = containerID
        self.container = CKContainer(identifier: containerID)
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: "AgentLinkZone", ownerName: CKCurrentUserDefaultName)
    }

    var modeDescription: String { "CloudKit mailbox" }

    private func pairingRecordID(_ rendezvousID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "pair-\(rendezvousID)", zoneID: zoneID)
    }

    func fetchPairingRecord(rendezvousID: String) async throws -> PairingRendezvous {
        let record: CKRecord
        do {
            record = try await database.record(for: pairingRecordID(rendezvousID))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            throw TransportError.notFound
        } catch {
            throw TransportError.cloud(error)
        }
        return PairingRendezvous(
            macDeviceID: record["macDeviceID"] as? String ?? "",
            macSigningPublicKey: record["macSigningPublicKey"] as? Data ?? Data(),
            macPairingPublicKey: record["macPairingPublicKey"] as? Data ?? Data(),
            state: record["state"] as? String ?? ""
        )
    }

    func claimPairing(rendezvousID: String, ephemeralPublicKey: Data, encryptedResponse: Data) async throws {
        let record: CKRecord
        do {
            record = try await database.record(for: pairingRecordID(rendezvousID))
        } catch {
            throw TransportError.notFound
        }
        guard record["state"] as? String == "waiting" else { throw TransportError.conflict }
        record["state"] = "responded" as CKRecordValue
        record["mobileEphemeralPublicKey"] = ephemeralPublicKey as CKRecordValue
        record["encryptedMobileResponse"] = encryptedResponse as CKRecordValue
        do {
            let result = try await database.modifyRecords(saving: [record], deleting: [],
                                                          savePolicy: .ifServerRecordUnchanged)
            for (_, save) in result.saveResults { _ = try save.get() }
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw TransportError.conflict  // atomic claim lost — QR replay rejected
        } catch {
            throw TransportError.cloud(error)
        }
    }

    func fetchCredential(rendezvousID: String) async throws -> (ciphertext: Data, epoch: UInt32)? {
        let record: CKRecord
        do {
            record = try await database.record(for: pairingRecordID(rendezvousID))
        } catch {
            throw TransportError.notFound
        }
        guard let credential = record["encryptedCredential"] as? Data else { return nil }
        let epoch = (record["epoch"] as? Int64).map(UInt32.init) ?? 1
        return (credential, epoch)
    }

    func send(_ envelope: EncryptedEnvelope) async throws {
        let recordID = CKRecord.ID(recordName: "env-\(envelope.messageID)", zoneID: zoneID)
        let record = CKRecord(recordType: "Envelope", recordID: recordID)
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
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return  // duplicate send — already deposited
        } catch {
            throw TransportError.cloud(error)
        }
    }

    func fetchInbox(recipient: String) async throws -> [EncryptedEnvelope] {
        let predicate = NSPredicate(format: "recipientDeviceID == %@", recipient)
        let query = CKQuery(recordType: "Envelope", predicate: predicate)
        do {
            let (results, _) = try await database.records(matching: query, inZoneWith: zoneID,
                                                          desiredKeys: nil, resultsLimit: 50)
            var envelopes: [EncryptedEnvelope] = []
            for (_, result) in results {
                guard let record = try? result.get(), let envelope = Self.envelope(from: record) else { continue }
                if envelope.expiresAt <= Date() { continue }
                envelopes.append(envelope)
            }
            return envelopes.sorted {
                $0.sequence != $1.sequence ? $0.sequence < $1.sequence : $0.createdAt < $1.createdAt
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return []
        } catch {
            throw TransportError.cloud(error)
        }
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

    func acknowledge(recipient: String, messageIDs: [String]) async throws {
        guard !messageIDs.isEmpty else { return }
        let ids = messageIDs.map { CKRecord.ID(recordName: "env-\($0)", zoneID: zoneID) }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
    }

    func macStatus() async -> MacStatus? {
        // CloudKit cannot observe the Mac directly; reachability of iCloud is
        // the only signal. Sandbox state arrives via sandbox.status envelopes.
        let status = try? await container.accountStatus()
        return MacStatus(reachable: status == .available, vmState: nil, epoch: nil)
    }

    func registerForWake(deviceID: String) async {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID,
                                                    subscriptionID: "chariot-phone-\(deviceID.prefix(8))")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.save(subscription)
            print("[chariot] zone subscription registered")
        } catch let error as CKError where error.code == .serverRejectedRequest {
            print("[chariot] zone subscription already exists")
        } catch {
            print("[chariot] zone subscription FAILED: \(error)")
        }
    }
}

// MARK: - Localhost HTTP transport (development stand-in)

final class LocalHTTPTransport: PhoneTransport, @unchecked Sendable {
    let baseURL: String
    /// Serial cursor for the local mailbox; persisted via UserDefaults keyed by
    /// base URL (the CloudKit transport has no cursor — acked mail is deleted).
    private let cursorKey: String

    init(baseURL: String) {
        self.baseURL = baseURL
        self.cursorKey = "chariot.cursor.\(baseURL.hashValue)"
    }

    var modeDescription: String { "Local mailbox (development)" }

    private var cursor: UInt64 {
        get { UInt64(UserDefaults.standard.integer(forKey: cursorKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: cursorKey) }
    }

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(string: baseURL)!
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func request(_ method: String, _ url: URL, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw TransportError.revoked }
        if status == 404 { throw TransportError.notFound }
        if status == 409 || status == 410 { throw TransportError.conflict }
        guard (200..<300).contains(status) else { throw TransportError.http(status) }
        return data
    }

    private func json(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> [String: Any] {
        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let data = try await request(method, url, body: bodyData)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func fetchPairingRecord(rendezvousID: String) async throws -> PairingRendezvous {
        let object = try await json("GET", url("/pairing/\(rendezvousID)"))
        return PairingRendezvous(
            macDeviceID: object["mac_device_id"] as? String ?? "",
            macSigningPublicKey: (try? Base64URL.decode(object["mac_signing_public_key"] as? String ?? "")) ?? Data(),
            macPairingPublicKey: (try? Base64URL.decode(object["mac_pairing_public_key"] as? String ?? "")) ?? Data(),
            state: object["state"] as? String ?? ""
        )
    }

    func claimPairing(rendezvousID: String, ephemeralPublicKey: Data, encryptedResponse: Data) async throws {
        _ = try await json("POST", url("/pairing/\(rendezvousID)/response"),
                           body: ["ephemeral_public_key": Base64URL.encode(ephemeralPublicKey),
                                  "ciphertext": Base64URL.encode(encryptedResponse)])
    }

    func fetchCredential(rendezvousID: String) async throws -> (ciphertext: Data, epoch: UInt32)? {
        do {
            let object = try await json("GET", url("/pairing/\(rendezvousID)/credential"))
            guard let ciphertextB64 = object["ciphertext"] as? String else { return nil }
            return (try Base64URL.decode(ciphertextB64), UInt32(object["epoch"] as? Int ?? 1))
        } catch TransportError.notFound {
            return nil
        }
    }

    func send(_ envelope: EncryptedEnvelope) async throws {
        _ = try await request("POST", url("/envelopes"), body: try CanonicalCoding.encode(envelope))
    }

    func fetchInbox(recipient: String) async throws -> [EncryptedEnvelope] {
        let object = try await json("GET", url("/envelopes",
                                               query: ["recipient": recipient, "after": String(cursor)]))
        guard let items = object["envelopes"] as? [[String: Any]] else { return [] }
        var envelopes: [EncryptedEnvelope] = []
        var newCursor = cursor
        for item in items {
            guard let serial = item["serial"] as? Int, let envelopeObject = item["envelope"] else { continue }
            newCursor = max(newCursor, UInt64(serial))
            if let data = try? JSONSerialization.data(withJSONObject: envelopeObject),
               let envelope = try? CanonicalCoding.decoder().decode(EncryptedEnvelope.self, from: data) {
                envelopes.append(envelope)
            }
        }
        cursor = newCursor
        return envelopes
    }

    func acknowledge(recipient: String, messageIDs: [String]) async throws {
        _ = try? await json("POST", url("/receipts"),
                            body: ["recipient": recipient, "message_ids": messageIDs] as [String: Any])
    }

    func macStatus() async -> MacStatus? {
        guard let object = try? await json("GET", url("/status")) else {
            return MacStatus(reachable: false, vmState: nil, epoch: nil)
        }
        return MacStatus(reachable: true,
                         vmState: object["vm_state"] as? String,
                         epoch: (object["epoch"] as? Int).map(UInt32.init))
    }

    func registerForWake(deviceID: String) async {}  // polling only
}
