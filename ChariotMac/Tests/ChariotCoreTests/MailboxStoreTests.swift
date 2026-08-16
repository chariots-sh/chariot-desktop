import XCTest
import AgentLinkKit
@testable import ChariotCore

final class MailboxStoreTests: XCTestCase {

    var directory: URL!
    var mac: DeviceIdentity!
    var phone: DeviceIdentity!
    var macSession: SessionCrypto!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        mac = DeviceIdentity()
        phone = DeviceIdentity()
        macSession = try SessionCrypto(localIdentity: mac, peerPublicIdentity: phone.publicIdentity, epoch: 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func envelope(sequence: UInt64,
                  expiresIn: TimeInterval = 3600,
                  session: SessionCrypto? = nil) throws -> EncryptedEnvelope {
        let message = AgentMessage(conversationID: "conv", senderDeviceID: mac.deviceID,
                                   sequence: sequence, type: .conversationSend,
                                   body: .object(["text": .string("message \(sequence)")]))
        return try (session ?? macSession).seal(message, expiresIn: expiresIn)
    }

    func testDepositFetchAcknowledge() throws {
        let store = MailboxStore(directory: directory)
        let first = try envelope(sequence: 1)
        let s1 = store.deposit(first)
        let s2 = store.deposit(try envelope(sequence: 2))
        let s3 = store.deposit(try envelope(sequence: 3))
        XCTAssertLessThan(s1, s2)
        XCTAssertLessThan(s2, s3)

        let all = store.fetch(recipient: phone.deviceID, after: 0)
        XCTAssertEqual(all.map(\.serial), [s1, s2, s3])
        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: s1).map(\.serial), [s2, s3])
        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: 0, limit: 2).count, 2)

        store.acknowledge(recipient: phone.deviceID,
                          messageIDs: [all[0].envelope.messageID, all[1].envelope.messageID])
        XCTAssertEqual(store.pendingCount(recipient: phone.deviceID), 1)
        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: 0).map(\.serial), [s3])
    }

    func testDepositDeduplicatesByMessageID() throws {
        let store = MailboxStore(directory: directory)
        let env = try envelope(sequence: 1)
        let serial = store.deposit(env)
        XCTAssertEqual(store.deposit(env), serial)
        XCTAssertEqual(store.pendingCount(recipient: phone.deviceID), 1)
    }

    func testFetchFiltersByRecipient() throws {
        let store = MailboxStore(directory: directory)
        store.deposit(try envelope(sequence: 1))
        // An envelope addressed to a different phone must not be returned.
        let otherPhone = DeviceIdentity()
        let otherSession = try SessionCrypto(localIdentity: mac,
                                             peerPublicIdentity: otherPhone.publicIdentity, epoch: 1)
        store.deposit(try envelope(sequence: 2, session: otherSession))

        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: 0).count, 1)
        XCTAssertEqual(store.fetch(recipient: otherPhone.deviceID, after: 0).count, 1)
        XCTAssertEqual(store.fetch(recipient: "unknown-device", after: 0).count, 0)
    }

    func testExpiredEnvelopesAreHiddenAndPurged() throws {
        let store = MailboxStore(directory: directory)
        store.deposit(try envelope(sequence: 1, expiresIn: -5))
        store.deposit(try envelope(sequence: 2))

        // Expired envelopes never come back from fetch...
        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: 0).count, 1)
        // ...but still count as pending until expireStale purges them.
        XCTAssertEqual(store.pendingCount(recipient: phone.deviceID), 2)
        store.expireStale()
        XCTAssertEqual(store.pendingCount(recipient: phone.deviceID), 1)
    }

    func testPersistsAcrossRestart() throws {
        let store = MailboxStore(directory: directory)
        let s1 = store.deposit(try envelope(sequence: 1))
        store.deposit(try envelope(sequence: 2))

        let reloaded = MailboxStore(directory: directory)
        XCTAssertEqual(reloaded.pendingCount(recipient: phone.deviceID), 2)
        let fetched = reloaded.fetch(recipient: phone.deviceID, after: 0)
        XCTAssertEqual(fetched.first?.serial, s1)
        // The envelope survives the JSON round trip intact and still decrypts.
        let phoneSession = try SessionCrypto(localIdentity: phone,
                                             peerPublicIdentity: mac.publicIdentity, epoch: 1)
        let opened = try phoneSession.open(fetched[0].envelope)
        XCTAssertEqual(opened.body["text"]?.stringValue, "message 1")
        // Serial numbering continues past the reload instead of restarting.
        let s3 = reloaded.deposit(try envelope(sequence: 3))
        XCTAssertGreaterThan(s3, s1)
    }

    func testOnDepositFiresForNewEnvelopesOnly() throws {
        let store = MailboxStore(directory: directory)
        var seen: [String] = []
        store.onDeposit = { envelope, _ in seen.append(envelope.messageID) }
        let env = try envelope(sequence: 1)
        store.deposit(env)
        store.deposit(env)  // duplicate: no callback
        XCTAssertEqual(seen, [env.messageID])
    }

    func testInstanceScopedFetch() throws {
        // Per-agent sessions replay only their own agent's mail; envelopes
        // stored before the fleet existed (no instance) match any scope.
        let store = MailboxStore(directory: directory)
        let guardianMail = try envelope(sequence: 1)
        let scribeMail = try envelope(sequence: 2)
        let legacyMail = try envelope(sequence: 3)
        store.deposit(guardianMail, instanceID: "guardian-uuid")
        store.deposit(scribeMail, instanceID: "scribe-uuid")
        store.deposit(legacyMail)

        let guardianView = store.fetch(recipient: phone.deviceID, instanceID: "guardian-uuid", after: 0)
        XCTAssertEqual(guardianView.map(\.envelope.messageID).sorted(),
                       [guardianMail.messageID, legacyMail.messageID].sorted())
        let scribeView = store.fetch(recipient: phone.deviceID, instanceID: "scribe-uuid", after: 0)
        XCTAssertFalse(scribeView.contains { $0.envelope.messageID == guardianMail.messageID })
        // Unscoped fetch (legacy sessions) sees everything.
        XCTAssertEqual(store.fetch(recipient: phone.deviceID, after: 0).count, 3)
    }
}
