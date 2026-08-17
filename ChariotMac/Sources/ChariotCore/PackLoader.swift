import Foundation
import CryptoKit

/// Pack format v1 (Guardian on Chariot, Milestone 1).
///
/// A pack is a folder dropped into `<data-dir>/packs/` — content only:
/// markdown (AGENTS.md, SOUL.md, MEMORY.seed.md), skills/ subfolders, and
/// tools/ scripts, described by a `pack.json` manifest. Creating an agent
/// from a pack yields a dedicated Codex VM whose /workspace is populated from
/// the manifest's `workspace` entries. Pack id and display name are cosmetic
/// labels; the durable identity is the agent instance UUID minted at creation.
/// Scripts shipped in a pack run inside the VM only — no new capability
/// beyond the unsandboxed shell Codex already has there.
public struct PackManifest: Codable, Sendable, Equatable {
    public struct VMSize: Codable, Sendable, Equatable {
        public var cpus: Int?
        public var memoryMB: Int?
        public var diskGB: Int?
    }

    public struct WorkspaceEntry: Codable, Sendable, Equatable {
        /// Path relative to the pack folder; a directory is expanded
        /// recursively.
        public var src: String
        /// Absolute guest path, restricted to /workspace.
        public var dest: String
        /// Written only when the guest file does not exist yet (fresh
        /// instance or post-reset); never overwritten on re-populate.
        public var seedOnly: Bool?

        public init(src: String, dest: String, seedOnly: Bool? = nil) {
            self.src = src
            self.dest = dest
            self.seedOnly = seedOnly
        }
    }

    /// Namespaced cosmetic identifier, e.g. "com.protocols.guardian".
    /// Nothing durable (grants, routing, pairing) ever binds to it.
    public let id: String
    public let name: String
    public let version: String
    public let vm: VMSize?
    public let workspace: [WorkspaceEntry]
    // A "data" field (phone data providers) is reserved for Milestone 2;
    // unknown keys are ignored by decoding, so v1 loaders accept such packs.

    public init(id: String, name: String, version: String, vm: VMSize? = nil,
                workspace: [WorkspaceEntry] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.vm = vm
        self.workspace = workspace
    }
}

public enum PackError: Error, CustomStringConvertible, Equatable {
    case manifestMissing(String)
    case manifestInvalid(String)
    case invalidEntry(String)
    case sourceMissing(String)

    public var description: String {
        switch self {
        case .manifestMissing(let s): return "pack.json missing in \(s)"
        case .manifestInvalid(let s): return "pack.json invalid: \(s)"
        case .invalidEntry(let s): return "invalid workspace entry: \(s)"
        case .sourceMissing(let s): return "workspace source missing: \(s)"
        }
    }
}

/// One concrete file to install in the guest, after directory expansion.
public struct PackFile: Sendable, Equatable {
    public let source: URL          // host file inside the pack folder
    public let destination: String  // absolute guest path under /workspace
    public let seedOnly: Bool
    public let executable: Bool
}

public struct Pack: Sendable {
    public static let guestWorkspace = "/workspace"

    public let directory: URL
    public let manifest: PackManifest

    /// Folder name under packs/, e.g. "guardian.pack" — how agents reference
    /// their pack on disk.
    public var directoryName: String { directory.lastPathComponent }

    /// Per-pack VM sizing over the standard defaults.
    public func configuration(baseImagePath: String) -> SandboxConfiguration {
        var configuration = SandboxConfiguration(baseImagePath: baseImagePath)
        if let cpus = manifest.vm?.cpus, cpus > 0 { configuration.cpuCount = cpus }
        if let memoryMB = manifest.vm?.memoryMB, memoryMB > 0 {
            configuration.memoryBytes = UInt64(memoryMB) * 1024 * 1024
        }
        if let diskGB = manifest.vm?.diskGB, diskGB > 0 {
            configuration.diskBytes = UInt64(diskGB) * 1024 * 1024 * 1024
        }
        return configuration
    }

