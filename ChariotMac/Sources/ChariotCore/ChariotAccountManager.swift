import Foundation

/// The Mac's link to the user's Chariot account: device-flow sign-in, the
/// stored credential, app-level local-model defaults, and per-agent external
/// registration. One per hub; all state guarded by its own lock.
public final class ChariotAccountManager: @unchecked Sendable {
    public enum SignInState: Equatable, Sendable {
        case signedOut
        /// Waiting for the user to approve in the browser.
        case pending(approveURL: String)
        case signedIn(email: String?)
        case failed(String)
    }

    private let lock = NSLock()
    private let paths: ChariotPaths
    private let client: ChariotAccountClient
    private var credentialCache: ChariotAccountCredential?
    private var pendingPoll: Task<Void, Never>?
    private var state: SignInState

    public init(paths: ChariotPaths, client: ChariotAccountClient = ChariotAccountClient()) {
        self.paths = paths
        self.client = client
        let stored = ChariotAccountCredential.load(from: paths.chariotAccount)
        self.credentialCache = stored
        self.state = stored.map { .signedIn(email: $0.email) } ?? .signedOut
    }

    // MARK: - Sign-in

    public var signInState: SignInState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func credential() -> ChariotAccountCredential? {
        lock.lock(); defer { lock.unlock() }
        return credentialCache
    }

    /// Begin the device flow. Returns the approve URL to open in the user's
    /// browser and starts a background poll that persists the credential once
    /// approved. Restarting while pending abandons the previous code.
    public func startSignIn() async throws -> URL {
        let start = try await client.startDeviceSignIn()
        lock.lock()
        pendingPoll?.cancel()
        state = .pending(approveURL: start.approveURL.absoluteString)
        lock.unlock()
        let poll = Task { [client, weak self] in
            let deadline = Date().addingTimeInterval(start.expiresIn)
            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(start.pollInterval * 1_000_000_000))
                do {
                    guard let token = try await client.pollDeviceToken(deviceCode: start.deviceCode) else {
                        continue
                    }
                    var credential = ChariotAccountCredential(kind: .sessionJWT, secret: token)
                    credential.email = try? await client.accountEmail(credential: credential)
                    self?.store(credential)
                    return
                } catch {
                    self?.fail("sign-in failed: \(error.localizedDescription)")
                    return
                }
            }
            self?.fail("sign-in timed out; try again")
        }
        lock.lock()
        pendingPoll = poll
        lock.unlock()
        return start.approveURL
    }

    public func signOut() {
        lock.lock(); defer { lock.unlock() }
        pendingPoll?.cancel()
        pendingPoll = nil
        credentialCache = nil
        state = .signedOut
        try? FileManager.default.removeItem(at: paths.chariotAccount)
    }

    private func store(_ credential: ChariotAccountCredential) {
        lock.lock(); defer { lock.unlock() }
        credentialCache = credential
        state = .signedIn(email: credential.email)
        try? credential.save(to: paths.chariotAccount)
    }

    private func fail(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if case .pending = state { state = .failed(message) }
    }

    // MARK: - External agents

    /// Register a chariot-powered desktop agent and persist its proxy token
    /// into the instance directory (0600). Fails fast when signed out.
    /// Registration runs before the VM instance exists, so the directory is
    /// created here — losing the token to a missing directory would leak the
    /// just-minted backend row.
    public func registerAgent(displayName: String, instanceDirectory: URL) async throws -> ChariotAgentCredential {
        guard let credential = credential() else {
            throw ChariotAccountClient.ClientError.notSignedIn
        }
        // The backend's name grammar is a DNS label; the display name is
        // free-form, so register unnamed rather than surprise-failing.
        let name = Self.backendName(from: displayName)
        let agent = try await client.registerExternalAgent(credential: credential, name: name)
        do {
            try FileManager.default.createDirectory(at: instanceDirectory,
                                                    withIntermediateDirectories: true)
            try agent.save(to: InstancePaths(directory: instanceDirectory).chariotCredential)
        } catch {
            // The token is gone if we can't persist it; release the backend
            // row rather than stranding a registration nothing can use.
            try? await client.deleteAgent(credential: credential, agentID: agent.agentID)
            throw error
        }
        return agent
    }

    /// Best-effort deregistration for a creation that failed after the
    /// backend row was minted (e.g. the disk clone threw).
    public func deregisterAgent(instanceDirectory: URL) async {
        guard let credential = credential(),
              let agent = ChariotAgentCredential.load(
                from: InstancePaths(directory: instanceDirectory).chariotCredential) else { return }
        try? await client.deleteAgent(credential: credential, agentID: agent.agentID)
    }

    /// Mirror a model override onto the backend row (the proxy re-resolves
    /// per call, so this applies immediately). Best-effort by design.
    public func mirrorAgentModel(instanceDirectory: URL, model: String?) async {
        guard let credential = credential(),
              let agent = ChariotAgentCredential.load(
                from: InstancePaths(directory: instanceDirectory).chariotCredential) else { return }
        try? await client.setAgentModel(credential: credential, agentID: agent.agentID, model: model)
    }

    /// Lowercase the display name into the backend's DNS-label grammar; nil
    /// when nothing safe remains (registers unnamed).
    static func backendName(from displayName: String) -> String? {
        let lowered = displayName.lowercased().map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        var name = String(lowered)
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if name.isEmpty || name.count > 63 { return nil }
        // Reserved shapes (slug-alike, UUID-alike) are rejected server-side;
        // avoid the obvious one locally.
        if name.hasPrefix("agent-") { return nil }
        return name
    }

    // MARK: - Local model defaults

    public func hostSettings() -> HostSettings {
        HostSettings.load(from: paths.hostSettings)
    }

    public func setLocalModelDefaults(baseURL: String?, model: String?) throws {
        var settings = hostSettings()
        settings.localModel = HostSettings.LocalModel(baseURL: baseURL, model: model)
        try settings.save(to: paths.hostSettings)
    }
}
