import XCTest
import CryptoKit
@testable import AgentLinkKit

final class AgentLinkKitTests: XCTestCase {

    func makePayload(expiresIn: TimeInterval = 120,
                     secretBytes: Int = 32,
                     type: String = PairingPayload.payloadType) throws -> Data {
        let mac = DeviceIdentity()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var payload = try CanonicalCoding.encode(PairingPayload(
            rendezvousID: UUID().uuidString.lowercased(),
            macDeviceID: mac.deviceID,
            macDisplayName: "Test Mac",
            macSigningPublicKey: mac.signingKey.publicKey.rawRepresentation,
            macPairingPublicKey: eph.publicKey.rawRepresentation,
            pairingSecret: Data((0..<secretBytes).map { _ in UInt8.random(in: 0...255) }),
            expiresAt: Date().addingTimeInterval(expiresIn),
            mailbox: "http://127.0.0.1:8787"
        ))
        if type != PairingPayload.payloadType {
            var obj = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            obj["type"] = type
            payload = try JSONSerialization.data(withJSONObject: obj)
        }
        return payload
    }

    // MARK: QR payload validation (§13.6)

    func testValidPayloadPasses() throws {
        _ = try PairingPayload.validate(json: try makePayload())
    }

    func testExpiredPayloadRejected() throws {
        XCTAssertThrowsError(try PairingPayload.validate(json: try makePayload(expiresIn: -5))) {
            XCTAssertEqual($0 as? AgentLinkError, .payloadExpired)
        }
    }

    func testOverlongLifetimeRejected() throws {
        XCTAssertThrowsError(try PairingPayload.validate(json: try makePayload(expiresIn: 3600))) {
            XCTAssertEqual($0 as? AgentLinkError, .payloadLifetimeTooLong)
        }
    }

    func testLowEntropySecretRejected() throws {
        XCTAssertThrowsError(try PairingPayload.validate(json: try makePayload(secretBytes: 8))) {
            XCTAssertEqual($0 as? AgentLinkError, .lowEntropyField("pairing_secret"))
        }
    }

    func testWrongTypeRejected() throws {
        XCTAssertThrowsError(try PairingPayload.validate(json: try makePayload(type: "not-a-pairing"))) {
            XCTAssertEqual($0 as? AgentLinkError, .invalidPayloadType("not-a-pairing"))
        }
    }

