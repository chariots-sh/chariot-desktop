import Foundation

/// Minimal URLSession client for the Chariot backend (https://app.chariots.sh):
/// the OAuth-style device sign-in, external-agent registration, and the two
/// per-agent mutations the desktop uses. Base URL overridable with
/// CHARIOT_BACKEND_URL for staging/local backends.
public struct ChariotAccountClient: Sendable {
    public struct DeviceStart: Sendable {
        public let deviceCode: String
        public let userCode: String
        /// Open this in the user's browser; they approve while signed in.
        public let approveURL: URL
        public let pollInterval: TimeInterval
        public let expiresIn: TimeInterval
    }

    public enum ClientError: Error, LocalizedError {
        case badStatus(Int, String)
        case malformedResponse
        case notSignedIn

        public var errorDescription: String? {
            switch self {
            case .badStatus(let code, let detail):
                return "chariot backend returned \(code): \(detail)"
            case .malformedResponse: return "chariot backend returned an unexpected payload"
            case .notSignedIn: return "not signed in to a Chariot account"
            }
        }
    }

    public let baseURL: URL

    public init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else if let raw = ProcessInfo.processInfo.environment["CHARIOT_BACKEND_URL"],
                  let url = URL(string: raw) {
            self.baseURL = url
        } else {
            self.baseURL = URL(string: "https://app.chariots.sh")!
        }
    }

    // MARK: - Device sign-in

    public func startDeviceSignIn() async throws -> DeviceStart {
        let json = try await request("POST", "/v1/auth/device/start", body: [:])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri_complete"] as? String,
              let approveURL = URL(string: uri) else {
            throw ClientError.malformedResponse
        }
        return DeviceStart(
            deviceCode: deviceCode,
            userCode: userCode,
            approveURL: approveURL,
            pollInterval: TimeInterval(json["interval"] as? Int ?? 3),
            expiresIn: TimeInterval(json["expires_in"] as? Int ?? 600))
    }

    /// One poll of the device flow: the session JWT once approved, nil while
    /// pending (202). Throws on an expired/unknown code (400).
    public func pollDeviceToken(deviceCode: String) async throws -> String? {
        let (data, status) = try await rawRequest(
            "POST", "/v1/auth/device/token", body: ["device_code": deviceCode])
        if status == 202 { return nil }
        guard status == 200 else {
            throw ClientError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw ClientError.malformedResponse
        }
        return token
    }

    /// The signed-in account's email, used as the Settings display line and
    /// as a validity probe for a stored credential.
    public func accountEmail(credential: ChariotAccountCredential) async throws -> String {
        let json = try await request("GET", "/v1/account", credential: credential)
        guard let email = json["email"] as? String else { throw ClientError.malformedResponse }
        return email
    }

    // MARK: - External agents

    /// Register this desktop agent with the backend. The returned credential
    /// carries the proxy bearer token, which the response surfaces exactly
    /// once — persist it immediately.
    public func registerExternalAgent(
        credential: ChariotAccountCredential, name: String?
    ) async throws -> ChariotAgentCredential {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        let json = try await request(
            "POST", "/v1/agents/external", body: body, credential: credential)
        guard let id = json["id"] as? String,
              let slug = json["slug"] as? String,
              let token = json["agent_token"] as? String else {
            throw ClientError.malformedResponse
        }
        return ChariotAgentCredential(agentID: id, slug: slug, agentToken: token)
    }

    /// Best-effort mirror of a local model override onto the backend row so
    /// the proxy's server-side resolution agrees with the harness config.
    public func setAgentModel(
        credential: ChariotAccountCredential, agentID: String, model: String?
    ) async throws {
        _ = try await request(
            "PUT", "/v1/agents/\(agentID)/model",
            body: ["model": model as Any], credential: credential)
    }

    public func deleteAgent(
        credential: ChariotAccountCredential, agentID: String
    ) async throws {
        _ = try await request("DELETE", "/v1/agents/\(agentID)", credential: credential)
    }

    // MARK: - Plumbing

    private func request(
        _ method: String, _ path: String,
        body: [String: Any]? = nil,
        credential: ChariotAccountCredential? = nil
    ) async throws -> [String: Any] {
        let (data, status) = try await rawRequest(
            method, path, body: body, credential: credential)
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["detail"] as? String }
            throw ClientError.badStatus(status, detail ?? String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.malformedResponse
        }
        return json
    }

    private func rawRequest(
        _ method: String, _ path: String,
        body: [String: Any]? = nil,
        credential: ChariotAccountCredential? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let credential {
            switch credential.kind {
            case .sessionJWT:
                request.setValue("Bearer \(credential.secret)", forHTTPHeaderField: "Authorization")
            case .tokenSeed:
                request.setValue(credential.secret, forHTTPHeaderField: "X-Chariot-Token")
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.malformedResponse }
        return (data, http.statusCode)
    }
}
