import XCTest
@testable import ChariotCore

/// First-run base image install. The network fetch is not exercised here; what
/// matters is that a corrupt or unexpected archive can never become the image
/// every agent VM clones, and that status reporting drives the setup gate
/// correctly.
final class BaseImageInstallerTests: XCTestCase {
    var directory: URL!
    var imagePath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        imagePath = directory.appendingPathComponent("base-image.raw").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func release(url: String = "https://example.invalid/image.tar.xz",
                         sha256: String = String(repeating: "a", count: 64),
                         expandedBytes: Int64 = 64) -> BaseImageRelease {
        BaseImageRelease(version: "test-1", url: URL(string: url)!, sha256: sha256,
                         compressedBytes: 32, expandedBytes: expandedBytes)
    }

    // MARK: Status

    func testMissingImageBlocksStartup() {
        let installer = BaseImageInstaller(imagePath: imagePath, release: release())
        XCTAssertEqual(installer.status(), .missing)
        XCTAssertFalse(installer.isReady)
    }

    /// A hand-placed image (dev checkouts, CHARIOT_BASE_IMAGE) has no marker.
    /// It must count as ready — re-downloading over a working image would be
    /// both slow and wrong.
    func testUnmanagedImageCountsAsReady() throws {
        try Data("not really an image".utf8).write(to: URL(fileURLWithPath: imagePath))
        let installer = BaseImageInstaller(imagePath: imagePath, release: release())
        XCTAssertEqual(installer.status(), .ready(version: "unmanaged"))
        XCTAssertTrue(installer.isReady)
    }

    func testMarkerFromAnotherBuildReportsOutdated() throws {
        try Data("image".utf8).write(to: URL(fileURLWithPath: imagePath))
        let marker = """
        {"version":"old-build","sha256":"deadbeef","installedAt":"2026-01-01T00:00:00Z"}
        """
        try Data(marker.utf8).write(to: directory.appendingPathComponent("base-image.json"))

        let installer = BaseImageInstaller(imagePath: imagePath, release: release())
        XCTAssertEqual(installer.status(), .outdated(installed: "old-build", expected: "test-1"))
        // Still usable: an outdated image boots, so the app must not block on it.
        XCTAssertTrue(installer.isReady)
    }

    func testMatchingMarkerReportsReady() throws {
        try Data("image".utf8).write(to: URL(fileURLWithPath: imagePath))
        let marker = """
        {"version":"test-1","sha256":"abc","installedAt":"2026-01-01T00:00:00Z"}
        """
        try Data(marker.utf8).write(to: directory.appendingPathComponent("base-image.json"))

        let installer = BaseImageInstaller(imagePath: imagePath, release: release())
        XCTAssertEqual(installer.status(), .ready(version: "test-1"))
    }

    // MARK: Integrity

    func testSHA256MatchesKnownVector() throws {
        let file = directory.appendingPathComponent("vector")
        try Data("abc".utf8).write(to: file)
        // Standard SHA-256("abc").
        XCTAssertEqual(try BaseImageInstaller.sha256(ofFileAt: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The digest is what stands between a corrupted or substituted download
    /// and a VM image. A staged archive that fails it must be discarded rather
    /// than reused, or one bad download would poison every later retry.
    func testCorruptStagedArchiveIsDiscarded() throws {
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let staged = downloads.appendingPathComponent("base-image-test-1.tar.xz")
        try Data("corrupt".utf8).write(to: staged)

        let installer = BaseImageInstaller(imagePath: imagePath, release: release())
        XCTAssertFalse(try installer.verifiedTarballExists(at: staged, progress: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    /// The matching case: a good archive is kept, so a retry that failed during
    /// expansion does not re-download 198 MB.
    func testVerifiedStagedArchiveIsReused() throws {
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let staged = downloads.appendingPathComponent("base-image-test-1.tar.xz")
        try Data("good".utf8).write(to: staged)
        let digest = try BaseImageInstaller.sha256(ofFileAt: staged)

        let installer = BaseImageInstaller(imagePath: imagePath, release: release(sha256: digest))
        XCTAssertTrue(try installer.verifiedTarballExists(at: staged, progress: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    /// A verified archive that unpacks to something other than a single
    /// `disk.raw` must not be installed.
    func testArchiveWithoutDiskRawIsRejected() async throws {
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        // Build a real .tar.xz whose member is deliberately misnamed.
        let staging = directory.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: staging.appendingPathComponent("wrong.raw"))

        let archive = downloads.appendingPathComponent("base-image-test-1.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", staging.path, "wrong.raw"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let digest = try BaseImageInstaller.sha256(ofFileAt: archive)
        let installer = BaseImageInstaller(imagePath: imagePath, release: release(sha256: digest))

        do {
            try await installer.install { _ in }
            XCTFail("install should reject an archive with no disk.raw")
        } catch BaseImageError.unexpectedArchiveContents {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
    }

    /// The happy path, minus the network: a verified archive containing a
    /// correctly sized disk.raw installs and records its version.
    func testVerifiedArchiveInstallsAndRecordsVersion() async throws {
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64).write(to: staging.appendingPathComponent("disk.raw"))

        let archive = downloads.appendingPathComponent("base-image-test-1.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", staging.path, "disk.raw"]
        try tar.run()
        tar.waitUntilExit()

        let digest = try BaseImageInstaller.sha256(ofFileAt: archive)
        let installer = BaseImageInstaller(imagePath: imagePath,
                                           release: release(sha256: digest, expandedBytes: 64))

        var phases: [BaseImageProgress] = []
        try await installer.install { phases.append($0) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: imagePath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imagePath)),
                       Data(repeating: 7, count: 64))
        XCTAssertEqual(installer.status(), .ready(version: "test-1"))
        XCTAssertTrue(phases.contains(.expanding))
        XCTAssertTrue(phases.contains(.installed))
        // Scratch space is reclaimed once the image is in place.
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
    }

    /// A wrong-sized disk.raw means the mirror does not match what this build
    /// pins; installing it anyway would boot an unknown guest.
    func testWrongSizedImageIsRejected() async throws {
        let downloads = directory.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: staging.appendingPathComponent("disk.raw"))

        let archive = downloads.appendingPathComponent("base-image-test-1.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", staging.path, "disk.raw"]
        try tar.run()
        tar.waitUntilExit()

        let digest = try BaseImageInstaller.sha256(ofFileAt: archive)
        let installer = BaseImageInstaller(imagePath: imagePath,
                                           release: release(sha256: digest, expandedBytes: 4096))
        do {
            try await installer.install { _ in }
            XCTFail("install should reject a disk.raw of unexpected size")
        } catch BaseImageError.unexpectedArchiveContents {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imagePath))
    }
}
