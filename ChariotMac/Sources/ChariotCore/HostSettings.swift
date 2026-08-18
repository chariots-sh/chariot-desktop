import Foundation

/// App-level (per-Mac) configuration persisted in the data directory.
///
/// `settings.json` holds non-secret defaults (the local model server). The
/// Chariot account credential lives separately in
/// `identity/chariot-account.json` at 0600, matching the repo's
/// files-not-Keychain convention (mac-identity.json).
public struct HostSettings: Codable, Sendable, Equatable {
    /// Defaults for `.local`-powered agents; per-agent record fields override.
    public struct LocalModel: Codable, Sendable, Equatable {
        /// OpenAI-compatible base URL on the Mac, e.g. "http://127.0.0.1:11434/v1".
        public var baseURL: String?
        public var model: String?

        enum CodingKeys: String, CodingKey {
            case baseURL = "base_url"
            case model
        }

        public init(baseURL: String? = nil, model: String? = nil) {
            self.baseURL = baseURL
            self.model = model
        }
    }

    public var localModel: LocalModel?

    enum CodingKeys: String, CodingKey {
        case localModel = "local_model"
    }

    public init(localModel: LocalModel? = nil) {
        self.localModel = localModel
    }

    public static func load(from url: URL) -> HostSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(HostSettings.self, from: data) else {
            return HostSettings()
        }
        return settings
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The signed-in Chariot account: a durable API credential for
/// https://app.chariots.sh plus the display email. 0600 on disk.
public struct ChariotAccountCredential: Codable, Sendable, Equatable {
    /// Bearer credential for the backend: the session JWT from the device
    /// flow, or an `X-Chariot-Token` seed. `kind` says which header to use.
    public enum Kind: String, Codable, Sendable {
        case sessionJWT = "session_jwt"
        case tokenSeed = "token_seed"
    }

    public var kind: Kind
    public var secret: String
    public var email: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case secret
        case email
    }

    public init(kind: Kind, secret: String, email: String? = nil) {
        self.kind = kind
        self.secret = secret
        self.email = email
    }

    public static func load(from url: URL) -> ChariotAccountCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChariotAccountCredential.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Per-agent registration with the backend: the external agent's identity and
/// its model-proxy bearer token, written once at creation into the agent's
/// instance directory. 0600 on disk; never enters the guest.
public struct ChariotAgentCredential: Codable, Sendable, Equatable {
    public var agentID: String
    public var slug: String
    public var agentToken: String

    enum CodingKeys: String, CodingKey {
        case agentID = "agent_id"
        case slug
        case agentToken = "agent_token"
    }

    public init(agentID: String, slug: String, agentToken: String) {
        self.agentID = agentID
        self.slug = slug
        self.agentToken = agentToken
    }

    public static func load(from url: URL) -> ChariotAgentCredential? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChariotAgentCredential.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
