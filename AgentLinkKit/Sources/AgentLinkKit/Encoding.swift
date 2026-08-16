import Foundation

public enum AgentLinkError: Error, Equatable {
    case invalidBase64URL
    case invalidKeyLength
    case unsupportedVersion(Int)
    case payloadExpired
    case payloadLifetimeTooLong
    case lowEntropyField(String)
    case invalidPayloadType(String)
    case signatureInvalid
    case envelopeExpired
    case replayDetected
    case sequenceRegression
    case decryptionFailed
    case malformedMessage(String)
    case epochMismatch
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) throws -> Data {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        guard let data = Data(base64Encoded: s) else { throw AgentLinkError.invalidBase64URL }
        return data
    }
}

public enum CanonicalCoding {
    /// Deterministic JSON encoding used for signatures and AEAD associated data.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum AgentLinkProtocolVersion {
    public static let current = 1
    public static let supported: Set<Int> = [1]
}
