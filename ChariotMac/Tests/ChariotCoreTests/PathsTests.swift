import XCTest
@testable import ChariotCore

final class PathsTests: XCTestCase {

    func testEnsureDirectoriesCreatesLayout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ChariotPaths(dataDirectory: root, guestResources: root)
        try paths.ensureDirectories()

        var isDirectory: ObjCBool = false
        for dir in [paths.identityDirectory, paths.instancesDirectory, paths.mailboxDirectory] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
        }
        // Idempotent: a second call must not throw on existing directories.
        XCTAssertNoThrow(try paths.ensureDirectories())
    }

    func testInstanceDirectoryLayout() {
        let root = URL(fileURLWithPath: "/data")
        let paths = ChariotPaths(dataDirectory: root, guestResources: root)
        let dir = paths.instanceDirectory("sandbox-1")
        XCTAssertEqual(dir.path, "/data/instances/sandbox-1")

        let instance = InstancePaths(directory: dir)
        XCTAssertEqual(instance.writableDisk.lastPathComponent, "writable.img")
        XCTAssertEqual(instance.seedISO.lastPathComponent, "seed.iso")
        XCTAssertEqual(instance.configuration.lastPathComponent, "configuration.json")
        XCTAssertEqual(instance.accessKey.lastPathComponent, "access-key")
        XCTAssertEqual(instance.accessKeyPublic.lastPathComponent, "access-key.pub")
        // Every artifact lives inside the instance directory.
        for url in [instance.writableDisk, instance.seedISO, instance.efiVariableStore,
                    instance.machineIdentifier, instance.configuration, instance.consoleLog,
                    instance.accessKey, instance.accessKeyPublic, instance.sshConfig,
                    instance.knownHosts] {
            XCTAssertTrue(url.path.hasPrefix(dir.path + "/"))
        }
    }
}
