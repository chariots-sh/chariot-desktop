import Foundation

/// SandboxBackend implementation over Virtualization.framework (design §5.3).
public final class VirtualMachineBackend: SandboxBackend, @unchecked Sendable {
    let paths: ChariotPaths
    private var controllers: [SandboxID: VMController] = [:]
    private var configurations: [SandboxID: SandboxConfiguration] = [:]
    private let lock = NSLock()

    public var onStateChange: (@Sendable (SandboxID, SandboxState) -> Void)?

    public init(paths: ChariotPaths) {
        self.paths = paths
    }

    public func state(of id: SandboxID) -> SandboxState {
        lock.lock(); defer { lock.unlock() }
        if let controller = controllers[id] { return controller.state }
        let instance = InstancePaths(directory: paths.instanceDirectory(id))
        return FileManager.default.fileExists(atPath: instance.configuration.path) ? .stopped : .notCreated
    }

    public func existingInstanceIDs() -> [SandboxID] {
        (try? FileManager.default.contentsOfDirectory(atPath: paths.instancesDirectory.path))?.sorted() ?? []
    }

    func controller(for id: SandboxID) throws -> VMController {
        lock.lock(); defer { lock.unlock() }
        if let controller = controllers[id] { return controller }
        let instanceDir = paths.instanceDirectory(id)
        let instance = InstancePaths(directory: instanceDir)
        guard let data = try? Data(contentsOf: instance.configuration),
              let configuration = try? JSONDecoder().decode(SandboxConfiguration.self, from: data) else {
            throw ChariotError.instanceNotFound(id)
        }
        let controller = VMController(instanceID: id, paths: instance, configuration: configuration)
        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.onStateChange?(id, state)
        }
        controllers[id] = controller
        configurations[id] = configuration
        return controller
    }

    // MARK: SandboxBackend

    public func create(configuration: SandboxConfiguration) async throws -> SandboxID {
        try await createInstance(configuration: configuration,
                                 id: String(UUID().uuidString.prefix(8)).lowercased())
    }

    /// Create with a caller-chosen instance ID. Agents pass their full UUID:
    /// the instance UUID minted at agent creation is the durable identity and
    /// routing key (Milestone 1), so it names the on-disk instance too.
    public func createInstance(configuration: SandboxConfiguration, id: SandboxID) async throws -> SandboxID {
        let instance = InstancePaths(directory: paths.instanceDirectory(id))
        guard !FileManager.default.fileExists(atPath: instance.configuration.path) else {
            throw ChariotError.invalidState("instance \(id) already exists")
        }
        try FileManager.default.createDirectory(at: instance.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: instance.configuration)

        ChariotLog.log("instance \(id): creating writable disk from base image")
        try SeedBuilder.createWritableDisk(base: URL(fileURLWithPath: configuration.baseImagePath),
                                           destination: instance.writableDisk,
                                           sizeBytes: configuration.diskBytes)
        ChariotLog.log("instance \(id): building cloud-init seed")
        try SeedBuilder.createSeedISO(instance: instance, guestResources: paths.guestResources,
                                      harness: configuration.harness.flatMap(HarnessKind.init(rawValue:)) ?? .codex)
        return id
    }

    public func start(_ id: SandboxID) async throws {
        try await controller(for: id).start()
    }

    public func stop(_ id: SandboxID) async throws {
        try await controller(for: id).stop()
    }

    public func restart(_ id: SandboxID) async throws {
        try await stop(id)
        try await start(id)
    }

    /// Discard all guest changes and credentials; keep the instance identity
    /// (design §1.3 Reset).
    private func forgetController(_ id: SandboxID, dropConfiguration: Bool = false) {
        lock.lock()
        controllers[id] = nil
        if dropConfiguration { configurations[id] = nil }
        lock.unlock()
    }

    public func reset(_ id: SandboxID) async throws {
        let controller = try controller(for: id)
        try await controller.stop()
        forgetController(id)

        let instance = InstancePaths(directory: paths.instanceDirectory(id))
        guard let configuration = configurations[id] ?? (try? JSONDecoder().decode(
            SandboxConfiguration.self, from: Data(contentsOf: instance.configuration))) else {
            throw ChariotError.instanceNotFound(id)
        }
        for stale in [instance.writableDisk, instance.efiVariableStore, instance.seedISO,
                      instance.accessKey, instance.accessKeyPublic, instance.knownHosts,
                      instance.packState] {
            // pack-state.json goes too: the re-cloned disk has no pack
            // content, so the next boot must replay the full workspace.
            try? FileManager.default.removeItem(at: stale)
        }
        try SeedBuilder.createWritableDisk(base: URL(fileURLWithPath: configuration.baseImagePath),
                                           destination: instance.writableDisk,
                                           sizeBytes: configuration.diskBytes)
        // The persisted configuration carries the harness, so Reset rebuilds
        // the same seed the agent was created with.
        try SeedBuilder.createSeedISO(instance: instance, guestResources: paths.guestResources,
                                      harness: configuration.harness.flatMap(HarnessKind.init(rawValue:)) ?? .codex)
        ChariotLog.log("instance \(id): reset complete")
    }

    public func destroy(_ id: SandboxID) async throws {
        if let controller = try? controller(for: id) {
            try? await controller.stop()
        }
        forgetController(id, dropConfiguration: true)
        try FileManager.default.removeItem(at: paths.instanceDirectory(id))
        ChariotLog.log("instance \(id): destroyed")
    }

    public func importArtifact(_ source: URL, into id: SandboxID) async throws {
        throw ChariotError.invalidState("artifact import is routed through ChariotHub")
    }

    public func exportArtifact(_ path: String, from id: SandboxID) async throws -> URL {
        throw ChariotError.invalidState("artifact export is routed through ChariotHub")
    }
}
