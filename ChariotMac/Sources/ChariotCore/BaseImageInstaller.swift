import Foundation
import CryptoKit

/// The guest base image the app expects, pinned by content hash.
///
/// Chariot mirrors Debian's `genericcloud` tarball as a release asset rather
/// than fetching from cloud.debian.org directly: Debian keeps only about three
/// dated builds online and prunes the rest, so a pinned upstream URL 404s
/// within weeks, and `latest/` silently changes bytes underneath us. The mirror
/// is permanent and the digest below names exactly one image.
///
/// The download is the 198 MB `.tar.xz`, not the 3 GB `.raw` — same image,
/// 15x less to transfer. It expands to a 3 GiB sparse file that occupies
/// roughly 1.3 GB on disk.
public struct BaseImageRelease: Sendable, Equatable {
    /// Debian's build stamp, e.g. "20260806-2562". Also the marker version.
    public let version: String
    public let url: URL
    /// SHA-256 of the compressed tarball, verified before expanding.
    public let sha256: String
    public let compressedBytes: Int64
    /// Apparent size of the expanded `disk.raw`; a mismatch fails the install.
    public let expandedBytes: Int64

    public init(version: String, url: URL, sha256: String,
                compressedBytes: Int64, expandedBytes: Int64) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.compressedBytes = compressedBytes
        self.expandedBytes = expandedBytes
    }

    /// Debian 12 (bookworm) genericcloud arm64, build 20260806-2562.
    ///
    /// To bump: run `scripts/mirror-base-image.sh`, which downloads the new
    /// upstream tarball, prints these five values, and uploads the asset.
    public static let pinned = BaseImageRelease(
        version: "20260806-2562",
        url: URL(string: "https://github.com/chariots-sh/chariot-desktop/releases/download/base-image-20260806-2562/debian-12-genericcloud-arm64.tar.xz")!,
        sha256: "04e0a49122b03c44bbdc584a1876d898e58d38d06d2e73012687013b5702f8ba",
        compressedBytes: 207_899_804,
        expandedBytes: 3_221_225_472)

    /// Dev override: point at a local mirror or an unreleased image without
    /// rebuilding. Both variables must be set together — a URL with a stale
    /// digest would fail verification, which is the safe direction.
    public static var current: BaseImageRelease {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["CHARIOT_BASE_IMAGE_URL"],
              let url = URL(string: urlString),
              let sha = env["CHARIOT_BASE_IMAGE_SHA256"] else { return pinned }
        return BaseImageRelease(
            version: env["CHARIOT_BASE_IMAGE_VERSION"] ?? "override",
            url: url,
            sha256: sha.lowercased(),
            compressedBytes: Int64(env["CHARIOT_BASE_IMAGE_BYTES"] ?? "") ?? pinned.compressedBytes,
            expandedBytes: Int64(env["CHARIOT_BASE_IMAGE_EXPANDED_BYTES"] ?? "") ?? pinned.expandedBytes)
    }
}

/// What the installer is doing, for the first-run UI.
public enum BaseImageProgress: Sendable, Equatable {
    case downloading(received: Int64, total: Int64)
    case verifying
    case expanding
    case installed
}

public enum BaseImageStatus: Sendable, Equatable {
    case missing
    case ready(version: String)
    /// Present, but built from a different image than this app pins.
    case outdated(installed: String, expected: String)
}

public enum BaseImageError: Error, CustomStringConvertible {
    case httpStatus(Int)
    case digestMismatch(expected: String, actual: String)
    case expansionFailed(String)
    case unexpectedArchiveContents(String)
    case insufficientSpace(needed: Int64, available: Int64)

    public var description: String {
        switch self {
        case .httpStatus(let code):
            return "image download failed with HTTP \(code)"
        case .digestMismatch(let expected, let actual):
            return "image digest mismatch — expected \(expected), got \(actual)"
        case .expansionFailed(let detail):
            return "could not expand the image archive: \(detail)"
        case .unexpectedArchiveContents(let detail):
            return "unexpected archive contents: \(detail)"
        case .insufficientSpace(let needed, let available):
            let fmt = ByteCountFormatter.string(fromByteCount:countStyle:)
            return "not enough disk space — needs \(fmt(needed, .file)), \(fmt(available, .file)) free"
        }
    }
}

