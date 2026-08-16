import Foundation
import CryptoKit

/// The transport-independent encrypted envelope (design §7). The same object is
/// carried over WebRTC, CloudKit, or the sample's localhost mailbox.
public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let messageID: String
    public let conversationID: String
    public let senderDeviceID: String
    public let recipientDeviceID: String
    public let sequence: UInt64
    public let epoch: UInt32
    public let createdAt: Date
    public let expiresAt: Date
    public let nonce: Data
    public let ciphertext: Data
    public var signature: Data

    enum CodingKeys: String, CodingKey {
        case version, sequence, epoch, nonce, ciphertext, signature
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case senderDeviceID = "sender_device_id"
        case recipientDeviceID = "recipient_device_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    /// Canonical authenticated header: everything except the signature, with
    /// binary fields base64url-encoded. Used as AEAD associated data and as the
    /// first part of the signed bytes.
    struct Header: Codable {
        let version: Int
        let messageID: String
        let conversationID: String
        let senderDeviceID: String
        let recipientDeviceID: String
        let sequence: UInt64
        let epoch: UInt32
        let createdAt: Date
        let expiresAt: Date
        let nonce: String

        enum CodingKeys: String, CodingKey {
            case version, sequence, epoch, nonce
            case messageID = "message_id"
            case conversationID = "conversation_id"
            case senderDeviceID = "sender_device_id"
            case recipientDeviceID = "recipient_device_id"
            case createdAt = "created_at"
            case expiresAt = "expires_at"
        }
    }

    var header: Header {
        Header(version: version, messageID: messageID, conversationID: conversationID,
               senderDeviceID: senderDeviceID, recipientDeviceID: recipientDeviceID,
               sequence: sequence, epoch: epoch, createdAt: createdAt, expiresAt: expiresAt,
               nonce: Base64URL.encode(nonce))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        messageID = try c.decode(String.self, forKey: .messageID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        senderDeviceID = try c.decode(String.self, forKey: .senderDeviceID)
        recipientDeviceID = try c.decode(String.self, forKey: .recipientDeviceID)
        sequence = try c.decode(UInt64.self, forKey: .sequence)
        epoch = try c.decode(UInt32.self, forKey: .epoch)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        nonce = try Base64URL.decode(c.decode(String.self, forKey: .nonce))
        ciphertext = try Base64URL.decode(c.decode(String.self, forKey: .ciphertext))
        signature = try Base64URL.decode(c.decode(String.self, forKey: .signature))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(messageID, forKey: .messageID)
        try c.encode(conversationID, forKey: .conversationID)
        try c.encode(senderDeviceID, forKey: .senderDeviceID)
        try c.encode(recipientDeviceID, forKey: .recipientDeviceID)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(Base64URL.encode(nonce), forKey: .nonce)
        try c.encode(Base64URL.encode(ciphertext), forKey: .ciphertext)
        try c.encode(Base64URL.encode(signature), forKey: .signature)
    }

    fileprivate init(version: Int, messageID: String, conversationID: String,
                     senderDeviceID: String, recipientDeviceID: String,
                     sequence: UInt64, epoch: UInt32, createdAt: Date, expiresAt: Date,
                     nonce: Data, ciphertext: Data, signature: Data) {
        self.version = version
        self.messageID = messageID
        self.conversationID = conversationID
        self.senderDeviceID = senderDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.sequence = sequence
        self.epoch = epoch
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.signature = signature
    }
}

extension EncryptedEnvelope {
    /// Inert placeholder used once to create the CloudKit record schema.
    /// Addressed to nobody; deleted immediately after saving.
    public static var schemaBootstrapMarker: EncryptedEnvelope {
        EncryptedEnvelope(version: AgentLinkProtocolVersion.current,
                          messageID: "schema-bootstrap",
                          conversationID: "schema-bootstrap",
                          senderDeviceID: "schema-bootstrap",
                          recipientDeviceID: "schema-bootstrap",
                          sequence: 0, epoch: 0,
                          createdAt: Date(timeIntervalSince1970: 0),
                          expiresAt: Date(timeIntervalSince1970: 1),
                          nonce: Data(count: 12), ciphertext: Data(count: 32),
                          signature: Data(count: 64))
    }
}

/// Per-epoch session cryptography between two paired devices.
public struct SessionCrypto {
    public let localDeviceID: String
    public let peerDeviceID: String
    public let epoch: UInt32
    private let messageKey: SymmetricKey
    private let signingKey: Curve25519.Signing.PrivateKey
    private let peerSigningPublicKey: Curve25519.Signing.PublicKey

    /// Both sides derive identical keys: the device IDs are ordered
    /// lexicographically so the info string matches on both ends.
    public init(localIdentity: DeviceIdentity,
                peerPublicIdentity: PublicDeviceIdentity,
                epoch: UInt32) throws {
        self.localDeviceID = localIdentity.deviceID
        self.peerDeviceID = peerPublicIdentity.deviceID
        self.epoch = epoch
        let peerAgreement = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicIdentity.agreementPublicKey)
        let shared = try localIdentity.agreementKey.sharedSecretFromKeyAgreement(with: peerAgreement)
        let ids = [localIdentity.deviceID, peerPublicIdentity.deviceID].sorted().joined(separator: "|")
        self.messageKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("epoch:\(epoch)".utf8),
            sharedInfo: Data("agent-link/session/v1|\(ids)".utf8),
            outputByteCount: 32
        )
        self.signingKey = localIdentity.signingKey
        self.peerSigningPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerPublicIdentity.signingPublicKey)
    }

    public static let defaultLifetime: TimeInterval = 24 * 60 * 60

    /// Encrypt + sign an AgentMessage for the peer.
    public func seal(_ message: AgentMessage,
                     conversationID: String? = nil,
                     expiresIn: TimeInterval = SessionCrypto.defaultLifetime,
                     now rawNow: Date = Date()) throws -> EncryptedEnvelope {
        let now = Date(timeIntervalSince1970: rawNow.timeIntervalSince1970.rounded(.down))
        let plaintext = try CanonicalCoding.encode(message)
        var nonceBytes = Data(count: 12)
        nonceBytes.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, 12, base)
        }
        var envelope = EncryptedEnvelope(
            version: AgentLinkProtocolVersion.current,
            messageID: message.messageID,
            conversationID: conversationID ?? message.conversationID,
            senderDeviceID: localDeviceID,
            recipientDeviceID: peerDeviceID,
            sequence: message.sequence,
            epoch: epoch,
            createdAt: now,
            expiresAt: now.addingTimeInterval(expiresIn),
            nonce: nonceBytes,
            ciphertext: Data(),
            signature: Data()
        )
        let aad = try CanonicalCoding.encode(envelope.header)
        let sealed = try ChaChaPoly.seal(plaintext,
                                         using: messageKey,
                                         nonce: ChaChaPoly.Nonce(data: nonceBytes),
                                         authenticating: aad)
        envelope = EncryptedEnvelope(
            version: envelope.version, messageID: envelope.messageID,
            conversationID: envelope.conversationID, senderDeviceID: envelope.senderDeviceID,
            recipientDeviceID: envelope.recipientDeviceID, sequence: envelope.sequence,
            epoch: envelope.epoch, createdAt: envelope.createdAt, expiresAt: envelope.expiresAt,
            nonce: nonceBytes, ciphertext: sealed.ciphertext + sealed.tag, signature: Data()
        )
        envelope.signature = try signingKey.signature(for: aad + envelope.ciphertext)
        return envelope
    }

    /// Verify signature + expiry, then decrypt. Replay/sequence checks are the
    /// caller's job via `ReplayWindow` (they need persistence).
    public func open(_ envelope: EncryptedEnvelope, now: Date = Date()) throws -> AgentMessage {
        guard envelope.version == AgentLinkProtocolVersion.current else {
            throw AgentLinkError.unsupportedVersion(envelope.version)
        }
        guard envelope.epoch == epoch else { throw AgentLinkError.epochMismatch }
        guard envelope.expiresAt > now else { throw AgentLinkError.envelopeExpired }
        guard envelope.senderDeviceID == peerDeviceID, envelope.recipientDeviceID == localDeviceID else {
            throw AgentLinkError.malformedMessage("envelope not addressed to this device")
        }
        let aad = try CanonicalCoding.encode(envelope.header)
        guard peerSigningPublicKey.isValidSignature(envelope.signature, for: aad + envelope.ciphertext) else {
            throw AgentLinkError.signatureInvalid
        }
        guard envelope.ciphertext.count > 16 else { throw AgentLinkError.decryptionFailed }
        let ct = envelope.ciphertext.prefix(envelope.ciphertext.count - 16)
        let tag = envelope.ciphertext.suffix(16)
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: envelope.nonce),
                                               ciphertext: ct, tag: tag)
            plaintext = try ChaChaPoly.open(box, using: messageKey, authenticating: aad)
        } catch {
            throw AgentLinkError.decryptionFailed
        }
        let message = try CanonicalCoding.decoder().decode(AgentMessage.self, from: plaintext)
        guard message.messageID == envelope.messageID, message.sequence == envelope.sequence else {
            throw AgentLinkError.malformedMessage("envelope/message header mismatch")
        }
        return message
    }
}
