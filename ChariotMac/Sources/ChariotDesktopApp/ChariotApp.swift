import SwiftUI
import AppKit
import ChariotCore
import AgentLinkKit

@main
struct ChariotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Chariot Desktop") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
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

@MainActor
final class AppModel: ObservableObject {
    @Published var vmState: SandboxState = .notCreated
    @Published var bridgeConnected = false
    @Published var guestKernel = ""
    @Published var busy = false
    @Published var statusLine = "Starting…"
    @Published var chat: [ChatLine] = []
    @Published var streaming = false
    @Published var pairingPayloadJSON: String?
    @Published var devices: [(id: String, name: String, pairedAt: Date, revoked: Bool, fingerprint: String)] = []
    @Published var approvalRequest: (name: String, fingerprint: String, respond: @Sendable (Bool) -> Void)?
    @Published var developerAccessInfo: (port: UInt16, command: String, instructions: String)?
    @Published var agentInstalled = false
    @Published var agentVersion = ""
    @Published var agentSignedIn = false
    @Published var signInInProgress = false
    @Published var eventLog: [String] = []
    @Published var fatalError: String?
    @Published var tailnetStatus: TailnetStatus = .stopped
    @Published var tailnetInfo: TailnetInfo?

    private(set) var hub: ChariotHub?

    var macFingerprint: String { hub?.macPublicIdentity.fingerprint ?? "—" }

    var transportMode: String {
        guard hub?.tailscaleEnabled == true else { return "Local development (127.0.0.1)" }
        switch tailnetStatus {
        case .ready(let info): return "Tailscale — \(info.dnsName)"
        default: return "Tailscale — \(tailnetStatus.label)"
        }
    }

    init() {
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
            hub.autoApprovePairing = false
            self.hub = hub
            hub.onEvent = { [weak self] message in
                Task { @MainActor in
                    self?.eventLog.append(message)
                    if self!.eventLog.count > 200 { self!.eventLog.removeFirst() }
                    self?.refreshDevices()
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

            refreshDevices()
            statusLine = "Transport on 127.0.0.1:\(hub.transportPort). Sandbox stopped."
            vmState = hub.vmState
            // Adopt an existing instance so the UI reflects it before Start.
            if !hub.backend.existingInstanceIDs().isEmpty {
                let imagePath = baseImagePath
                Task {
                    _ = try? await hub.ensureInstance(configuration: SandboxConfiguration(baseImagePath: imagePath))
                    await MainActor.run {
                        self.refresh()
                        self.statusLine = "Sandbox ready — press Start to boot it."
                    }
                }
            }
        } catch {
            fatalError = "Failed to start Chariot core: \(error)"
        }
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

    var baseImagePath: String {
        ProcessInfo.processInfo.environment["CHARIOT_BASE_IMAGE"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/ChariotDesktop/base-image.raw").path
    }

    func refresh() {
        guard let hub else { return }
        vmState = hub.vmState
        bridgeConnected = hub.bridgeConnected
        guestKernel = hub.lastGuestStatus?.kernel ?? ""
        tailnetStatus = hub.tailnetStatus
        tailnetInfo = hub.tailnet?.info
        if let agent = hub.agentStatus {
            agentInstalled = agent.installed
            agentVersion = agent.version ?? ""
            agentSignedIn = agent.loggedIn
            if agent.loggedIn { signInInProgress = false }
        } else {
            agentInstalled = false
            agentSignedIn = false
        }
        refreshDevices()
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

    func signInCodex() {
        guard let hub else { return }
        do {
            try hub.startCodexLogin()
            signInInProgress = true
            statusLine = "Complete the ChatGPT sign-in in your browser…"
        } catch {
            statusLine = "Sign-in failed to start: \(error)"
        }
    }

    func refreshDevices() {
        devices = hub?.pairedDevices() ?? []
    }

    func startSandbox() {
        guard let hub else { return }
        busy = true
        statusLine = "Preparing sandbox…"
        Task {
            do {
                _ = try await hub.ensureInstance(configuration: SandboxConfiguration(baseImagePath: baseImagePath))
                await MainActor.run { self.statusLine = "Booting Linux VM…"; self.vmState = .starting }
                try await hub.startVM()
                await MainActor.run {
                    self.statusLine = "Sandbox running."
                    self.refresh()
                }
            } catch {
                await MainActor.run { self.statusLine = "Start failed: \(error)" }
            }
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }

    func stopSandbox() {
        lifecycle("Stopping…") { try await $0.stopVM() }
    }

    func restartSandbox() {
        lifecycle("Restarting…") { try await $0.restartVM() }
    }

    func resetSandbox() {
        lifecycle("Resetting sandbox (discarding all guest changes)…") { try await $0.resetVM() }
    }

    private func lifecycle(_ label: String, _ operation: @escaping @Sendable (ChariotHub) async throws -> Void) {
        guard let hub else { return }
        busy = true
        statusLine = label
        Task {
            do {
                try await operation(hub)
                await MainActor.run { self.statusLine = "Done." }
            } catch {
                await MainActor.run { self.statusLine = "\(label) failed: \(error)" }
            }
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }

    func sendPrompt(_ text: String) {
        guard let hub else { return }
        chat.append(ChatLine(role: "user", text: text))
        let agentLineIndex = chat.count
        chat.append(ChatLine(role: "agent", text: ""))
        streaming = true
        do {
            try hub.sendLocalPrompt(text, onDelta: { [weak self] delta in
                Task { @MainActor in
                    guard let self, self.chat.indices.contains(agentLineIndex) else { return }
                    self.chat[agentLineIndex].text += delta
                }
            }, onCompleted: { [weak self] code in
                Task { @MainActor in
                    guard let self else { return }
                    self.streaming = false
                    if code != 0, self.chat.indices.contains(agentLineIndex) {
                        self.chat[agentLineIndex].text += "\n[exit code \(code)]"
                    }
                }
            })
        } catch {
            chat[agentLineIndex] = ChatLine(role: "system", text: "Sandbox not running: start it from the Sandbox tab.")
            streaming = false
        }
    }

    @Published var pairingErrorMessage: String?

    func startPairing() {
        guard let hub else { return }
        do {
            let payload = try hub.startPairingSession()
            let json = try CanonicalCoding.encode(payload)
            pairingPayloadJSON = String(data: json, encoding: .utf8)
        } catch {
            pairingErrorMessage = "\(error)"
        }
    }

    func revoke(_ deviceID: String) {
        hub?.revokeDevice(deviceID)
        refreshDevices()
    }

    func toggleDeveloperAccess() {
        guard let hub else { return }
        if developerAccessInfo != nil {
            hub.disableDeveloperAccess()
            developerAccessInfo = nil
        } else {
            do {
                let info = try hub.enableDeveloperAccess()
                developerAccessInfo = info
            } catch {
                statusLine = "Developer access failed: \(error)"
            }
        }
    }
}