    func testTamperedPayloadRejected() throws {
        let data = try makePayload()
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj["mac_signing_public_key"] = "AAAA"  // wrong length key
        let tampered = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try PairingPayload.validate(json: tampered))
    }

    // MARK: Pairing crypto symmetry

    func testPairingKeyAgreementSymmetric() throws {
        let macEph = Curve25519.KeyAgreement.PrivateKey()
        let phoneEph = Curve25519.KeyAgreement.PrivateKey()
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let kMac = try PairingCrypto.deriveKey(ephemeralPrivate: macEph,
                                               peerEphemeralPublic: phoneEph.publicKey.rawRepresentation,
                                               pairingSecret: secret)
        let kPhone = try PairingCrypto.deriveKey(ephemeralPrivate: phoneEph,
                                                 peerEphemeralPublic: macEph.publicKey.rawRepresentation,
                                                 pairingSecret: secret)
        XCTAssertEqual(kMac.withUnsafeBytes { Data($0) }, kPhone.withUnsafeBytes { Data($0) })

        // Round-trip a pairing response through the sealed channel.
        let phone = DeviceIdentity()
        var response = PairingResponse(mobile: phone.publicIdentity,
                                       mobileDisplayName: "Test iPhone",
                                       mobileEphemeralPublicKey: phoneEph.publicKey.rawRepresentation)
        try response.sign(with: phone.signingKey)
        let sealed = try PairingCrypto.seal(response, key: kPhone)
        let opened = try PairingCrypto.open(PairingResponse.self, combined: sealed, key: kMac)
        XCTAssertEqual(opened, response)
        XCTAssertNoThrow(try opened.verifySignature())

        // Wrong secret cannot decrypt.
        let kWrong = try PairingCrypto.deriveKey(ephemeralPrivate: macEph,
                                                 peerEphemeralPublic: phoneEph.publicKey.rawRepresentation,
                                                 pairingSecret: Data(count: 32))
        XCTAssertThrowsError(try PairingCrypto.open(PairingResponse.self, combined: sealed, key: kWrong))
    }

    func testTamperedResponseSignatureRejected() throws {
        let phone = DeviceIdentity()
        let eph = Curve25519.KeyAgreement.PrivateKey()
        var response = PairingResponse(mobile: phone.publicIdentity,
                                       mobileDisplayName: "iPhone",
                                       mobileEphemeralPublicKey: eph.publicKey.rawRepresentation)
        try response.sign(with: phone.signingKey)
        var copy = response
        copy = PairingResponse(mobile: phone.publicIdentity,
                               mobileDisplayName: "Evil iPhone",
                               mobileEphemeralPublicKey: eph.publicKey.rawRepresentation)
        copy.signature = response.signature
        XCTAssertThrowsError(try copy.verifySignature()) {
            XCTAssertEqual($0 as? AgentLinkError, .signatureInvalid)
        }
    }

    // MARK: Device credential

    func testDeviceCredentialSignVerify() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        var credential = DeviceCredential(mac: mac.publicIdentity, mobile: phone.publicIdentity)
        try credential.sign(with: mac.signingKey)
        XCTAssertNoThrow(try credential.verify(pinnedMacSigningKey: mac.signingKey.publicKey.rawRepresentation))

        // A different pinned key must fail even with a valid signature.
        let other = DeviceIdentity()
        XCTAssertThrowsError(try credential.verify(pinnedMacSigningKey: other.signingKey.publicKey.rawRepresentation))

        // JSON round trip preserves verifiability.
        let json = try CanonicalCoding.encode(credential)
        let decoded = try CanonicalCoding.decoder().decode(DeviceCredential.self, from: json)
        XCTAssertNoThrow(try decoded.verify(pinnedMacSigningKey: mac.signingKey.publicKey.rawRepresentation))
    }

    // MARK: Envelope seal/open

    func testEnvelopeRoundTrip() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        let macSession = try SessionCrypto(localIdentity: mac, peerPublicIdentity: phone.publicIdentity, epoch: 7)
        let phoneSession = try SessionCrypto(localIdentity: phone, peerPublicIdentity: mac.publicIdentity, epoch: 7)

        let message = AgentMessage(conversationID: "conv-1", senderDeviceID: phone.deviceID,
                                   sequence: 184, type: .conversationSend,
                                   body: .object(["text": .string("hello agent")]))
        let envelope = try phoneSession.seal(message)
        let json = try CanonicalCoding.encode(envelope)
        let received = try CanonicalCoding.decoder().decode(EncryptedEnvelope.self, from: json)
        let opened = try macSession.open(received)
        XCTAssertEqual(opened, message)
        XCTAssertEqual(opened.body["text"]?.stringValue, "hello agent")
    }

    func testEnvelopeTamperRejected() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        let macSession = try SessionCrypto(localIdentity: mac, peerPublicIdentity: phone.publicIdentity, epoch: 1)
        let phoneSession = try SessionCrypto(localIdentity: phone, peerPublicIdentity: mac.publicIdentity, epoch: 1)

        let message = AgentMessage(conversationID: "c", senderDeviceID: phone.deviceID,
                                   sequence: 1, type: .conversationSend, body: .object([:]))
        let envelope = try phoneSession.seal(message)
        var json = try JSONSerialization.jsonObject(with: CanonicalCoding.encode(envelope)) as! [String: Any]
        json["sequence"] = 999  // header tamper breaks signature/AAD
        let tampered = try JSONSerialization.data(withJSONObject: json)
        let received = try CanonicalCoding.decoder().decode(EncryptedEnvelope.self, from: tampered)
        XCTAssertThrowsError(try macSession.open(received))
    }

    func testWrongEpochRejected() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        let phoneSession = try SessionCrypto(localIdentity: phone, peerPublicIdentity: mac.publicIdentity, epoch: 1)
        let macSessionNewEpoch = try SessionCrypto(localIdentity: mac, peerPublicIdentity: phone.publicIdentity, epoch: 2)
        let message = AgentMessage(conversationID: "c", senderDeviceID: phone.deviceID,
                                   sequence: 1, type: .conversationSend, body: .object([:]))
        let envelope = try phoneSession.seal(message)
        XCTAssertThrowsError(try macSessionNewEpoch.open(envelope)) {
            XCTAssertEqual($0 as? AgentLinkError, .epochMismatch)
        }
    }

    func testExpiredEnvelopeRejected() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        let macSession = try SessionCrypto(localIdentity: mac, peerPublicIdentity: phone.publicIdentity, epoch: 1)
        let phoneSession = try SessionCrypto(localIdentity: phone, peerPublicIdentity: mac.publicIdentity, epoch: 1)
        let message = AgentMessage(conversationID: "c", senderDeviceID: phone.deviceID,
                                   sequence: 1, type: .conversationSend, body: .object([:]))
        let envelope = try phoneSession.seal(message, expiresIn: 10)
        XCTAssertThrowsError(try macSession.open(envelope, now: Date().addingTimeInterval(60))) {
            XCTAssertEqual($0 as? AgentLinkError, .envelopeExpired)
        }
    }

    func testThirdPartyCannotDecrypt() throws {
        let mac = DeviceIdentity()
        let phone = DeviceIdentity()
        let eve = DeviceIdentity(deviceID: mac.deviceID)  // even claiming the same ID
        let phoneSession = try SessionCrypto(localIdentity: phone, peerPublicIdentity: mac.publicIdentity, epoch: 1)
        let eveSession = try SessionCrypto(localIdentity: eve, peerPublicIdentity: phone.publicIdentity, epoch: 1)
        let message = AgentMessage(conversationID: "c", senderDeviceID: phone.deviceID,
                                   sequence: 1, type: .conversationSend,
                                   body: .object(["text": .string("secret")]))
        let envelope = try phoneSession.seal(message)
        XCTAssertThrowsError(try eveSession.open(envelope))
    }

    // MARK: Replay protection

    func testReplayWindow() throws {
        var window = ReplayWindow(capacity: 4)
        try window.accept(messageID: "a", sequence: 1)
        try window.accept(messageID: "b", sequence: 2)
        XCTAssertThrowsError(try window.accept(messageID: "a", sequence: 1)) {
            XCTAssertEqual($0 as? AgentLinkError, .replayDetected)
        }
        // Reordering within the window is tolerated.
        try window.accept(messageID: "d", sequence: 4)
        try window.accept(messageID: "c", sequence: 3)
        // Far-behind sequence is rejected once the window has moved on.
        try window.accept(messageID: "e", sequence: 20)
        XCTAssertThrowsError(try window.accept(messageID: "f", sequence: 2)) {
            XCTAssertEqual($0 as? AgentLinkError, .sequenceRegression)
        }
    }

    func testSequenceAllocatorMonotonic() {
        var alloc = SequenceAllocator()
        XCTAssertEqual(alloc.next(), 1)
        XCTAssertEqual(alloc.next(), 2)
        let restored = SequenceAllocator(lastAssigned: 100)
        var r = restored
        XCTAssertEqual(r.next(), 101)
    }

    // MARK: Fingerprints & identity persistence

    func testFingerprintStableAcrossPlatformEncoding() throws {
        let identity = DeviceIdentity()
        let json = try CanonicalCoding.encode(identity.publicIdentity)
        let decoded = try CanonicalCoding.decoder().decode(PublicDeviceIdentity.self, from: json)
        XCTAssertEqual(decoded.fingerprint, identity.publicIdentity.fingerprint)
        XCTAssertEqual(decoded.fingerprint.count, 19)
    }

    func testIdentityStorageRoundTrip() throws {
        let identity = DeviceIdentity()
        let restored = try DeviceIdentity(stored: identity.stored())
        XCTAssertEqual(restored.deviceID, identity.deviceID)
        XCTAssertEqual(restored.signingKey.publicKey.rawRepresentation,
                       identity.signingKey.publicKey.rawRepresentation)
        XCTAssertEqual(restored.agreementKey.publicKey.rawRepresentation,
                       identity.agreementKey.publicKey.rawRepresentation)
    }
}
