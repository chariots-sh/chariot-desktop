import Foundation
import CryptoKit

/// The QR payload displayed by the Mac. See design §4.3 / §13.7.
public struct PairingPayload: Codable, Equatable {
    public static let payloadType = "agent-link-pairing"
    /// A pairing QR may not be valid for longer than this.
    public static let maximumLifetime: TimeInterval = 10 * 60

    public let type: String
    public let version: Int
    public let rendezvousID: String
    public let macDeviceID: String
    public let macDisplayName: String
    public let macSigningPublicKey: Data
    public let macPairingPublicKey: Data   // ephemeral X25519, base64url
    public let pairingSecret: Data          // one-time 32-byte secret, base64url
    public let expiresAt: Date
    /// Where the rendezvous mailbox lives. In production this is a CloudKit zone
    /// reference; the sample uses a localhost mailbox URL.
    public let mailbox: String

    enum CodingKeys: String, CodingKey {
        case type, version, mailbox
        case rendezvousID = "rendezvous_id"
        case macDeviceID = "mac_device_id"
        case macDisplayName = "mac_display_name"
        case macSigningPublicKey = "mac_signing_public_key"
        case macPairingPublicKey = "mac_pairing_public_key"
        case pairingSecret = "pairing_secret"
        case expiresAt = "expires_at"
    }

    public init(rendezvousID: String, macDeviceID: String, macDisplayName: String,
                macSigningPublicKey: Data, macPairingPublicKey: Data,
                pairingSecret: Data, expiresAt: Date, mailbox: String) {
        self.type = Self.payloadType
        self.version = AgentLinkProtocolVersion.current
        self.rendezvousID = rendezvousID
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.macSigningPublicKey = macSigningPublicKey
        self.macPairingPublicKey = macPairingPublicKey
        self.pairingSecret = pairingSecret
        self.expiresAt = expiresAt
        self.mailbox = mailbox
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        version = try c.decode(Int.self, forKey: .version)
        rendezvousID = try c.decode(String.self, forKey: .rendezvousID)
        macDeviceID = try c.decode(String.self, forKey: .macDeviceID)
        macDisplayName = try c.decode(String.self, forKey: .macDisplayName)
        macSigningPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .macSigningPublicKey))
        macPairingPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .macPairingPublicKey))
        pairingSecret = try Base64URL.decode(c.decode(String.self, forKey: .pairingSecret))
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        mailbox = try c.decode(String.self, forKey: .mailbox)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(version, forKey: .version)
        try c.encode(rendezvousID, forKey: .rendezvousID)
        try c.encode(macDeviceID, forKey: .macDeviceID)
        try c.encode(macDisplayName, forKey: .macDisplayName)
        try c.encode(Base64URL.encode(macSigningPublicKey), forKey: .macSigningPublicKey)
        try c.encode(Base64URL.encode(macPairingPublicKey), forKey: .macPairingPublicKey)
        try c.encode(Base64URL.encode(pairingSecret), forKey: .pairingSecret)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encode(mailbox, forKey: .mailbox)
    }

    /// Full validation as required by design §13.6 before any mailbox write.
    public static func validate(json: Data, now: Date = Date()) throws -> PairingPayload {
        let payload: PairingPayload
        do {
            payload = try CanonicalCoding.decoder().decode(PairingPayload.self, from: json)
        } catch let error as AgentLinkError {
            throw error
        } catch {
            throw AgentLinkError.malformedMessage("pairing payload: \(error)")
        }
        guard payload.type == payloadType else { throw AgentLinkError.invalidPayloadType(payload.type) }
        guard AgentLinkProtocolVersion.supported.contains(payload.version) else {
            throw AgentLinkError.unsupportedVersion(payload.version)
        }
        guard payload.macSigningPublicKey.count == 32, payload.macPairingPublicKey.count == 32 else {
            throw AgentLinkError.invalidKeyLength
        }
        guard payload.pairingSecret.count >= 32 else { throw AgentLinkError.lowEntropyField("pairing_secret") }
        guard payload.rendezvousID.count >= 16 else { throw AgentLinkError.lowEntropyField("rendezvous_id") }
        guard payload.expiresAt > now else { throw AgentLinkError.payloadExpired }
        guard payload.expiresAt.timeIntervalSince(now) <= maximumLifetime else {
            throw AgentLinkError.payloadLifetimeTooLong
        }
        return payload
    }
}

