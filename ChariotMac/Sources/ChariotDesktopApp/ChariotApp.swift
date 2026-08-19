import SwiftUI
import AppKit
import ChariotCore
import AgentLinkKit

@main
struct ChariotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Before any socket exists: a peer vanishing mid-write must fail the
        // write, not kill the app.
        ignoreSIGPIPE()
    }

    var body: some Scene {
        WindowGroup("Chariot Desktop") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 620)
                .task { model.startUpdater() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: model.updater)
            }
        }
    }
}

/// Observes the updater directly so the menu item enables itself the moment
/// Sparkle is ready — AppModel does not republish the updater's state.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ChatLine: Identifiable {
    let id = UUID()
    var role: String  // "user" | "agent" | "system"
    var text: String
}

struct DeviceRow: Identifiable, Equatable {
    let id: String
    let name: String
    let fingerprint: String
    let pairedAt: Date
    let revoked: Bool
}

/// One agent in the sidebar/detail: fleet summary plus GUI-only state.
struct AgentViewState: Identifiable, Equatable {
    let id: String            // instance UUID
    var name: String
    var packID: String
    var packDir: String
    var vmState: SandboxState
    var bridgeConnected: Bool
    var harness: HarnessKind
    var powerSource: PowerSourceKind
    /// Per-agent model override ("" = default chain).
    var model: String
    var agentInstalled: Bool
    /// ChatGPT-codex: signed in. API-powered: configured and ready.
    var agentReady: Bool
    var agentVersion: String
    /// Why the guest could not install the harness, when it could not.
    var agentInstallError: String?
    var devices: [DeviceRow]
}

struct PackRow: Identifiable, Equatable {
    var id: String { dir }
    let dir: String
    let packID: String
    let name: String
    let version: String
}

/// First-run base image install, as the setup screen sees it.
enum SetupPhase {
    case idle
    case running(BaseImageProgress)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var agents: [AgentViewState] = []
    @Published var packs: [PackRow] = []
    @Published var chats: [String: [ChatLine]] = [:]      // agent id → transcript
    @Published var streamingAgents: Set<String> = []
    @Published var busyAgents: Set<String> = []
    @Published var signInProgress: Set<String> = []
    @Published var devAccess: [String: (port: UInt16, command: String, instructions: String)] = [:]
    @Published var statusLine = "Starting…"
    @Published var pairingPayloadJSON: String?
    @Published var approvalRequest: (name: String, fingerprint: String, respond: @Sendable (Bool) -> Void)?
    @Published var eventLog: [String] = []
    @Published var fatalError: String?
    @Published var errorMessage: String?
    @Published var tailnetStatus: TailnetStatus = .stopped
    @Published var tailnetInfo: TailnetInfo?
    @Published var showCreateSheet = false

    /// Blocks the main UI until the guest base image is on disk.
    @Published var needsBaseImage = false
    @Published var setupPhase: SetupPhase = .idle

    // Chariot account + local model defaults (Settings page).
    @Published var chariotSignIn: ChariotAccountManager.SignInState = .signedOut
    @Published var localModelDefaultBaseURL = ""
    @Published var localModelDefaultModel = ""

    private(set) var hub: ChariotHub?
    private(set) var updater: UpdaterController!
    private let baseImage: BaseImageInstaller
    private var setupTask: Task<Void, Never>?
    private var setupGeneration = 0
    private var updaterStarted = false

    var macFingerprint: String { hub?.macPublicIdentity.fingerprint ?? "—" }

    var transportMode: String {
        guard hub?.tailscaleEnabled == true else { return "Local development (127.0.0.1)" }
        switch tailnetStatus {
        case .ready(let info): return "Tailscale — \(info.dnsName)"
        default: return "Tailscale — \(tailnetStatus.label)"
        }
    }

