import Foundation

/// Prepares per-instance disk artifacts: the writable disk cloned from the
/// immutable base image (design §1.3) and the cloud-init seed ISO that injects
/// the guest bridge and the developer-access SSH key.
enum SeedBuilder {

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ChariotError.io("\(tool) failed (\(process.terminationStatus)): \(err)")
        }
    }

    /// APFS-clone the immutable base image into the instance's writable disk,
    /// then grow it sparsely so cloud-init expands the root partition.
    static func createWritableDisk(base: URL, destination: URL, sizeBytes: UInt64) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.copyItem(at: base, to: destination)  // APFS clone on same volume
        } catch {
            throw ChariotError.io("cloning base image failed: \(error)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: sizeBytes)
    }

    static func createSeedISO(instance: InstancePaths, guestResources: URL) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: instance.accessKey.path) {
            try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C",
                                            "chariot-developer-access", "-f", instance.accessKey.path])
        }
        let publicKey = try String(contentsOf: instance.accessKeyPublic, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bridge = try Data(contentsOf: guestResources.appendingPathComponent("bridge.py"))
        let template = try String(contentsOf: guestResources.appendingPathComponent("user-data.template"),
                                  encoding: .utf8)

        let userData = template
            .replacingOccurrences(of: "__SSH_PUBKEY__", with: publicKey)
            .replacingOccurrences(of: "__BRIDGE_B64__", with: bridge.base64EncodedString())

        let work = fm.temporaryDirectory.appendingPathComponent("chariot-seed-\(UUID().uuidString)")
        let cidata = work.appendingPathComponent("cidata")
        try fm.createDirectory(at: cidata, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try userData.write(to: cidata.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        let instanceID = instance.directory.lastPathComponent
        let metaData = "instance-id: chariot-\(instanceID)\nlocal-hostname: chariot-sandbox\n"
        try metaData.write(to: cidata.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: instance.seedISO.path) {
            try fm.removeItem(at: instance.seedISO)
        }
        // hdiutil appends .iso when missing; give it the exact output path.
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet",
                                     "-default-volume-name", "cidata",
                                     "-o", instance.seedISO.path, cidata.path])
    }
}
