import Foundation

/// Application-level message types carried inside encrypted envelopes and over
/// the host↔guest bridge (design §1.4, §7).
///
/// Body schemas for the phone-data surface (all fields snake_case; `body` is a
/// schema-flexible JSON object, so additions here are wire-compatible):
///
/// - `conversation.send`: `{"text": String, "attachments": [String]?}` —
///   `attachments` lists absolute guest paths under `/workspace/data/attachments/`
///   that the sender uploaded via `file.write` before this message. Optional;
///   receivers that predate it ignore the key.
/// - `tool.call` (Mac → phone): `{"request_id": String, "name": String,
///   "arguments": {…}, "turn_id": String?, "expires_at": Number?}` —
///   `turn_id` is the `message_id` of the `conversation.send` whose turn issued
///   the call, so the phone can attribute results to the visible conversation.
///   `expires_at` (Unix seconds) lets a late-delivered phone drop a stale call
///   instead of executing it after the Mac has already timed out.
/// - `tool.result` (phone → Mac): `{"request_id": String, "ok": Bool,
///   "output": String, "user_visible_summary": String?, "error": String?}` —
///   `output` is the text handed back to the model; `user_visible_summary`, when
///   present, is the line the phone rendered into its own transcript.
public enum AgentMessageType: String, Codable, Sendable {
    case conversationSend = "conversation.send"
    case conversationCancel = "conversation.cancel"
    case outputDelta = "output.delta"
    case outputCompleted = "output.completed"
    case toolApprovalRequested = "tool.approval.requested"
    case toolApprovalRespond = "tool.approval.respond"
    case oauthRequested = "oauth.requested"
    case oauthCompleted = "oauth.completed"
    case sandboxStatus = "sandbox.status"
    case deviceRevoked = "device.revoked"
    case fileWrite = "file.write"
    case fileWriteResult = "file.write.result"
    case toolCall = "tool.call"
    case toolResult = "tool.result"
    case ack = "ack"
}

/// The plaintext application message (design §7). `body` is a JSON object whose
/// schema depends on `type`.
public struct AgentMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let messageID: String
    public let conversationID: String
    public let senderDeviceID: String
    public let sequence: UInt64
    public let type: AgentMessageType
    public let sentAt: Date
    public let body: JSONValue

    enum CodingKeys: String, CodingKey {
        case version, sequence, type, body
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case senderDeviceID = "sender_device_id"
        case sentAt = "sent_at"
    }

    public init(messageID: String = UUID().uuidString.lowercased(),
                conversationID: String,
                senderDeviceID: String,
                sequence: UInt64,
                type: AgentMessageType,
                sentAt: Date = Date(),
                body: JSONValue) {
        self.version = AgentLinkProtocolVersion.current
        self.messageID = messageID
        self.conversationID = conversationID
        self.senderDeviceID = senderDeviceID
        self.sequence = sequence
        self.type = type
        // ISO8601 wire format carries whole seconds; normalize so equality and
        // canonical encodings are stable across a round trip.
        self.sentAt = Date(timeIntervalSince1970: sentAt.timeIntervalSince1970.rounded(.down))
        self.body = body
    }
}

/// Minimal JSON value model so message bodies stay schema-flexible but Codable.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}
