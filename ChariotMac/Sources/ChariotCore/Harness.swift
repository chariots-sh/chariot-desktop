import Foundation

/// The agentic runtime installed inside an agent's VM, mirroring the backend's
/// builtin image catalog (ProtocolsBackend chariot/handler/builtin_images.py).
/// The harness is chosen at agent creation and is cosmetic to identity: the
/// instance UUID stays the durable key regardless of harness.
public enum HarnessKind: String, Codable, CaseIterable, Sendable {
    case codex
    case zeroclaw
    case openclaw
    case hermes
    case muse

    /// Only Codex has a brokered ChatGPT OAuth sign-in (guest/bridge.py
    /// start_login); every other harness is powered through an API endpoint.
    public var supportsChatGPTLogin: Bool { self == .codex }

    /// A model the harness is co-trained with, used when neither the agent
    /// nor the app settings choose one. Mirrors the backend catalog, where
    /// muse is the only entry with a default_model.
    public var defaultModel: String? {
        self == .muse ? "meta/muse-spark-1.2" : nil
    }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .zeroclaw: return "ZeroClaw"
        case .openclaw: return "OpenClaw"
        case .hermes: return "Hermes"
        case .muse: return "Muse Code"
        }
    }
}

/// What supplies the model behind an agent's harness.
public enum PowerSourceKind: String, Codable, Sendable {
    /// The user's Chariot account: the backend's metered OpenAI-compatible
    /// proxy, authenticated with a per-agent token held on the Mac host only.
    case chariot
    /// A user-run OpenAI-compatible server on the Mac (e.g. Ollama).
    case local
    /// The existing brokered ChatGPT OAuth; codex harness only. The
    /// credential lives inside the guest (~agent/.codex/auth.json).
    case chatgpt
}

public enum HarnessError: Error, LocalizedError, Equatable {
    case chatgptRequiresCodex(HarnessKind)
    case noModelConfigured(HarnessKind)
    case localBaseURLMissing

    public var errorDescription: String? {
        switch self {
        case .chatgptRequiresCodex(let harness):
            return "ChatGPT sign-in only powers the codex harness, not \(harness.rawValue)"
        case .noModelConfigured(let harness):
            return "no model configured for \(harness.rawValue): set one on the agent or in Settings"
        case .localBaseURLMissing:
            return "no local model server URL: set one on the agent or in Settings"
        }
    }
}

/// The fully resolved power configuration pushed to a guest via
/// `agent.configure` and used by the host-side model broker.
public struct ResolvedPower: Sendable, Equatable {
    public let source: PowerSourceKind
    /// Model id the harness config names. Empty only for chatgpt (the Codex
    /// account's own default applies).
    public let model: String?
    /// Upstream base URL for the `.local` route (the user's server).
    public let localBaseURL: URL?
}

/// Model precedence, mirroring the backend chain (agent → account default →
/// harness default → error): the record's override wins, then the app-level
/// local default (local power only), then the harness's co-trained model.
/// For chariot power the model is advisory — the proxy re-resolves and
/// enforces server-side — but it is still rendered into the harness config
/// so both ends agree.
public func resolvePower(
    record: AgentRecord, settings: HostSettings.LocalModel?
) throws -> ResolvedPower {
    let harness = record.effectiveHarness
    switch record.effectivePowerSource {
    case .chatgpt:
        guard harness == .codex else { throw HarnessError.chatgptRequiresCodex(harness) }
        return ResolvedPower(source: .chatgpt, model: nil, localBaseURL: nil)
    case .chariot:
        let model = record.model ?? harness.defaultModel
        return ResolvedPower(source: .chariot, model: model, localBaseURL: nil)
    case .local:
        guard let raw = record.localBaseURL ?? settings?.baseURL,
              let url = URL(string: raw) else {
            throw HarnessError.localBaseURLMissing
        }
        guard let model = record.model ?? settings?.model ?? harness.defaultModel else {
            throw HarnessError.noModelConfigured(harness)
        }
        return ResolvedPower(source: .local, model: model, localBaseURL: url)
    }
}
