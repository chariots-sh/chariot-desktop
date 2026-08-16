import Foundation

public typealias SandboxID = String

public struct SandboxConfiguration: Codable, Sendable {
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var baseImagePath: String

    public init(cpuCount: Int = 2,
                memoryBytes: UInt64 = 2 * 1024 * 1024 * 1024,
                diskBytes: UInt64 = 8 * 1024 * 1024 * 1024,
                baseImagePath: String) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        self.baseImagePath = baseImagePath
    }
}

public enum SandboxState: String, Codable, Sendable {
    case notCreated = "not-created"
    case stopped
    case starting
    case running
    case stopping
    case failed
}

/// Design §5.3 — the backend abstraction over Virtualization.framework.
public protocol SandboxBackend {
    func create(configuration: SandboxConfiguration) async throws -> SandboxID
    func start(_ id: SandboxID) async throws
    func stop(_ id: SandboxID) async throws
    func restart(_ id: SandboxID) async throws
    func reset(_ id: SandboxID) async throws
    func destroy(_ id: SandboxID) async throws
    func importArtifact(_ source: URL, into id: SandboxID) async throws
    func exportArtifact(_ path: String, from id: SandboxID) async throws -> URL
}

public enum ChariotError: Error, CustomStringConvertible {
    case instanceNotFound(SandboxID)
    case invalidState(String)
    case bridgeUnavailable(String)
    case vmFailure(String)
    case pairingFailure(String)
    case notPaired
    case io(String)

    public var description: String {
        switch self {
        case .instanceNotFound(let id): return "instance not found: \(id)"
        case .invalidState(let s): return "invalid state: \(s)"
        case .bridgeUnavailable(let s): return "bridge unavailable: \(s)"
        case .vmFailure(let s): return "vm failure: \(s)"
        case .pairingFailure(let s): return "pairing failure: \(s)"
        case .notPaired: return "no paired device"
        case .io(let s): return "io error: \(s)"
        }
    }
}

public enum ChariotLog {
    nonisolated(unsafe) public static var sink: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data(("[chariot] " + line + "\n").utf8))
    }

    public static func log(_ message: String) {
        sink(message)
    }
}
