import Foundation
import AgentLinkKit

/// One created agent (Guardian on Chariot, Milestone 1).
///
/// The instance UUID minted at creation is the durable identity: it names the
/// on-disk instance, keys envelope routing, and is the pairing endpoint.
/// Pack id and display name are cosmetic labels — nothing durable (grants,
/// routing, pairing) ever binds to them.
public struct AgentRecord: Codable, Sendable, Equatable {
    public let instanceID: String
    public var packID: String
    public var displayName: String
    /// Folder name under `<data-dir>/packs/`, e.g. "guardian.pack".
    public var packDirectoryName: String
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case packID = "pack_id"
        case displayName = "display_name"
        case packDirectoryName = "pack_directory"
        case createdAt = "created_at"
    }
}

/// Snapshot of one agent for the GUI sidebar and the admin surface.
public struct AgentSummary: Sendable {
    public let record: AgentRecord
    public let vmState: SandboxState
    public let bridgeConnected: Bool
    public let agentStatus: AgentRuntimeStatus?
    public let epoch: UInt32
    public let pairedDeviceCount: Int
}

/// Checksums of the pack content last installed into a guest, persisted next
/// to the instance so restarts skip unchanged files. Reset deletes the file,
/// forcing a full replay onto the re-cloned disk.
struct PackInstallState: Codable {
    var checksums: [String: String] = [:]  // guest destination → SHA-256
}

/// Per-agent runtime state inside ChariotHub. Everything that used to be
/// hub-global for the single VM — device registry and epoch, bridge, guest
/// status, replay windows, login tunnel — lives here, one per agent, so
/// agents are isolated from each other end to end. All mutable state is
/// guarded by the hub's lock.
final class AgentContext {
    /// Canonical routing key: the agent's instance UUID, or "default" for the
    /// legacy single-VM/loopback development context.
    let key: String
    var record: AgentRecord?
    /// The sandbox instance this context boots. Fixed for agents; the legacy
    /// context adopts whatever instance `ensureInstance` finds or creates.
    var vmInstanceID: SandboxID?
    var registry = DeviceRegistry()
    let registryURL: URL
    let packStateURL: URL?
    var bridge: BridgeClient?
    var agentStatus: AgentRuntimeStatus?
    var lastGuestStatus: (state: String, kernel: String, hostname: String)?
    var replayWindows: [String: ReplayWindow] = [:]
    var loginTunnel: VsockPortForwarder?
    var developerAccess: DeveloperAccess?
    var packInstalled: [String: String] = [:]

    init(key: String, record: AgentRecord?, vmInstanceID: SandboxID?,
         registryURL: URL, packStateURL: URL?) {
        self.key = key
        self.record = record
        self.vmInstanceID = vmInstanceID
        self.registryURL = registryURL
        self.packStateURL = packStateURL
        if let data = try? Data(contentsOf: registryURL),
           let loaded = try? CanonicalCoding.decoder().decode(DeviceRegistry.self, from: data) {
            registry = loaded
        }
        if let packStateURL,
           let data = try? Data(contentsOf: packStateURL),
           let loaded = try? JSONDecoder().decode(PackInstallState.self, from: data) {
            packInstalled = loaded.checksums
        }
    }
}
