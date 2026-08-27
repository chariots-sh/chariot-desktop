import XCTest
@testable import ChariotCore

/// Pack format v1: manifest parsing/validation, workspace expansion,
/// /workspace confinement, seed-only flags, and checksum edit detection.
final class PackLoaderTests: XCTestCase {
    var packsDir: URL!

    override func setUpWithError() throws {
        packsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-packs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: packsDir)
    }

    @discardableResult
    func writePack(_ folder: String, manifest: String, files: [String: String] = [:],
                   executables: Set<String> = []) throws -> URL {
        let dir = packsDir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            if executables.contains(path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        return dir
    }

    let guardianManifest = """
    {
      "id": "com.protocols.guardian",
      "name": "Guardian",
      "version": "1.0.0",
      "vm": { "cpus": 3, "memoryMB": 3072, "diskGB": 12 },
      "workspace": [
        { "src": "AGENTS.md", "dest": "/workspace/AGENTS.md" },
        { "src": "MEMORY.seed.md", "dest": "/workspace/MEMORY.md", "seedOnly": true },
        { "src": "tools", "dest": "/workspace/tools" }
      ],
      "data": { "providers": ["healthkit"] }
    }
    """

    func testLoadParsesManifestAndIgnoresReservedDataField() throws {
        let dir = try writePack("guardian.pack", manifest: guardianManifest, files: [
            "AGENTS.md": "# Guardian",
            "MEMORY.seed.md": "seed",
            "tools/checkin.sh": "#!/bin/bash\necho ok\n"
        ], executables: ["tools/checkin.sh"])

        let pack = try PackLoader.load(at: dir)
        XCTAssertEqual(pack.manifest.id, "com.protocols.guardian")
        XCTAssertEqual(pack.manifest.name, "Guardian")
        XCTAssertEqual(pack.directoryName, "guardian.pack")
        // The Milestone 2 "data" field must not break a v1 loader.
        XCTAssertEqual(pack.manifest.workspace.count, 3)
    }

    func testVMSizingAppliedToConfiguration() throws {
        let dir = try writePack("guardian.pack", manifest: guardianManifest, files: [
            "AGENTS.md": "x", "MEMORY.seed.md": "x", "tools/checkin.sh": "x"
        ])
        let pack = try PackLoader.load(at: dir)
        let configuration = pack.configuration(baseImagePath: "/tmp/base.raw")
        XCTAssertEqual(configuration.cpuCount, 3)
        XCTAssertEqual(configuration.memoryBytes, 3072 * 1024 * 1024)
        XCTAssertEqual(configuration.diskBytes, 12 * 1024 * 1024 * 1024)
        XCTAssertEqual(configuration.baseImagePath, "/tmp/base.raw")
    }

    func testDefaultSizingWhenVMOmitted() throws {
        let dir = try writePack("mini.pack", manifest: """
        { "id": "m", "name": "Mini", "version": "1", "workspace": [] }
        """)
        let pack = try PackLoader.load(at: dir)
        let configuration = pack.configuration(baseImagePath: "/tmp/base.raw")
        XCTAssertEqual(configuration.cpuCount, SandboxConfiguration(baseImagePath: "").cpuCount)
        XCTAssertEqual(configuration.memoryBytes, SandboxConfiguration(baseImagePath: "").memoryBytes)
    }

    func testWorkspaceExpansionDirectoriesSeedFlagsAndExecutableBit() throws {
        let dir = try writePack("guardian.pack", manifest: guardianManifest, files: [
            "AGENTS.md": "# Guardian",
            "MEMORY.seed.md": "seed",
            "tools/checkin.sh": "#!/bin/bash\necho ok\n",
            "tools/lib/util.py": "print('x')"
        ], executables: ["tools/checkin.sh"])

        let files = try PackLoader.load(at: dir).workspaceFiles()
        XCTAssertEqual(files.map(\.destination), [
            "/workspace/AGENTS.md",
            "/workspace/MEMORY.md",
            "/workspace/tools/checkin.sh",
            "/workspace/tools/lib/util.py"
        ])
        let byDest = Dictionary(uniqueKeysWithValues: files.map { ($0.destination, $0) })
        XCTAssertEqual(byDest["/workspace/MEMORY.md"]?.seedOnly, true)
        XCTAssertEqual(byDest["/workspace/AGENTS.md"]?.seedOnly, false)
        XCTAssertEqual(byDest["/workspace/tools/checkin.sh"]?.executable, true)
        XCTAssertEqual(byDest["/workspace/tools/lib/util.py"]?.executable, false)
    }

    func testChecksumsDetectEdits() throws {
        let dir = try writePack("guardian.pack", manifest: guardianManifest, files: [
            "AGENTS.md": "v1", "MEMORY.seed.md": "seed", "tools/checkin.sh": "echo"
        ])
        let pack = try PackLoader.load(at: dir)
        let before = try pack.checksums()
        try "v2 — edited persona".write(to: dir.appendingPathComponent("AGENTS.md"),
                                        atomically: true, encoding: .utf8)
        let after = try pack.checksums()
        XCTAssertNotEqual(before["/workspace/AGENTS.md"], after["/workspace/AGENTS.md"])
        XCTAssertEqual(before["/workspace/MEMORY.md"], after["/workspace/MEMORY.md"])
        XCTAssertEqual(before.count, after.count)
    }

    func testRejectsDestOutsideWorkspace() throws {
        for badDest in ["/etc/passwd", "/workspace/../etc/passwd", "workspace/AGENTS.md", "/workspaceX/a"] {
            let dir = try writePack("bad-\(badDest.hashValue).pack", manifest: """
            { "id": "b", "name": "Bad", "version": "1",
              "workspace": [ { "src": "AGENTS.md", "dest": "\(badDest)" } ] }
            """, files: ["AGENTS.md": "x"])
            XCTAssertThrowsError(try PackLoader.load(at: dir), badDest) { error in
                guard case PackError.invalidEntry = error else {
                    return XCTFail("expected invalidEntry for \(badDest), got \(error)")
                }
            }
        }
    }

    func testRejectsSrcTraversalAndAbsoluteSrc() throws {
        for badSrc in ["../outside.md", "/etc/passwd"] {
            let dir = try writePack("srcbad-\(badSrc.hashValue).pack", manifest: """
            { "id": "b", "name": "Bad", "version": "1",
              "workspace": [ { "src": "\(badSrc)", "dest": "/workspace/x" } ] }
            """)
            XCTAssertThrowsError(try PackLoader.load(at: dir), badSrc) { error in
                guard case PackError.invalidEntry = error else {
                    return XCTFail("expected invalidEntry for \(badSrc), got \(error)")
                }
            }
        }
    }

    func testMissingSourceAndMissingManifest() throws {
        let dir = try writePack("nosrc.pack", manifest: """
        { "id": "n", "name": "N", "version": "1",
          "workspace": [ { "src": "GHOST.md", "dest": "/workspace/GHOST.md" } ] }
        """)
        XCTAssertThrowsError(try PackLoader.load(at: dir)) { error in
            guard case PackError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }

        let empty = packsDir.appendingPathComponent("empty.pack")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PackLoader.load(at: empty)) { error in
            guard case PackError.manifestMissing = error else {
                return XCTFail("expected manifestMissing, got \(error)")
            }
        }
    }

    func testAvailablePacksSkipsInvalidAndSortsByFolder() throws {
        try writePack("b-scribe.pack", manifest: """
        { "id": "s", "name": "Scribe", "version": "1", "workspace": [] }
        """)
        try writePack("a-guardian.pack", manifest: guardianManifest, files: [
            "AGENTS.md": "x", "MEMORY.seed.md": "x", "tools/checkin.sh": "x"
        ])
        try writePack("broken.pack", manifest: "{ not json")

        let packs = PackLoader.availablePacks(in: packsDir)
        XCTAssertEqual(packs.map(\.directoryName), ["a-guardian.pack", "b-scribe.pack"])
    }

    // MARK: In-app pack creation
    //
    // The GUI's "New Pack" sheet calls createPack; whatever it writes must
    // round-trip through the same loader that New Agent uses.

    func testCreatePackScaffoldsAValidLoadablePack() throws {
        let pack = try PackLoader.createPack(named: "My Health Coach!",
                                             instructions: "# Coach\n\nYou are a coach.",
                                             soul: "Warm but direct.",
                                             seedMemory: "## Notes\n- (empty)",
                                             in: packsDir)
        XCTAssertEqual(pack.directoryName, "my-health-coach.pack")
        XCTAssertEqual(pack.manifest.id, "local.my-health-coach")
        XCTAssertEqual(pack.manifest.name, "My Health Coach!")
        XCTAssertEqual(pack.manifest.version, "1.0.0")

        let files = try pack.workspaceFiles()
        XCTAssertEqual(files.map(\.destination),
                       ["/workspace/AGENTS.md", "/workspace/MEMORY.md", "/workspace/SOUL.md"])
        let byDest = Dictionary(uniqueKeysWithValues: files.map { ($0.destination, $0) })
        XCTAssertEqual(byDest["/workspace/MEMORY.md"]?.seedOnly, true)
        XCTAssertEqual(byDest["/workspace/AGENTS.md"]?.seedOnly, false)

        // And it shows up where the create sheet looks.
        XCTAssertEqual(PackLoader.availablePacks(in: packsDir).map(\.directoryName),
                       ["my-health-coach.pack"])
    }

    func testCreatePackOmitsEmptyOptionalFiles() throws {
        let pack = try PackLoader.createPack(named: "Mini",
                                             instructions: "Do things.",
                                             soul: "   ",
                                             seedMemory: nil,
                                             in: packsDir)
        XCTAssertEqual(try pack.workspaceFiles().map(\.destination), ["/workspace/AGENTS.md"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pack.directory.appendingPathComponent("SOUL.md").path))
    }

    func testCreatePackNameCollisionGetsSuffixNotFailure() throws {
        let first = try PackLoader.createPack(named: "Twin", instructions: "a", in: packsDir)
        let second = try PackLoader.createPack(named: "twin", instructions: "b", in: packsDir)
        XCTAssertEqual(first.directoryName, "twin.pack")
        XCTAssertEqual(second.directoryName, "twin-2.pack")
    }

    func testCreatePackRejectsBlankNameOrInstructions() {
        XCTAssertThrowsError(try PackLoader.createPack(named: "  ",
                                                       instructions: "x", in: packsDir))
        XCTAssertThrowsError(try PackLoader.createPack(named: "OK",
                                                       instructions: "\n  \n", in: packsDir))
        XCTAssertEqual(PackLoader.availablePacks(in: packsDir).count, 0)
    }

    func testSlugFallsBackWhenNameHasNoSafeCharacters() throws {
        XCTAssertEqual(PackLoader.slug(from: "Crème Brûlée 9"), "creme-brulee-9")
        XCTAssertEqual(PackLoader.slug(from: "!!!"), "agent")
        let pack = try PackLoader.createPack(named: "日本語", instructions: "x", in: packsDir)
        XCTAssertEqual(pack.directoryName, "agent.pack")
    }

    // MARK: Seeding bundled packs
    //
    // A downloaded app starts with an empty packs directory; without seeding,
    // New Agent has nothing to offer and the app is unusable out of the box.

    /// The bundled packs stand in for Contents/Resources/packs.
    private func makeBundledPacks() throws -> URL {
        let bundled = packsDir.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for name in ["guardian.pack", "scribe.pack"] {
            let dir = bundled.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{ "id": "\#(name)", "name": "\#(name)", "version": "1", "workspace": [] }"#
                .write(to: dir.appendingPathComponent("pack.json"), atomically: true, encoding: .utf8)
            try "bundled".write(to: dir.appendingPathComponent("AGENTS.md"),
                                atomically: true, encoding: .utf8)
        }
        return bundled
    }

    func testSeedingPopulatesAnEmptyPacksDirectory() throws {
        let bundled = try makeBundledPacks()
        let destination = packsDir.appendingPathComponent("data-packs")

        let seeded = PackLoader.seedBundledPacks(from: bundled, into: destination)

        XCTAssertEqual(seeded.sorted(), ["guardian.pack", "scribe.pack"])
        XCTAssertEqual(PackLoader.availablePacks(in: destination).map(\.directoryName),
                       ["guardian.pack", "scribe.pack"])
    }

    /// Packs are user-editable — an edit lands on the agent's next turn — so a
    /// pack already on disk must never be replaced by the bundled copy.
    func testSeedingNeverOverwritesAnEditedPack() throws {
        let bundled = try makeBundledPacks()
        let destination = packsDir.appendingPathComponent("data-packs")
        PackLoader.seedBundledPacks(from: bundled, into: destination)

        let edited = destination.appendingPathComponent("guardian.pack/AGENTS.md")
        try "user's own persona".write(to: edited, atomically: true, encoding: .utf8)

        let seeded = PackLoader.seedBundledPacks(from: bundled, into: destination)

        XCTAssertTrue(seeded.isEmpty, "a second launch must not re-seed")
        XCTAssertEqual(try String(contentsOf: edited, encoding: .utf8), "user's own persona")
    }

    /// Only .pack folders are copied; anything else in Resources stays put.
    func testSeedingIgnoresNonPackEntries() throws {
        let bundled = try makeBundledPacks()
        try "not a pack".write(to: bundled.appendingPathComponent("README.md"),
                               atomically: true, encoding: .utf8)
        let destination = packsDir.appendingPathComponent("data-packs")

        let seeded = PackLoader.seedBundledPacks(from: bundled, into: destination)

        XCTAssertEqual(seeded.sorted(), ["guardian.pack", "scribe.pack"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("README.md").path))
    }

    /// A missing bundle directory (dev builds run from the build tree) is not
    /// an error — the app still starts, just without samples.
    /// The packs shipped in the repo must always load — a broken pack.json
    /// or a workspace entry pointing at a missing folder would otherwise
    /// surface only when a user creates an agent from it.
    func testShippedRepoPacksLoad() throws {
        let repoPacks = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChariotCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ChariotMac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("packs")
        let packs = PackLoader.availablePacks(in: repoPacks)
        XCTAssertEqual(packs.map(\.directoryName), ["guardian.pack", "scribe.pack"])

        // Guardian ships the mitochondria simulator: the vendored engine
        // lands under /workspace/sim and its wrapper stays executable.
        let guardian = try XCTUnwrap(packs.first { $0.directoryName == "guardian.pack" })
        let files = try guardian.workspaceFiles()
        XCTAssertTrue(files.contains { $0.destination == "/workspace/sim/mitosim/cli.py" })
        XCTAssertTrue(files.contains { $0.destination == "/workspace/sim/examples/runner.json" })
        let wrapper = try XCTUnwrap(files.first { $0.destination == "/workspace/tools/mitosim.sh" })
        XCTAssertTrue(wrapper.executable)
    }

    func testSeedingFromMissingDirectoryIsHarmless() {
        let destination = packsDir.appendingPathComponent("data-packs")
        let seeded = PackLoader.seedBundledPacks(
            from: packsDir.appendingPathComponent("does-not-exist"), into: destination)
        XCTAssertTrue(seeded.isEmpty)
    }
}