    /// Expand the manifest's workspace entries into concrete files: a file
    /// entry maps 1:1, a directory entry recurses with the entry's dest as
    /// the root. Deterministically sorted by destination.
    public func workspaceFiles() throws -> [PackFile] {
        let fm = FileManager.default
        var files: [PackFile] = []
        for entry in manifest.workspace {
            let source = try resolveSource(entry.src)
            let seedOnly = entry.seedOnly ?? false
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw PackError.sourceMissing("\(directoryName)/\(entry.src)")
            }
            if isDirectory.boolValue {
                guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
                    throw PackError.sourceMissing("\(directoryName)/\(entry.src)")
                }
                for case let child as URL in walker {
                    guard (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                        continue
                    }
                    let relative = child.standardizedFileURL.path
                        .dropFirst(source.standardizedFileURL.path.count)
                        .drop(while: { $0 == "/" })
                    files.append(PackFile(source: child,
                                          destination: try Self.validateDestination(entry.dest + "/" + relative),
                                          seedOnly: seedOnly,
                                          executable: fm.isExecutableFile(atPath: child.path)))
                }
            } else {
                files.append(PackFile(source: source,
                                      destination: try Self.validateDestination(entry.dest),
                                      seedOnly: seedOnly,
                                      executable: fm.isExecutableFile(atPath: source.path)))
            }
        }
        return files.sorted { $0.destination < $1.destination }
    }

    /// SHA-256 per destination — the edit-detection fingerprint. Comparing
    /// against the last-installed snapshot yields exactly the files to
    /// hot-push into a running VM.
    public func checksums() throws -> [String: String] {
        var sums: [String: String] = [:]
        for file in try workspaceFiles() {
            let data = try Data(contentsOf: file.source)
            sums[file.destination] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return sums
    }

    /// A workspace src stays inside the pack folder: relative, no traversal.
    private func resolveSource(_ src: String) throws -> URL {
        guard !src.isEmpty, !src.hasPrefix("/") else {
            throw PackError.invalidEntry("src must be relative: \(src)")
        }
        let resolved = directory.appendingPathComponent(src).standardizedFileURL
        let root = directory.standardizedFileURL.path
        guard resolved.path == root || resolved.path.hasPrefix(root + "/") else {
            throw PackError.invalidEntry("src escapes the pack folder: \(src)")
        }
        return resolved
    }

    /// A dest is an absolute guest path confined to /workspace.
    static func validateDestination(_ dest: String) throws -> String {
        let normalized = (dest as NSString).standardizingPath
        guard normalized.hasPrefix(guestWorkspace + "/"), !normalized.contains("..") else {
            throw PackError.invalidEntry("dest must be under \(guestWorkspace): \(dest)")
        }
        return normalized
    }
}

public enum PackLoader {
    /// Packs live in `<data-dir>/packs/`, one folder per pack.
    public static func packsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("packs")
    }

    /// Parse and validate one pack folder.
    public static func load(at directory: URL) throws -> Pack {
        let manifestURL = directory.appendingPathComponent("pack.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PackError.manifestMissing(directory.lastPathComponent)
        }
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw PackError.manifestInvalid("\(directory.lastPathComponent): \(error)")
        }
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.version.isEmpty else {
            throw PackError.manifestInvalid("\(directory.lastPathComponent): id, name, and version are required")
        }
        let pack = Pack(directory: directory, manifest: manifest)
        // Surface bad entries at load time, not mid-populate.
        _ = try pack.workspaceFiles()
        return pack
    }

    /// Copies sample packs shipped inside the app bundle into the packs
    /// directory, and returns the names it added.
    ///
    /// A downloaded app has an empty packs directory, so without this there is
    /// nothing to create an agent from and the New Agent sheet is empty — the
    /// same shape of problem as shipping without the guest base image.
    ///
    /// Only packs whose folder is absent are copied. Packs are user-editable
    /// content — editing one lands on the agent's next turn — so an existing
    /// folder is never overwritten, and deleting a bundled pack makes it come
    /// back on next launch rather than staying deleted. That trade favours the
    /// common case (a fresh install needs packs) over the rare one (someone
    /// wants the samples gone).
    @discardableResult
    public static func seedBundledPacks(from bundledDirectory: URL,
                                        into packsDirectory: URL) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: bundledDirectory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var seeded: [String] = []
        for source in entries where source.pathExtension == "pack" {
            let destination = packsDirectory.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                seeded.append(source.lastPathComponent)
            } catch {
                ChariotLog.log("could not seed pack \(source.lastPathComponent): \(error)")
            }
        }
        return seeded
    }

    /// Every valid pack in the packs directory, sorted by folder name.
    /// Invalid folders are skipped (and logged) so one broken pack never
    /// hides the rest.
    public static func availablePacks(in directory: URL) -> [Pack] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in
                do {
                    return try load(at: folder)
                } catch {
                    ChariotLog.log("skipping pack \(folder.lastPathComponent): \(error)")
                    return nil
                }
            }
    }
}