/// Symmetric key protecting the pairing handshake, derived on both sides from
/// the ephemeral X25519 agreement mixed with the one-time QR secret.
public enum PairingCrypto {
    public static func deriveKey(ephemeralPrivate: Curve25519.KeyAgreement.PrivateKey,
                                 peerEphemeralPublic: Data,
                                 pairingSecret: Data) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralPublic)
        let shared = try ephemeralPrivate.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingSecret,
            sharedInfo: Data("agent-link/pairing/v1".utf8),
            outputByteCount: 32
        )
    }

    public static func seal<T: Encodable>(_ value: T, key: SymmetricKey) throws -> Data {
        let plaintext = try CanonicalCoding.encode(value)
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return box.combined
    }

    public static func open<T: Decodable>(_ type: T.Type, combined: Data, key: SymmetricKey) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(box, using: key)
        } catch {
            throw AgentLinkError.decryptionFailed
        }
        return try CanonicalCoding.decoder().decode(type, from: plaintext)
    }
}

/// The mobile device's encrypted answer posted to the rendezvous mailbox.
public struct PairingResponse: Codable, Equatable {
    public let version: Int
    public let mobile: PublicDeviceIdentity
    public let mobileDisplayName: String
    public let mobileEphemeralPublicKey: Data
    public let supportedVersions: [Int]
    /// Ed25519 signature by the mobile signing key over the canonical encoding
    /// of this response with `signature` empty — binds the long-lived identity
    /// to this handshake.
    public var signature: Data

    enum CodingKeys: String, CodingKey {
        case version, mobile, signature
        case mobileDisplayName = "mobile_display_name"
        case mobileEphemeralPublicKey = "mobile_ephemeral_public_key"
        case supportedVersions = "supported_versions"
    }

    public init(mobile: PublicDeviceIdentity, mobileDisplayName: String,
                mobileEphemeralPublicKey: Data, supportedVersions: [Int] = [AgentLinkProtocolVersion.current]) {
        self.version = AgentLinkProtocolVersion.current
        self.mobile = mobile
        self.mobileDisplayName = mobileDisplayName
        self.mobileEphemeralPublicKey = mobileEphemeralPublicKey
        self.supportedVersions = supportedVersions
        self.signature = Data()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        mobile = try c.decode(PublicDeviceIdentity.self, forKey: .mobile)
        mobileDisplayName = try c.decode(String.self, forKey: .mobileDisplayName)
        mobileEphemeralPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .mobileEphemeralPublicKey))
        supportedVersions = try c.decode([Int].self, forKey: .supportedVersions)
        signature = try Base64URL.decode(c.decode(String.self, forKey: .signature))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(mobile, forKey: .mobile)
        try c.encode(mobileDisplayName, forKey: .mobileDisplayName)
        try c.encode(Base64URL.encode(mobileEphemeralPublicKey), forKey: .mobileEphemeralPublicKey)
        try c.encode(supportedVersions, forKey: .supportedVersions)
        try c.encode(Base64URL.encode(signature), forKey: .signature)
    }

    private var signingBody: PairingResponse {
        var copy = self
        copy.signature = Data()
        return copy
    }

    public mutating func sign(with key: Curve25519.Signing.PrivateKey) throws {
        signature = try key.signature(for: CanonicalCoding.encode(signingBody))
    }

    public func verifySignature() throws {
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: mobile.signingPublicKey)
        let body = try CanonicalCoding.encode(signingBody)
        guard pub.isValidSignature(signature, for: body) else { throw AgentLinkError.signatureInvalid }
    }
}
