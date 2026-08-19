import Foundation
import Sparkle

/// Sparkle wiring for Chariot Desktop.
///
/// The only Chariot-specific behaviour is the relaunch gate: swapping the app
/// bundle while `Virtualization.framework` has VMs attached kills every running
/// agent mid-turn, with the guest disk left however it happened to be. So when
/// an update is ready and agents are live, the relaunch is postponed until the
/// fleet has been stopped cleanly.
///
/// Sparkle verifies two things independently before any of this runs: the
/// appcast item's EdDSA signature, and that the downloaded bundle's Developer
/// ID team matches the running app. Neither is Chariot's to re-implement.
/// `@unchecked Sendable`: every stored property is created and mutated on the
/// main actor — Sparkle calls its delegate there, and the KVO observation hops
/// back with `Task { @MainActor }`.
final class UpdaterController: NSObject, ObservableObject, @unchecked Sendable {
    /// Live agent count, read at the moment an update wants to relaunch.
    private let runningAgentCount: @MainActor () -> Int
    /// Stops every running agent; must complete before the bundle is replaced.
    private let stopAllAgents: @MainActor () async -> Void
    /// Surfaces updater state on the Activity log.
    private let log: @MainActor (String) -> Void

    @Published private(set) var canCheckForUpdates = false
    /// Set while the fleet is being stopped for a pending update, so the UI can
    /// explain why the app is shutting agents down on its own.
    @Published private(set) var isStoppingFleetForUpdate = false

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    init(runningAgentCount: @escaping @MainActor () -> Int,
         stopAllAgents: @escaping @MainActor () async -> Void,
         log: @escaping @MainActor (String) -> Void) {
        self.runningAgentCount = runningAgentCount
        self.stopAllAgents = stopAllAgents
        self.log = log
        super.init()
    }

    /// True once a real feed and key are baked into the bundle. Development
    /// builds ship an empty `SUPublicEDKey`, and starting Sparkle without one
    /// means it could not verify a feed even if it fetched it — so it stays off
    /// rather than nagging with errors it cannot resolve.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let key = info?["SUPublicEDKey"] as? String ?? ""
        let feed = info?["SUFeedURL"] as? String ?? ""
        return isUsableEdKey(key) && !feed.isEmpty && !feed.hasPrefix("$(")
    }

    /// Sparkle's public key is base64 of a 32-byte ed25519 key. Presence alone
    /// is not enough: a placeholder key is non-empty, so the updater starts and
    /// then fails with "The updater failed to start" in a dialog the user can do
    /// nothing about. Staying off is the better failure.
    static func isUsableEdKey(_ key: String) -> Bool {
        guard let decoded = Data(base64Encoded: key) else { return false }
        return decoded.count == 32
    }

    @MainActor
    func start() {
        guard Self.isConfigured else {
            log("Automatic updates disabled: this build has no update feed configured.")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                     updaterDelegate: self,
                                                     userDriverDelegate: nil)
        updaterController = controller
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    @MainActor
    func checkForUpdates() {
        updaterController?.updater.checkForUpdates()
    }
}

extension UpdaterController: SPUUpdaterDelegate {
    /// Sparkle is about to replace the bundle and relaunch. Returning true
    /// holds it until `installHandler` runs, which is our window to bring the
    /// fleet down without losing guest state.
    func updater(_ updater: SPUUpdater,
                 shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            let running = runningAgentCount()
            guard running > 0 else { return false }

            log("Update \(item.displayVersionString) ready — stopping \(running) running agent\(running == 1 ? "" : "s") first.")
            isStoppingFleetForUpdate = true
            Task { @MainActor in
                await stopAllAgents()
                isStoppingFleetForUpdate = false
                log("Fleet stopped; installing update \(item.displayVersionString).")
                installHandler()
            }
            return true
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // A "no update found" abort is the normal outcome of a scheduled check.
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Task { @MainActor in self.log("Update check failed: \(error.localizedDescription)") }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in self.log("Installing Chariot Desktop \(item.displayVersionString).") }
    }
}
