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

    static func createSeedISO(instance: InstancePaths, guestResources: URL,
                              harness: HarnessKind = .codex) throws {
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
            .replacingOccurrences(of: "__HARNESS__", with: harness.rawValue)
            .replacingOccurrences(of: "__HARNESS_INSTALL__", with: installBlock(for: harness))

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

    /// The chosen harness's cloud-init preinstall, substituted for
    /// __HARNESS_INSTALL__ (a runcmd list item, so two-space indented). Every
    /// step tolerates failure — bridge.py's ensure_harness_forever self-heals,
    /// exactly as the codex install always has. Pins mirror the backend
    /// images (ProtocolsBackend chariot/images/*/Dockerfile).
    static func installBlock(for harness: HarnessKind) -> String {
        switch harness {
        case .codex:
            // Both binaries, not just `codex`: the bridge's installed() check
            // requires every entry, so installing one left the agent at
            // installed=false after a successful boot.
            return """
              - |
                for pair in "codex-aarch64-unknown-linux-musl:/usr/local/bin/codex" \\
                            "codex-code-mode-host-aarch64-unknown-linux-musl:/usr/local/bin/codex-code-mode-host"; do
                  asset="${pair%%:*}"
                  dest="${pair##*:}"
                  curl -fsSL -o "/tmp/$asset.tar.gz" \\
                    "https://github.com/openai/codex/releases/download/rust-v0.147.0/$asset.tar.gz" \\
                    && tar -xzf "/tmp/$asset.tar.gz" -C /tmp \\
                    && mv "/tmp/$asset" "$dest" \\
                    && chmod 755 "$dest" \\
                    && rm -f "/tmp/$asset.tar.gz" || true
                done
            """
        case .zeroclaw:
            return """
              - |
                curl -fsSL -o /tmp/zeroclaw.tar.gz \\
                  "https://github.com/zeroclaw-labs/zeroclaw/releases/download/v0.7.5/zeroclaw-aarch64-unknown-linux-musl.tar.gz" \\
                  && tar -xzf /tmp/zeroclaw.tar.gz -C /tmp \\
                  && mv /tmp/zeroclaw /usr/local/bin/zeroclaw \\
                  && chmod 755 /usr/local/bin/zeroclaw \\
                  && rm -f /tmp/zeroclaw.tar.gz || true
            """
        case .openclaw:
            return """
              - |
                curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \\
                  && DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs \\
                  && npm install -g openclaw@2026.6.11 || true
            """
        case .hermes:
            return """
              - |
                python3 -m venv /opt/hermes \\
                  && /opt/hermes/bin/pip install --no-cache-dir hermes-agent==0.18.0 || true
            """
        case .muse:
            return """
              - |
                MUSE_INSTALL_DIR=/usr/local/bin MUSE_NO_MODIFY_PATH=1 MUSE_NO_AUTO_UPDATE=1 \\
                  bash -c 'curl -fsSL https://dev.meta.ai/install.sh | bash' || true
            """
        }
    }
}
