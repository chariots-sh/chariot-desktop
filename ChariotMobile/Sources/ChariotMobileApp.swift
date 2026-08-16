import SwiftUI
import UIKit

/// Registers for silent CloudKit pushes (design §13.12). Notifications are
/// only a wake signal — the model re-polls its mailbox on every wake.
final class PushDelegate: NSObject, UIApplicationDelegate {
    static let wakeNotification = Notification.Name("chariot.push.wake")

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Self.wakeNotification, object: nil)
        // Give the model a moment to fetch before reporting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            completionHandler(.newData)
        }
    }
}

@main
struct ChariotMobileApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) var pushDelegate
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onReceive(NotificationCenter.default.publisher(for: PushDelegate.wakeNotification)) { _ in
                    model.lastPushAt = Date()
                    Task {
                        await model.pollOnce()
                        model.flushOutbox()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground activation: reconcile once, then APNs carries it.
            if phase == .active {
                Task {
                    await model.pollOnce()
                    model.flushOutbox()
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        switch model.phase {
        case .welcome: WelcomeView()
        case .scanner: ScannerView()
        case .pairing: PairingProgressView()
        case .paired: MainTabs()
        case .revoked: RevokedView()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            ConversationView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
            ConnectionDetailsView()
                .tabItem { Label("Connection", systemImage: "dot.radiowaves.left.and.right") }
        }
    }
}