/// Downloads, verifies, and installs the guest base image.
///
/// Chariot is unusable without it — every agent VM clones this file — so the
/// GUI blocks on a successful install at first run rather than surfacing the
/// absence later as a VM boot failure.
public final class BaseImageInstaller: @unchecked Sendable {
    private let release: BaseImageRelease
    private let imageURL: URL
    private let markerURL: URL
    private let downloadsDirectory: URL

    /// - Parameter imagePath: final resting place of the expanded `base-image.raw`.
    public init(imagePath: String, release: BaseImageRelease = .current) {
        self.release = release
        self.imageURL = URL(fileURLWithPath: imagePath)
        self.markerURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent("base-image.json")
        self.downloadsDirectory = imageURL.deletingLastPathComponent()
            .appendingPathComponent("downloads")
    }

    public var expectedVersion: String { release.version }
    public var downloadBytes: Int64 { release.compressedBytes }

    // MARK: Status

    private struct Marker: Codable {
        var version: String
        var sha256: String
        var installedAt: Date
    }

    public func status() -> BaseImageStatus {
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder.chariot.decode(Marker.self, from: data) else {
            // An image placed by hand (dev checkouts, CHARIOT_BASE_IMAGE) has no
            // marker. Treat it as ready: it boots, and re-downloading 200 MB
            // over a working image would be hostile.
            return .ready(version: "unmanaged")
        }
        return marker.version == release.version
            ? .ready(version: marker.version)
            : .outdated(installed: marker.version, expected: release.version)
    }

    public var isReady: Bool {
        if case .missing = status() { return false }
        return true
    }

    // MARK: Install

    /// Downloads and installs the image, replacing any existing one.
    ///
    /// Safe to call again after a failure: a verified tarball is kept in the
    /// downloads directory, so a retry that fails during expansion does not
    /// re-download.
    public func install(progress: @escaping @Sendable (BaseImageProgress) -> Void) async throws {
        try FileManager.default.createDirectory(at: downloadsDirectory,
                                                withIntermediateDirectories: true)
        try checkFreeSpace()

        let tarball = downloadsDirectory
            .appendingPathComponent("base-image-\(release.version).tar.xz")

        if try !verifiedTarballExists(at: tarball, progress: progress) {
            try await download(to: tarball, progress: progress)
            progress(.verifying)
            let digest = try Self.sha256(ofFileAt: tarball)
            guard digest == release.sha256.lowercased() else {
                // Never leave an unverified archive to be picked up by a retry.
                try? FileManager.default.removeItem(at: tarball)
                throw BaseImageError.digestMismatch(expected: release.sha256, actual: digest)
            }
        }

        progress(.expanding)
        try expand(tarball: tarball)
        try writeMarker()
        try? FileManager.default.removeItem(at: downloadsDirectory)
        progress(.installed)
    }

