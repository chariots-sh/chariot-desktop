import SwiftUI
import AppKit
import CloudKit
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
    static let pushWake = Notification.Name("chariot.mac.push.wake")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.registerForRemoteNotifications()
    }

    static let apnsDiagnostic = Notification.Name("chariot.mac.apns.diagnostic")

    private func diagnose(_ message: String) {
        NotificationCenter.default.post(name: Self.apnsDiagnostic, object: message)
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        diagnose("apns registered (token \(deviceToken.prefix(4).map { String(format: "%02x", $0) }.joined())…)")
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        diagnose("apns registration FAILED: \(error)")
    }

    // CloudKit zone-subscription pushes: a wake signal only (design §4.8).
    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        diagnose("push received")
        NotificationCenter.default.post(name: Self.pushWake, object: nil)
    }

    // Foreground activation: reconcile once (§13.12).
    func applicationDidBecomeActive(_ notification: Notification) {
        NotificationCenter.default.post(name: Self.pushWake, object: nil)
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
    @Published var transportMode = "Local mailbox (127.0.0.1)"

    private(set) var hub: ChariotHub?

    var macFingerprint: String { hub?.macPublicIdentity.fingerprint ?? "—" }

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
            NotificationCenter.default.addObserver(forName: AppDelegate.pushWake, object: nil,
                                                   queue: .main) { [weak hub] _ in
                hub?.pokeCloudPoll()
            }
            NotificationCenter.default.addObserver(forName: AppDelegate.apnsDiagnostic, object: nil,
                                                   queue: .main) { [weak hub] notification in
                if let message = notification.object as? String {
                    hub?.note(message)
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
            try hub.startMailboxServer(port: UInt16(env["CHARIOT_MAILBOX_PORT"] ?? "8787") ?? 8787)
            // Real CloudKit transport (design §4.6) when the entitled build
            // declares a container; the localhost mailbox stays for local dev.
            if let container = env["CHARIOT_CLOUDKIT"]
                ?? Bundle.main.object(forInfoDictionaryKey: "ChariotCloudKitContainer") as? String {
                hub.cloudDesired = true
                Task {
                    // The development container rate-limits aggressively; keep
                    // retrying with the server-provided backoff until it opens.
                    while true {
                        do {
                            try await hub.enableCloudKit(containerID: container)
                            await MainActor.run { self.transportMode = "CloudKit (\(container))" }
                            return
                        } catch let error as CKError
                            where error.code == .quotaExceeded || error.code == .requestRateLimited {
                            let wait = (error.retryAfterSeconds ?? 60) + 5
                            await MainActor.run {
                                self.transportMode = "CloudKit throttled — retrying in \(Int(wait))s"
                            }
                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                        } catch {
                            await MainActor.run {
                                self.transportMode = "CloudKit unavailable — local mailbox only"
                                self.eventLog.append("CloudKit failed: \(error)")
                            }
                            return
                        }
                    }
                }
            }
            refreshDevices()
            statusLine = "Mailbox on 127.0.0.1:\(hub.mailboxPort). Sandbox stopped."
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
