import Foundation
import CryptoKit

/// Application frames carried as JSON text messages over the persistent
/// WebSocket between phone and Mac (over the tailnet in production, loopback
/// in the development harness).
///
/// Flow: on connect the server sends `challenge`; the client answers `hello`
/// with an Ed25519 signature over the nonce, proving control of a paired
/// device key before any ciphertext is exchanged (tailnet membership alone is
/// never sufficient authorization). After `welcome`, both sides exchange
/// `envelope` and `ack` frames; the server keeps envelopes durably queued
/// until acked and the client deduplicates via its replay window.
public struct TransportFrame: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case challenge   // server → client: {nonce}
        case hello       // client → server: {deviceID, instanceID, signature}
        case welcome     // server → client: {epoch, macDeviceID}
        case envelope    // both directions
        case ack         // both directions: {messageIDs}
        case status      // server → client: {vmState, bridgeConnected, epoch}
        case revoked     // server → client, then close
        case denied      // server → client: authentication failed, then close
        case error       // either: {message}
    }

    public let type: Kind
    public var nonce: String?
    public var deviceID: String?
    public var instanceID: String?
    public var signature: String?
    public var epoch: UInt32?
    public var macDeviceID: String?
    public var envelope: EncryptedEnvelope?
    public var messageIDs: [String]?
    public var vmState: String?
    public var bridgeConnected: Bool?
    public var message: String?

    enum CodingKeys: String, CodingKey {
        case type, nonce, signature, epoch, envelope, message
        case deviceID = "device_id"
        case instanceID = "instance_id"
        case macDeviceID = "mac_device_id"
        case messageIDs = "message_ids"
        case vmState = "vm_state"
        case bridgeConnected = "bridge_connected"
    }

    public init(type: Kind) {
        self.type = type
    }

    public static func decode(_ data: Data) throws -> TransportFrame {
        try CanonicalCoding.decoder().decode(TransportFrame.self, from: data)
    }

    public func encoded() throws -> Data {
        try CanonicalCoding.encode(self)
    }
}

/// Challenge-response authentication for the WebSocket session, using the
/// long-lived device signing keys established at pairing.
public enum TransportAuth {
    static func signedBytes(nonce: String, deviceID: String, instanceID: String) -> Data {
        Data("agent-link/ws-auth/v1|\(nonce)|\(deviceID)|\(instanceID)".utf8)
    }

    public static func signature(nonce: String, deviceID: String, instanceID: String,
                                 signingKey: Curve25519.Signing.PrivateKey) throws -> String {
        Base64URL.encode(try signingKey.signature(for: signedBytes(nonce: nonce,
                                                                   deviceID: deviceID,
                                                                   instanceID: instanceID)))
    }

    public static func verify(nonce: String, deviceID: String, instanceID: String,
                              signature: String, signingPublicKey: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey),
              let sig = try? Base64URL.decode(signature) else { return false }
        return pub.isValidSignature(sig, for: signedBytes(nonce: nonce, deviceID: deviceID,
                                                          instanceID: instanceID))
    }
}
