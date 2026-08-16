import Foundation
import CryptoKit

/// QR payload version 2: Tailscale pairing. The Mac advertises the HTTPS/WSS
/// service it exposes through its embedded tailnet node; the phone (whose VPN
/// is provided by the official Tailscale iOS app) connects to `service_url`
/// and runs the existing application-level pairing handshake.
///
/// The payload deliberately never carries Tailscale auth keys, OAuth
/// credentials, login URLs, admin tokens, reusable application tokens, or raw
/// 100.x addresses — only the MagicDNS service URL taken from authenticated
/// Tailscale state, the Mac's public identity, an optional TLS pin, and a
/// single-use pairing ID + secret.
public struct PairingPayload: Codable, Equatable {
    public static let payloadType = "agent-link-tailscale-pairing"
    public static let payloadVersion = 2
    /// A pairing QR may not be valid for longer than this.
    public static let maximumLifetime: TimeInterval = 10 * 60

    public let type: String
    public let version: Int
    /// Where the Mac's transport service lives. In production this is the
    /// tailnet MagicDNS URL (`https://agentbox-ab12.<tailnet>.ts.net`); the
    /// development harness uses a loopback URL.
    public let serviceURL: String
    /// Which sandbox instance behind this Mac node the phone talks to.
    public let instanceID: String
    public let macDeviceID: String
    public let macDisplayName: String
    public let macSigningPublicKey: Data
    public let macPairingPublicKey: Data   // ephemeral X25519, base64url
    /// Base64 SHA-256 of the service certificate's SubjectPublicKeyInfo.
    /// Present only when the Mac serves a per-installation self-signed
    /// certificate (tailnet HTTPS disabled); nil with Tailscale-issued TLS.
    public let tlsPublicKeyHash: String?
    /// Random single-use pairing session ID; consuming it is atomic on the Mac.
    public let pairingID: String
    public let pairingSecret: Data          // one-time 32-byte secret, base64url
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case type, version
        case serviceURL = "service_url"
        case instanceID = "instance_id"
        case macDeviceID = "mac_device_id"
        case macDisplayName = "mac_display_name"
        case macSigningPublicKey = "mac_signing_public_key"
        case macPairingPublicKey = "mac_pairing_public_key"
        case tlsPublicKeyHash = "tls_public_key_hash"
        case pairingID = "pairing_id"
        case pairingSecret = "pairing_secret"
        case expiresAt = "expires_at"
    }

    public init(serviceURL: String, instanceID: String, macDeviceID: String,
                macDisplayName: String, macSigningPublicKey: Data,
                macPairingPublicKey: Data, tlsPublicKeyHash: String?,
                pairingID: String, pairingSecret: Data, expiresAt: Date) {
        self.type = Self.payloadType
        self.version = Self.payloadVersion
        self.serviceURL = serviceURL
        self.instanceID = instanceID
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.macSigningPublicKey = macSigningPublicKey
        self.macPairingPublicKey = macPairingPublicKey
        self.tlsPublicKeyHash = tlsPublicKeyHash
        self.pairingID = pairingID
        self.pairingSecret = pairingSecret
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        version = try c.decode(Int.self, forKey: .version)
        serviceURL = try c.decode(String.self, forKey: .serviceURL)
        instanceID = try c.decode(String.self, forKey: .instanceID)
        macDeviceID = try c.decode(String.self, forKey: .macDeviceID)
        macDisplayName = try c.decode(String.self, forKey: .macDisplayName)
        macSigningPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .macSigningPublicKey))
        macPairingPublicKey = try Base64URL.decode(c.decode(String.self, forKey: .macPairingPublicKey))
        tlsPublicKeyHash = try c.decodeIfPresent(String.self, forKey: .tlsPublicKeyHash)
        pairingID = try c.decode(String.self, forKey: .pairingID)
        pairingSecret = try Base64URL.decode(c.decode(String.self, forKey: .pairingSecret))
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(version, forKey: .version)
        try c.encode(serviceURL, forKey: .serviceURL)
        try c.encode(instanceID, forKey: .instanceID)
        try c.encode(macDeviceID, forKey: .macDeviceID)
        try c.encode(macDisplayName, forKey: .macDisplayName)
        try c.encode(Base64URL.encode(macSigningPublicKey), forKey: .macSigningPublicKey)
        try c.encode(Base64URL.encode(macPairingPublicKey), forKey: .macPairingPublicKey)
        try c.encodeIfPresent(tlsPublicKeyHash, forKey: .tlsPublicKeyHash)
        try c.encode(pairingID, forKey: .pairingID)
        try c.encode(Base64URL.encode(pairingSecret), forKey: .pairingSecret)
        try c.encode(expiresAt, forKey: .expiresAt)
    }

    /// Full validation of a scanned payload before any network contact:
    /// type, version, expiry, entropy, key lengths, and a service URL that is
    /// either HTTPS or a loopback development URL. Non-loopback IP-literal
    /// hosts (e.g. a bare 100.x address) are rejected — production payloads
    /// carry the MagicDNS name.
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
        guard payload.version == payloadVersion else {
            throw AgentLinkError.unsupportedVersion(payload.version)
        }
        guard payload.macSigningPublicKey.count == 32, payload.macPairingPublicKey.count == 32 else {
            throw AgentLinkError.invalidKeyLength
        }
        guard payload.pairingSecret.count >= 32 else { throw AgentLinkError.lowEntropyField("pairing_secret") }
        guard payload.pairingID.count >= 16 else { throw AgentLinkError.lowEntropyField("pairing_id") }
        guard !payload.instanceID.isEmpty else { throw AgentLinkError.malformedMessage("instance_id missing") }
        guard payload.expiresAt > now else { throw AgentLinkError.payloadExpired }
        guard payload.expiresAt.timeIntervalSince(now) <= maximumLifetime else {
            throw AgentLinkError.payloadLifetimeTooLong
        }
        try validateServiceURL(payload.serviceURL)
        return payload
    }

    static func validateServiceURL(_ string: String) throws {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            throw AgentLinkError.malformedMessage("service_url is not a valid URL")
        }
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        switch scheme {
        case "https":
            break
        case "http" where isLoopback:
            break  // development harness only
        default:
            throw AgentLinkError.malformedMessage("service_url must be https (or loopback http in development)")
        }
        // Reject raw IP hosts other than loopback: production payloads must use
        // the MagicDNS name, never a bare tailnet IP.
        if !isLoopback, host.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil {
            throw AgentLinkError.malformedMessage("service_url must use a DNS name, not an IP address")
        }
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

/// The mobile device's encrypted answer submitted to the Mac's pairing
/// endpoint.
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
