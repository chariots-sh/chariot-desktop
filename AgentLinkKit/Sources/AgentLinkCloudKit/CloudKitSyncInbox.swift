import Foundation
import CloudKit
import AgentLinkKit

/// Push-driven inbox built on CKSyncEngine (design §13.9: "The sample uses
/// CKSyncEngine"). The engine maintains its own database subscription and
/// receives change pushes over CloudKit's daemon channel — independent of the
/// app-delegate APNs path — plus server change tokens and system-managed
/// scheduling. We consume fetched changes; outbound writes stay direct saves.
public final class CloudKitSyncInbox: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    private let mailbox: CloudKitMailbox
    private let stateURL: URL
    private var engine: CKSyncEngine?

    public var onEnvelope: (@Sendable (EncryptedEnvelope) -> Void)?
    public var onPairingRecordChanged: (@Sendable (String) -> Void)?
    public var onLog: (@Sendable (String) -> Void)?

    public init(mailbox: CloudKitMailbox, stateDirectory: URL) {
        self.mailbox = mailbox
        self.stateURL = stateDirectory.appendingPathComponent("cksyncengine-state.json")
    }

    public func start() {
        var saved: CKSyncEngine.State.Serialization?
        if let data = try? Data(contentsOf: stateURL) {
            saved = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }
        var configuration = CKSyncEngine.Configuration(database: mailbox.database,
                                                       stateSerialization: saved,
                                                       delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        onLog?("CKSyncEngine started (state \(saved == nil ? "fresh" : "restored"))")
    }

    /// Manual nudge (launch/foreground); the engine also fetches on its own pushes.
    public func fetchNow() {
        guard let engine else { return }
        Task {
            try? await engine.fetchChanges()
        }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: stateURL, options: .atomic)
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                route(record: modification.record)
            }
        case .accountChange(let change):
            onLog?("iCloud account change: \(change.changeType)")
        case .fetchedDatabaseChanges, .sentDatabaseChanges, .sentRecordZoneChanges,
             .willFetchChanges, .didFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    private func route(record: CKRecord) {
        switch record.recordType {
        case CloudKitMailbox.envelopeType:
            if let envelope = CloudKitMailbox.envelope(from: record) {
                onEnvelope?(envelope)
            }
        case CloudKitMailbox.pairingType:
            if let rendezvousID = record["rendezvousID"] as? String {
                onPairingRecordChanged?(rendezvousID)
            }
        default:
            break
        }
    }

    /// Outbound changes go through direct saves, not the engine.
    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}
