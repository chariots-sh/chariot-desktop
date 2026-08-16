import Foundation
import Virtualization

/// Owns one VZVirtualMachine. All Virtualization.framework calls happen on
/// `queue`, per the framework's threading contract.
final class VMController: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let instanceID: SandboxID
    private let paths: InstancePaths
    private let configuration: SandboxConfiguration
    private let queue = DispatchQueue(label: "chariot.vm")
    private var machine: VZVirtualMachine?
    private var consoleHandle: FileHandle?
    private(set) var state: SandboxState = .stopped
    var onStateChange: (@Sendable (SandboxState) -> Void)?

    init(instanceID: SandboxID, paths: InstancePaths, configuration: SandboxConfiguration) {
        self.instanceID = instanceID
        self.paths = paths
        self.configuration = configuration
    }

    private func setState(_ new: SandboxState) {
        state = new
        onStateChange?(new)
    }

    // MARK: Configuration

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = max(configuration.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        config.memorySize = max(configuration.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize)

        // EFI boot for the generic cloud image.
        let bootLoader = VZEFIBootLoader()
        if FileManager.default.fileExists(atPath: paths.efiVariableStore.path) {
            bootLoader.variableStore = VZEFIVariableStore(url: paths.efiVariableStore)
        } else {
            bootLoader.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: paths.efiVariableStore)
        }
        config.bootLoader = bootLoader

        let platform = VZGenericPlatformConfiguration()
        if let data = try? Data(contentsOf: paths.machineIdentifier),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = identifier
        } else {
            let identifier = VZGenericMachineIdentifier()
            try identifier.dataRepresentation.write(to: paths.machineIdentifier)
            platform.machineIdentifier = identifier
        }
        config.platform = platform

        // Storage: writable disk + read-only cloud-init seed.
        let disk = try VZDiskImageStorageDeviceAttachment(url: paths.writableDisk, readOnly: false)
        let seed = try VZDiskImageStorageDeviceAttachment(url: paths.seedISO, readOnly: true)
        config.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: disk),
            VZVirtioBlockDeviceConfiguration(attachment: seed)
        ]

        // NAT egress only (design §2.1).
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [network]

        // Host↔guest control channel (design §1.4).
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Serial console captured to a log file for diagnostics.
        FileManager.default.createFile(atPath: paths.consoleLog.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: paths.consoleLog)
        consoleHandle = logHandle
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil,
                                                             fileHandleForWriting: logHandle)
        config.serialPorts = [serial]

        try config.validate()
        return config
    }

    // MARK: Lifecycle

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    if self.machine == nil {
                        let vm = VZVirtualMachine(configuration: try self.makeConfiguration(), queue: self.queue)
                        vm.delegate = self
                        self.machine = vm
                    }
                    guard let vm = self.machine, vm.canStart else {
                        throw ChariotError.invalidState("VM cannot start in state \(String(describing: self.machine?.state))")
                    }
                    self.setState(.starting)
                    vm.start { result in
                        switch result {
                        case .success:
                            self.setState(.running)
                            cont.resume()
                        case .failure(let error):
                            self.setState(.failed)
                            cont.resume(throwing: ChariotError.vmFailure("start: \(error)"))
                        }
                    }
                } catch {
                    self.setState(.failed)
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let vm = self.machine, vm.state == .running || vm.state == .paused else {
                    self.machine = nil
                    self.setState(.stopped)
                    cont.resume()
                    return
                }
                self.setState(.stopping)
                let finish: @Sendable (Error?) -> Void = { error in
                    self.machine = nil
                    self.setState(.stopped)
                    if let error { cont.resume(throwing: ChariotError.vmFailure("stop: \(error)")) }
                    else { cont.resume() }
                }
                if vm.canRequestStop {
                    // Graceful ACPI shutdown with a forced-stop fallback. The
                    // pending completion is the single-resume token: whoever
                    // takes it (the delegate when the guest powers off, or
                    // this fallback) owns the continuation. Both run on
                    // `queue`, so taking it is atomic — without this, a guest
                    // finishing its ACPI shutdown right as the fallback force-
                    // stops resumed the continuation twice and crashed.
                    try? vm.requestStop()
                    self.pendingStopCompletion = finish
                    self.queue.asyncAfter(deadline: .now() + 15) {
                        guard let pending = self.pendingStopCompletion else { return }
                        self.pendingStopCompletion = nil
                        if let vm = self.machine, vm.state != .stopped, vm.canStop {
                            vm.stop { _ in pending(nil) }
                        } else {
                            // Owning the token means the delegate never fired;
                            // resume rather than leak the continuation.
                            pending(nil)
                        }
                    }
                } else if vm.canStop {
                    vm.stop { error in finish(error) }
                } else {
                    finish(nil)
                }
            }
        }
    }

    private var pendingStopCompletion: (@Sendable (Error?) -> Void)?

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        ChariotLog.log("guest powered off")
        let completion = pendingStopCompletion
        pendingStopCompletion = nil
        if let completion {
            completion(nil)
        } else {
            machine = nil
            setState(.stopped)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        ChariotLog.log("guest stopped with error: \(error)")
        let completion = pendingStopCompletion
        pendingStopCompletion = nil
        machine = nil
        setState(.failed)
        completion?(error)
    }

    // MARK: vsock

    /// Connect to a vsock port in the guest, retrying while the guest boots.
    func connectSocket(port: UInt32, timeout: TimeInterval = 180) async throws -> VZVirtioSocketConnection {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try await connectOnce(port: port)
            } catch {
                if Date() > deadline {
                    throw ChariotError.bridgeUnavailable("vsock port \(port) not reachable within \(Int(timeout))s: \(error)")
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func connectOnce(port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<VZVirtioSocketConnection, Error>) in
            queue.async {
                guard let vm = self.machine, vm.state == .running,
                      let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    cont.resume(throwing: ChariotError.invalidState("VM not running"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let connection): cont.resume(returning: connection)
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}