    init() {
        baseImage = BaseImageInstaller(imagePath: Self.baseImagePath)
        needsBaseImage = !baseImage.isReady

        do {
            let env = ProcessInfo.processInfo.environment
            let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ChariotDesktop")
            let dataDir = env["CHARIOT_DATA_DIR"].map(URL.init(fileURLWithPath:)) ?? defaultRoot

            let guestResources: URL
            if let override = env["CHARIOT_GUEST_RESOURCES"] {
                guestResources = URL(fileURLWithPath: override)
            } else if let bundled = Bundle.main.resourceURL,
                      FileManager.default.fileExists(atPath: bundled.appendingPathComponent("bridge.py").path) {
                guestResources = bundled
            } else {
                guestResources = defaultRoot.appendingPathComponent("guest")
            }

            let hub = try ChariotHub(paths: ChariotPaths(dataDirectory: dataDir, guestResources: guestResources))

            // A downloaded app starts with an empty packs directory, so New
            // Agent would offer nothing to create. Copy the samples shipped in
            // the bundle; existing folders are left alone, since packs are
            // user-editable content.
            if let bundledPacks = Bundle.main.resourceURL?.appendingPathComponent("packs") {
                let seeded = PackLoader.seedBundledPacks(from: bundledPacks,
                                                         into: hub.paths.packsDirectory)
                if !seeded.isEmpty {
                    eventLog.append("Installed sample packs: \(seeded.joined(separator: ", "))")
                }
            }

            hub.autoApprovePairing = false
            hub.defaultBaseImagePath = baseImagePath
            self.hub = hub
            hub.onEvent = { [weak self] message in
                Task { @MainActor in
                    self?.eventLog.append(message)
                    if self!.eventLog.count > 200 { self!.eventLog.removeFirst() }
                    self?.refresh()
                }
            }
            hub.onDeviceApprovalRequest = { [weak self] response, respond in
                Task { @MainActor in
                    // Close the QR sheet first — an alert cannot present under
                    // an open sheet, and the QR is consumed at this point.
                    self?.pairingPayloadJSON = nil
                    self?.approvalRequest = (response.mobileDisplayName, response.mobile.fingerprint, respond)
                }
            }
            // Brokered browser step (design §3.1): guest asked for OAuth; the
            // Mac performs the browser dance. The localhost callback is
            // tunneled back into the guest by the hub.
            hub.onOAuthRequest = { urlString in
                Task { @MainActor in
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            try hub.startTransportServer(port: UInt16(env["CHARIOT_MAILBOX_PORT"] ?? "8787") ?? 8787)

            // Embedded Tailscale node (one per installation). Users never
            // install the Tailscale Mac app; the bundled helper is the node.
            if hub.tailscaleEnabled {
                if let helper = Self.helperURL() {
                    hub.enableTailscale(helperURL: helper)
                } else {
                    eventLog.append("agent-tailnet helper missing from the app bundle")
                }
            }

            refresh()
            statusLine = "Transport on 127.0.0.1:\(hub.transportPort)."
        } catch {
            fatalError = "Failed to start Chariot core: \(error)"
        }

        updater = UpdaterController(
            runningAgentCount: { [weak self] in
                self?.agents.filter { $0.vmState == .running }.count ?? 0
            },
            stopAllAgents: { [weak self] in await self?.stopAllAgents() },
            log: { [weak self] message in
                self?.eventLog.append(message)
                self?.statusLine = message
            })
    }

    /// Called once the first window exists — Sparkle should not schedule checks
    /// before the app has finished launching.
    func startUpdater() {
        guard !updaterStarted else { return }
        updaterStarted = true
        updater.start()
    }

    // MARK: First-run base image

    var baseImageVersion: String { baseImage.expectedVersion }

    var baseImageDownloadSize: String {
        ByteCountFormatter.string(fromByteCount: baseImage.downloadBytes, countStyle: .file)
    }

    func installBaseImage() {
        guard setupTask == nil else { return }
        setupGeneration &+= 1
        // A cancelled attempt keeps running until its next suspension point, so
        // every state write below is gated on still being the current attempt —
        // otherwise cancel-then-retry lets the abandoned task clobber the new
        // one's progress and drop setupTask, allowing two concurrent installs.
        let generation = setupGeneration
        setupPhase = .running(.downloading(received: 0, total: baseImage.downloadBytes))
        setupTask = Task { [baseImage] in
            do {
                try await baseImage.install { progress in
                    Task { @MainActor in
                        guard self.setupGeneration == generation else { return }
                        self.setupPhase = .running(progress)
                    }
                }
                await MainActor.run {
                    guard self.setupGeneration == generation else { return }
                    self.setupTask = nil
                    self.setupPhase = .idle
                    self.needsBaseImage = false
                    self.statusLine = "Guest image installed — create an agent to begin."
                    self.eventLog.append("Guest base image \(baseImage.expectedVersion) installed.")
                }
            } catch {
                let cancelled = Task.isCancelled
                await MainActor.run {
                    guard self.setupGeneration == generation else { return }
                    self.setupTask = nil
                    self.setupPhase = cancelled ? .idle : .failed("\(error)")
                }
            }
        }
    }

    func cancelBaseImageInstall() {
        setupTask?.cancel()
        setupTask = nil
        setupGeneration &+= 1
        setupPhase = .idle
    }

    /// Brings the whole fleet down; used before an update replaces the bundle.
    func stopAllAgents() async {
        guard let hub else { return }
        for agent in agents where agent.vmState == .running || agent.vmState == .starting {
            try? await hub.stopAgent(agent.id)
        }
        refresh()
    }

    /// The bundled helper lives next to the app executable (signed and covered
    /// by the hardened runtime); a dev override and a build-tree fallback keep
    /// `swift run` workflows working.
    static func helperURL() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["CHARIOT_TAILNET_HELPER"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("agent-tailnet"))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("agent-tailnet"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Static so `init` can build the installer before `self` is available.
    static var baseImagePath: String {
        ProcessInfo.processInfo.environment["CHARIOT_BASE_IMAGE"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ChariotDesktop/base-image.raw").path
    }

    var baseImagePath: String { Self.baseImagePath }

    func refresh() {
        guard let hub else { return }
        tailnetStatus = hub.tailnetStatus
        tailnetInfo = hub.tailnet?.info
        agents = hub.agentSummaries().map { summary in
            AgentViewState(id: summary.record.instanceID,
                           name: summary.record.displayName,
                           packID: summary.record.packID,
                           packDir: summary.record.packDirectoryName,
                           vmState: summary.vmState,
                           bridgeConnected: summary.bridgeConnected,
                           harness: summary.record.effectiveHarness,
                           powerSource: summary.record.effectivePowerSource,
                           model: summary.record.model ?? "",
                           agentInstalled: summary.agentStatus?.installed ?? false,
                           agentReady: summary.agentStatus?.loggedIn ?? false,
                           agentVersion: summary.agentStatus?.version ?? "",
                           agentInstallError: summary.agentStatus?.installError,
                           devices: hub.pairedDevices(instanceID: summary.record.instanceID).map {
                               DeviceRow(id: $0.id, name: $0.name, fingerprint: $0.fingerprint,
                                         pairedAt: $0.pairedAt, revoked: $0.revoked)
                           })
        }
        for agent in agents where agent.agentReady {
            signInProgress.remove(agent.id)
        }
        packs = PackLoader.availablePacks(in: hub.paths.packsDirectory).map {
            PackRow(dir: $0.directoryName, packID: $0.manifest.id,
                    name: $0.manifest.name, version: $0.manifest.version)
        }
        chariotSignIn = hub.account.signInState
        let localDefaults = hub.account.hostSettings().localModel
        localModelDefaultBaseURL = localDefaults?.baseURL ?? ""
        localModelDefaultModel = localDefaults?.model ?? ""
    }

    func agent(_ id: String) -> AgentViewState? {
        agents.first { $0.id == id }
    }

    // MARK: Fleet actions

    func createAgent(fromPack dir: String,
                     harness: HarnessKind = .codex,
                     powerSource: PowerSourceKind = .chatgpt,
                     model: String? = nil,
                     localBaseURL: String? = nil) {
        guard let hub else { return }
        statusLine = "Creating agent from \(dir)…"
        Task {
            do {
                let record = try await hub.createAgent(fromPackDirectory: dir,
                                                       harness: harness,
                                                       powerSource: powerSource,
                                                       model: model,
                                                       localBaseURL: localBaseURL)
                await MainActor.run {
                    self.statusLine = "\(record.displayName) created — press Start to boot it."
                    self.refresh()
                }
            } catch {
                await MainActor.run { self.errorMessage = "Create failed: \(error)" }
            }
        }
    }

    /// Scaffold a new pack from the New Pack sheet. Returns its folder name
    /// (so the New Agent sheet can preselect it), or nil after surfacing the
    /// error.
    func createPack(name: String, instructions: String,
                    soul: String, seedMemory: String) -> String? {
        guard let hub else { return nil }
        do {
            let pack = try PackLoader.createPack(named: name,
                                                 instructions: instructions,
                                                 soul: soul,
                                                 seedMemory: seedMemory,
                                                 in: hub.paths.packsDirectory)
            eventLog.append("Created pack \(pack.directoryName)")
            statusLine = "\(pack.manifest.name) pack created."
            refresh()
            return pack.directoryName
        } catch {
            errorMessage = "Could not create pack: \(error)"
            return nil
        }
    }

    /// Packs are folders; everything beyond the sheet's markdown (tools/,
    /// skills/, pack.json tweaks) is a Finder edit.
    func revealPacksDirectory() {
        guard let dir = hub?.paths.packsDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func setAgentModel(_ agentID: String, model: String) {
        guard let hub else { return }
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await hub.setAgentModel(agentID, model: value.isEmpty ? nil : value)
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run { self.errorMessage = "Model change failed: \(error)" }
            }
        }
    }

    // MARK: Chariot account

    func chariotAccountSignIn() {
        guard let hub else { return }
        Task {
            do {
                let approveURL = try await hub.account.startSignIn()
                _ = await MainActor.run { NSWorkspace.shared.open(approveURL) }
                await MainActor.run { self.refresh() }
            } catch {
                await MainActor.run { self.errorMessage = "Chariot sign-in failed: \(error)" }
            }
        }
    }

    func chariotAccountSignOut() {
        hub?.account.signOut()
        refresh()
    }

    func saveLocalModelDefaults() {
        guard let hub else { return }
        do {
            let base = localModelDefaultBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = localModelDefaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
            try hub.account.setLocalModelDefaults(baseURL: base.isEmpty ? nil : base,
                                                  model: model.isEmpty ? nil : model)
            statusLine = "Local model defaults saved."
        } catch {
            errorMessage = "Could not save local model defaults: \(error)"
        }
    }

    /// Probe the configured local server's /models from the host — a quick
    /// "is Ollama actually up" check for the Settings page.
    func testLocalModelServer() {
        let base = localModelDefaultBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base)?.appendingPathComponent("models") else {
            errorMessage = "Enter a base URL first (e.g. http://127.0.0.1:11434/v1)."
            return
        }
        statusLine = "Checking \(base)…"
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    self.statusLine = code == 200
                        ? "Local model server is reachable."
                        : "Local server answered HTTP \(code)."
                }
            } catch {
                await MainActor.run {
                    self.statusLine = "Local server unreachable: \(error.localizedDescription)"
                }
            }
        }
    }

    func startAgent(_ id: String) {
        lifecycle(id, "Booting") { try await $0.startAgent(id) }
    }

    func stopAgent(_ id: String) {
        lifecycle(id, "Stopping") { try await $0.stopAgent(id) }
    }

    func resetAgent(_ id: String) {
        lifecycle(id, "Resetting (discarding all guest changes)") { try await $0.resetAgent(id) }
    }

    private func lifecycle(_ id: String, _ label: String,
                           _ operation: @escaping @Sendable (ChariotHub) async throws -> Void) {
        guard let hub else { return }
        busyAgents.insert(id)
        let name = agent(id)?.name ?? "agent"
        statusLine = "\(label) \(name)…"
        Task {
            do {
                try await operation(hub)
                await MainActor.run { self.statusLine = "\(name): done." }
            } catch {
                await MainActor.run { self.statusLine = "\(name): \(label.lowercased()) failed: \(error)" }
            }
            await MainActor.run {
                self.busyAgents.remove(id)
                self.refresh()
            }
        }
    }

    func sendPrompt(_ text: String, to agentID: String) {
        guard let hub else { return }
        chats[agentID, default: []].append(ChatLine(role: "user", text: text))
        chats[agentID, default: []].append(ChatLine(role: "agent", text: ""))
        let agentLineIndex = chats[agentID]!.count - 1
        streamingAgents.insert(agentID)
        do {
            try hub.sendLocalPrompt(text, instanceID: agentID, onDelta: { [weak self] delta in
                Task { @MainActor in
                    guard let self, self.chats[agentID]?.indices.contains(agentLineIndex) == true else { return }
                    self.chats[agentID]![agentLineIndex].text += delta
                }
            }, onCompleted: { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    self.streamingAgents.remove(agentID)
                    if code != 0, self.chats[agentID]?.indices.contains(agentLineIndex) == true {
                        self.chats[agentID]![agentLineIndex].text += "\n[exit code \(code)]"
                    }
                }
            })
        } catch {
            chats[agentID]![agentLineIndex] = ChatLine(role: "system",
                                                       text: "Sandbox not running: press Start first.")
            streamingAgents.remove(agentID)
        }
    }

    func signInCodex(_ agentID: String) {
        guard let hub else { return }
        do {
            try hub.startCodexLogin(instanceID: agentID)
            signInProgress.insert(agentID)
            statusLine = "Complete the ChatGPT sign-in in your browser…"
        } catch {
            errorMessage = "Sign-in failed to start: \(error)"
        }
    }

    func cancelSignIn(_ agentID: String) {
        hub?.cancelCodexLogin(instanceID: agentID)
        signInProgress.remove(agentID)
    }

    func startPairing(_ agentID: String) {
        guard let hub else { return }
        do {
            let payload = try hub.startPairingSession(instanceID: agentID)
            let json = try CanonicalCoding.encode(payload)
            pairingPayloadJSON = String(data: json, encoding: .utf8)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func revoke(_ deviceID: String, agentID: String) {
        hub?.revokeDevice(deviceID, instanceID: agentID)
        refresh()
    }

    func toggleDeveloperAccess(_ agentID: String) {
        guard let hub else { return }
        if devAccess[agentID] != nil {
            hub.disableDeveloperAccess(instanceID: agentID)
            devAccess[agentID] = nil
        } else {
            do {
                devAccess[agentID] = try hub.enableDeveloperAccess(instanceID: agentID)
            } catch {
                errorMessage = "Developer access failed: \(error)"
            }
        }
    }

    // MARK: Tailscale controls

    var tailnetAuthURL: String? {
        if case .needsLogin(let url) = tailnetStatus { return url }
        return nil
    }

    func tailscaleSignIn() {
        guard let hub else { return }
        if let urlString = tailnetAuthURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else {
            hub.tailnet?.start()
            hub.tailnet?.requestStatus()
        }
    }

    func tailscaleReauthenticate() {
        hub?.tailnet?.logout()  // backend falls to NeedsLogin and emits a fresh auth URL
    }

    func tailscaleDisconnect() {
        hub?.tailnet?.stop()
        refresh()
    }

    func tailscaleConnect() {
        hub?.tailnet?.start()
        refresh()
    }

    /// Destructive: deletes the local node identity; requires signing in to
    /// Tailscale again. The UI shows an explicit warning first.
    func tailscaleReset() {
        do {
            try hub?.tailnet?.reset()
        } catch {
            statusLine = "Tailscale reset failed: \(error)"
        }
        refresh()
    }

    func openTailscaleAdmin() {
        NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/machines")!)
    }
}
