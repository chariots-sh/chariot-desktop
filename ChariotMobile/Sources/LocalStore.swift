import Foundation
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

struct OutboxItem: Codable {
    let messageID: String
    let text: String
    let createdAt: Date
}

/// Sample persistence: JSON files in Application Support. Production stores the
/// private identity in the iOS Keychain (design §13.8) and operational state in
/// SwiftData/SQLite; the file layout here keeps the sample dependency-free.
final class LocalStore {
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("ChariotMobile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func write<T: Encodable>(_ value: T, to name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value) {
            try? data.write(to: url(name), options: .atomic)
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? CanonicalCoding.decoder().decode(type, from: data)
    }

    // Identity

    func loadIdentity() -> DeviceIdentity? {
        guard let stored = read(DeviceIdentity.Stored.self, from: "identity.json") else { return nil }
        return try? DeviceIdentity(stored: stored)
    }

    func saveIdentity(_ identity: DeviceIdentity) {
        write(identity.stored(), to: "identity.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url("identity.json").path)
    }

    // Connection

    func loadConnection() -> ConnectionRecord? { read(ConnectionRecord.self, from: "connection.json") }
    func saveConnection(_ record: ConnectionRecord) { write(record, to: "connection.json") }
    func clearConnection() { try? FileManager.default.removeItem(at: url("connection.json")) }

    // Chat transcript

    func loadChat() -> [PhoneChatMessage] { read([PhoneChatMessage].self, from: "chat.json") ?? [] }
    func saveChat(_ chat: [PhoneChatMessage]) { write(chat, to: "chat.json") }

    // Outbox

    func pendingOutbox() -> [OutboxItem] {
        (read([OutboxItem].self, from: "outbox.json") ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func enqueueOutbox(_ item: OutboxItem) {
        var items = pendingOutbox()
        items.append(item)
        write(items, to: "outbox.json")
    }

    func removeOutbox(_ messageID: String) {
        let items = pendingOutbox().filter { $0.messageID != messageID }
        write(items, to: "outbox.json")
    }
}