    /// A previously verified tarball short-circuits the download on retry.
    /// Anything that fails verification is deleted, so a bad archive can never
    /// be picked up by a later attempt.
    func verifiedTarballExists(at tarball: URL,
                                       progress: @escaping @Sendable (BaseImageProgress) -> Void) throws -> Bool {
        guard FileManager.default.fileExists(atPath: tarball.path) else { return false }
        progress(.verifying)
        guard let digest = try? Self.sha256(ofFileAt: tarball), digest == release.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: tarball)
            return false
        }
        return true
    }

    private func checkFreeSpace() throws {
        let directory = imageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Tarball plus the expanded image; the raw file is sparse, so this is a
        // deliberate over-estimate rather than a tight bound.
        let needed = release.compressedBytes + release.expandedBytes / 2
        guard available >= needed else {
            throw BaseImageError.insufficientSpace(needed: needed, available: available)
        }
    }

    // MARK: Download

    private func download(to destination: URL,
                          progress: @escaping @Sendable (BaseImageProgress) -> Void) async throws {
        let delegate = DownloadProgressDelegate(total: release.compressedBytes, progress: progress)
        let configuration = URLSessionConfiguration.default
        // Fail fast when there is no route at all: an offline user should get
        // "you are offline" on the setup screen, not an indefinite spinner.
        // Transient drops mid-transfer are handled by the resume loop below.
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var resumeData: Data?
        var lastError: Error?
        // Retries cover the common case — a transient drop mid-transfer —
        // by resuming rather than restarting a 198 MB download.
        for attempt in 0..<4 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
            }
            do {
                let temporary: URL
                if let data = resumeData {
                    temporary = try await session.chariot_download(resumeFrom: data)
                } else {
                    temporary = try await session.chariot_download(from: release.url)
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                return
            } catch {
                lastError = error
                if Task.isCancelled { throw error }
                let nsError = error as NSError
                resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                // A 4xx/5xx is not worth retrying; a transport error is.
                if let imageError = error as? BaseImageError,
                   case .httpStatus = imageError { throw error }
            }
        }
        throw lastError ?? BaseImageError.httpStatus(0)
    }

    // MARK: Expand

    private func expand(tarball: URL) throws {
        let staging = downloadsDirectory.appendingPathComponent("expand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // macOS tar is libarchive: it reads xz natively and writes the result
        // sparsely, so the 3 GiB image lands as ~1.3 GB of blocks.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xJf", tarball.path, "-C", staging.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "tar exited \(process.terminationStatus)"
            throw BaseImageError.expansionFailed(detail)
        }

        let expanded = staging.appendingPathComponent("disk.raw")
        guard FileManager.default.fileExists(atPath: expanded.path) else {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
            throw BaseImageError.unexpectedArchiveContents(
                "expected disk.raw, found \(found.isEmpty ? "nothing" : found.joined(separator: ", "))")
        }
        let size = (try? expanded.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        if let size, size != release.expandedBytes {
            throw BaseImageError.unexpectedArchiveContents(
                "disk.raw is \(size) bytes, expected \(release.expandedBytes)")
        }

        // Move into place only once the image is known good, so an interrupted
        // install never leaves a truncated base image that VMs would clone.
        if FileManager.default.fileExists(atPath: imageURL.path) {
            _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: expanded)
        } else {
            try FileManager.default.moveItem(at: expanded, to: imageURL)
        }
    }

    private func writeMarker() throws {
        let marker = Marker(version: release.version, sha256: release.sha256, installedAt: Date())
        try JSONEncoder.chariot.encode(marker).write(to: markerURL, options: .atomic)
    }

    // MARK: Hashing

    /// Streams the file so a 198 MB archive never lands in memory whole.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSession plumbing

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let total: Int64
    private let progress: @Sendable (BaseImageProgress) -> Void

    init(total: Int64, progress: @escaping @Sendable (BaseImageProgress) -> Void) {
        self.total = total
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // The server's length is authoritative when known; the pinned size is
        // the fallback so a resumed transfer still shows a sane denominator.
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : total
        progress(.downloading(received: totalBytesWritten, total: expected))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Handled by the continuation in chariot_download; URLSession deletes
        // `location` when this returns, so the move happens there.
    }
}

private extension URLSession {
    /// `download(from:)` and `download(resumeFrom:)` exist on macOS 12+, but
    /// neither surfaces a non-2xx as an error, and both discard the delegate's
    /// progress on the shared session. This wraps them with status checking.
    func chariot_download(from url: URL) async throws -> URL {
        let (location, response) = try await download(from: url)
        try Self.check(response, cleaningUp: location)
        return try Self.preserve(location)
    }

    func chariot_download(resumeFrom data: Data) async throws -> URL {
        let (location, response) = try await download(resumeFrom: data)
        try Self.check(response, cleaningUp: location)
        return try Self.preserve(location)
    }

    private static func check(_ response: URLResponse, cleaningUp location: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: location)
            throw BaseImageError.httpStatus(http.statusCode)
        }
    }

    /// URLSession removes the temporary file as soon as the call returns.
    private static func preserve(_ location: URL) throws -> URL {
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("chariot-image-\(UUID().uuidString).tar.xz")
        try FileManager.default.moveItem(at: location, to: kept)
        return kept
    }
}

extension JSONEncoder {
    static var chariot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var chariot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
