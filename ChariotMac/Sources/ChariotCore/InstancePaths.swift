import Foundation

/// Filesystem layout for Chariot data (design §1.2).
public struct ChariotPaths: Sendable {
    public let dataDirectory: URL
    /// Directory containing bridge.py and user-data.template.
    public let guestResources: URL

    public init(dataDirectory: URL, guestResources: URL) {
        self.dataDirectory = dataDirectory
        self.guestResources = guestResources
    }

    public var identityDirectory: URL { dataDirectory.appendingPathComponent("identity") }
    public var instancesDirectory: URL { dataDirectory.appendingPathComponent("instances") }
    public var mailboxDirectory: URL { dataDirectory.appendingPathComponent("mailbox") }
    /// Agent packs (Milestone 1): one folder per pack.
    public var packsDirectory: URL { dataDirectory.appendingPathComponent("packs") }
    /// Fleet index: the created agents (instance UUID → pack provenance).
    public var agentsIndex: URL { dataDirectory.appendingPathComponent("agents.json") }
    /// App-level defaults (local model server); non-secret.
    public var hostSettings: URL { dataDirectory.appendingPathComponent("settings.json") }
    /// The signed-in Chariot account credential (0600).
    public var chariotAccount: URL { identityDirectory.appendingPathComponent("chariot-account.json") }

    public func instanceDirectory(_ id: SandboxID) -> URL {
        instancesDirectory.appendingPathComponent(id)
    }

    public func ensureDirectories() throws {
        for dir in [dataDirectory, identityDirectory, instancesDirectory, mailboxDirectory, packsDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public struct InstancePaths: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var writableDisk: URL { directory.appendingPathComponent("writable.img") }
    public var seedISO: URL { directory.appendingPathComponent("seed.iso") }
    public var efiVariableStore: URL { directory.appendingPathComponent("efi-vars.fd") }
    public var machineIdentifier: URL { directory.appendingPathComponent("machine-id.bin") }
    public var configuration: URL { directory.appendingPathComponent("configuration.json") }
    public var consoleLog: URL { directory.appendingPathComponent("console.log") }
    public var accessKey: URL { directory.appendingPathComponent("access-key") }
    public var accessKeyPublic: URL { directory.appendingPathComponent("access-key.pub") }
    public var sshConfig: URL { directory.appendingPathComponent("ssh_config") }
    public var knownHosts: URL { directory.appendingPathComponent("known_hosts") }
    /// Per-agent device registry: pairing is per agent instance (Milestone 1).
    public var deviceRegistry: URL { directory.appendingPathComponent("devices.json") }
    /// Checksums of the last pack content installed into the guest.
    public var packState: URL { directory.appendingPathComponent("pack-state.json") }
    /// Chariot-account power source: the backend registration + proxy bearer
    /// token for this agent (0600, host-only — never synced into the guest).
    public var chariotCredential: URL { directory.appendingPathComponent("chariot-agent.json") }
}
