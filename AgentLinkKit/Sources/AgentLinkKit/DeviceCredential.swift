import Foundation
import CryptoKit

/// Mac-issued credential binding both devices' permanent public identities (design §4.4 step 8).
public struct DeviceCredential: Codable, Equatable {
    public let version: Int
    public let credentialID: String
    public let mac: PublicDeviceIdentity
    public let mobile: PublicDeviceIdentity
    public let issuedAt: Date
    public var signature: Data  // Ed25519 by the Mac signing key

    enum CodingKeys: String, CodingKey {
        case version, mac, mobile, signature
        case credentialID = "credential_id"
        case issuedAt = "issued_at"
    }

    public init(credentialID: String = UUID().uuidString.lowercased(),
                mac: PublicDeviceIdentity, mobile: PublicDeviceIdentity, issuedAt: Date = Date()) {
        self.version = AgentLinkProtocolVersion.current
        self.credentialID = credentialID
        self.mac = mac
        self.mobile = mobile
        self.issuedAt = issuedAt
        self.signature = Data()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        credentialID = try c.decode(String.self, forKey: .credentialID)
        mac = try c.decode(PublicDeviceIdentity.self, forKey: .mac)
        mobile = try c.decode(PublicDeviceIdentity.self, forKey: .mobile)
        issuedAt = try c.decode(Date.self, forKey: .issuedAt)
        signature = try Base64URL.decode(c.decode(String.self, forKey: .signature))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(credentialID, forKey: .credentialID)
        try c.encode(mac, forKey: .mac)
        try c.encode(mobile, forKey: .mobile)
        try c.encode(issuedAt, forKey: .issuedAt)
        try c.encode(Base64URL.encode(signature), forKey: .signature)
    }

    private var signingBody: DeviceCredential {
        var copy = self
        copy.signature = Data()
        return copy
    }

    public mutating func sign(with key: Curve25519.Signing.PrivateKey) throws {
        signature = try key.signature(for: CanonicalCoding.encode(signingBody))
    }

    /// Verify against the Mac signing key pinned from the QR payload.
    public func verify(pinnedMacSigningKey: Data) throws {
        guard mac.signingPublicKey == pinnedMacSigningKey else { throw AgentLinkError.signatureInvalid }
        let pub = try Curve25519.Signing.PublicKey(rawRepresentation: mac.signingPublicKey)
        let body = try CanonicalCoding.encode(signingBody)
        guard pub.isValidSignature(signature, for: body) else { throw AgentLinkError.signatureInvalid }
    }
}
