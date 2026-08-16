import SwiftUI

@main
struct ChariotMobileApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS suspends the WebSocket in the background; foreground
            // activation reconnects and resumes from the last acked message.
            if phase == .active {
                model.reconnectIfNeeded()
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
