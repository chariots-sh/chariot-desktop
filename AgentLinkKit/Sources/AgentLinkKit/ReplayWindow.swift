import Foundation

/// Bounded per-sender replay protection (design §7, §13.10).
/// Tracks seen message IDs and enforces a sliding sequence window.
public struct ReplayWindow: Codable, Equatable, Sendable {
    public private(set) var highestSequence: UInt64
    public private(set) var seenMessageIDs: [String]
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.highestSequence = 0
        self.seenMessageIDs = []
        self.capacity = capacity
    }

    /// Validates and records a message. Throws on replays; tolerates reordering
    /// within the window.
    public mutating func accept(messageID: String, sequence: UInt64) throws {
        if seenMessageIDs.contains(messageID) { throw AgentLinkError.replayDetected }
        if sequence + UInt64(capacity) <= highestSequence {
            // Too far behind the window to distinguish from a replay.
            throw AgentLinkError.sequenceRegression
        }
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > capacity {
            seenMessageIDs.removeFirst(seenMessageIDs.count - capacity)
        }
        if sequence > highestSequence { highestSequence = sequence }
    }
}

/// Monotonic outbound sequence allocator.
public struct SequenceAllocator: Codable, Equatable, Sendable {
    public private(set) var lastAssigned: UInt64

    public init(lastAssigned: UInt64 = 0) {
        self.lastAssigned = lastAssigned
    }

    public mutating func next() -> UInt64 {
        lastAssigned += 1
        return lastAssigned
    }
}
