import Foundation
import CryptoKit

/// Long-lived device identity: an Ed25519 signing key and an X25519 key-agreement key.
/// Private halves are stored by the platform apps (Keychain); this type is the in-memory form.
public struct DeviceIdentity {
    public let deviceID: String
    public let signingKey: Curve25519.Signing.PrivateKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init(deviceID: String = UUID().uuidString.lowercased(),
                signingKey: Curve25519.Signing.PrivateKey = .init(),
                agreementKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.deviceID = deviceID
        self.signingKey = signingKey
        self.agreementKey = agreementKey
    }

    public var publicIdentity: PublicDeviceIdentity {
        PublicDeviceIdentity(
            deviceID: deviceID,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            agreementPublicKey: agreementKey.publicKey.rawRepresentation
        )
    }

    // MARK: Persistence

    public struct Stored: Codable {
        public let deviceID: String
        public let signingPrivateKey: String
        public let agreementPrivateKey: String
    }

    public func stored() -> Stored {
        Stored(deviceID: deviceID,
               signingPrivateKey: Base64URL.encode(signingKey.rawRepresentation),
               agreementPrivateKey: Base64URL.encode(agreementKey.rawRepresentation))
    }

    public init(stored: Stored) throws {
        self.deviceID = stored.deviceID
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Base64URL.decode(stored.signingPrivateKey))
        self.agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Base64URL.decode(stored.agreementPrivateKey))
    }
}

public struct PublicDeviceIdentity: Codable, Equatable, Sendable {
    public let deviceID: String
    public let signingPublicKey: Data
    public let agreementPublicKey: Data

    public init(deviceID: String, signingPublicKey: Data, agreementPublicKey: Data) {
        self.deviceID = deviceID
        self.signingPublicKey = signingPublicKey
        self.agreementPublicKey = agreementPublicKey
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case signingPublicKey = "signing_public_key"
        case agreementPublicKey = "agreement_public_key"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        signingPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .signingPublicKey))
        agreementPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .agreementPublicKey))
        guard signingPublicKey.count == 32, agreementPublicKey.count == 32 else {
            throw AgentLinkError.invalidKeyLength
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(Base64URL.encode(signingPublicKey), forKey: .signingPublicKey)
        try c.encode(Base64URL.encode(agreementPublicKey), forKey: .agreementPublicKey)
    }

    /// Human-comparable fingerprint shown on both devices after pairing.
    public var fingerprint: String {
        let digest = SHA256.hash(data: signingPublicKey + agreementPublicKey)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // Group as xxxx-xxxx-xxxx-xxxx from the first 16 hex chars.
        let head = String(hex.prefix(16))
        return stride(from: 0, to: 16, by: 4).map {
            let s = head.index(head.startIndex, offsetBy: $0)
            let e = head.index(s, offsetBy: 4)
            return String(head[s..<e])
        }.joined(separator: "-")
    }
}
