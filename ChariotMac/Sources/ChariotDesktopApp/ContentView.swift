import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String? = "sandbox"

    var body: some View {
        if let fatal = model.fatalError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    .foregroundStyle(Theme.amber)
                Text(fatal).multilineTextAlignment(.center).foregroundStyle(Theme.text)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .preferredColorScheme(.dark)
        } else {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "diamond")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                        Text("~/chariot")
                            .font(Theme.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("desktop")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    List(selection: $selection) {
                        SidebarRow(icon: "shippingbox", title: "Sandbox").tag("sandbox")
                        SidebarRow(icon: "bubble.left.and.bubble.right", title: "Conversation").tag("chat")
                        SidebarRow(icon: "iphone", title: "Devices").tag("devices")
                        SidebarRow(icon: "terminal", title: "Developer Access").tag("dev")
                        SidebarRow(icon: "list.bullet.rectangle", title: "Activity").tag("log")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .background(Theme.sidebar)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            } detail: {
                Group {
                    switch selection {
                    case "chat": ConversationView()
                    case "devices": DevicesView()
                    case "dev": DeveloperAccessView()
                    case "log": ActivityView()
                    default: SandboxView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .sheet(isPresented: Binding(get: { model.pairingPayloadJSON != nil },
                                        set: { if !$0 { model.pairingPayloadJSON = nil } })) {
                PairingSheet()
            }
            .alert("Pair new device?", isPresented: Binding(get: { model.approvalRequest != nil },
                                                            set: { _ in })) {
                Button("Approve") {
                    model.approvalRequest?.respond(true)
                    model.approvalRequest = nil
                }
                Button("Reject", role: .cancel) {
                    model.approvalRequest?.respond(false)
                    model.approvalRequest = nil
                }
            } message: {
                Text("\(model.approvalRequest?.name ?? "") wants to pair.\nFingerprint: \(model.approvalRequest?.fingerprint ?? "")\n\nApprove only if this matches the phone's fingerprint.")
            }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                model.refresh()
            }
        }
    }
}

struct SidebarRow: View {
    let icon: String
    let title: String

    var body: some View {
        Label {
            Text(title).font(.system(size: 13))
        } icon: {
            Image(systemName: icon).foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Page scaffold: "# title" + heading + cards.
struct Page<Content: View>: View {
    let hash: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHash(title: hash)
                    Text(title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                .padding(.bottom, 4)
                content
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }
}

// MARK: - Sandbox

struct SandboxView: View {
    @EnvironmentObject var model: AppModel

    var stateColor: Color {
        switch model.vmState {
        case .running: return Theme.green
        case .starting, .stopping: return Theme.amber
        case .failed: return Theme.red
        default: return Theme.secondary
        }
    }

    var body: some View {
        Page(hash: "sandbox", title: "Sandbox") {
            Card(title: "chariot sandbox", subtitle: "Disposable Debian VM · Virtualization.framework") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(text: model.vmState.rawValue, color: stateColor)
                        if model.bridgeConnected { Chip(text: "bridge connected", color: Theme.green) }
                        Spacer()
                        if model.busy { ProgressView().controlSize(.small) }
                    }
                    KVRow(key: "kernel", value: model.guestKernel.isEmpty ? "—" : model.guestKernel)
                    KVRow(key: "transport", value: model.transportMode)
                    KVRow(key: "fingerprint", value: model.macFingerprint)
                    KVRow(key: "status", value: model.statusLine, valueColor: Theme.secondary)
                    HStack(spacing: 8) {
                        Button("Start") { model.startSandbox() }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(model.busy || model.vmState == .running)
                        Button("Stop") { model.stopSandbox() }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(model.busy || model.vmState != .running)
                        Button("Restart") { model.restartSandbox() }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(model.busy || model.vmState != .running)
                        Spacer()
                        Button("Reset") { model.resetSandbox() }
                            .buttonStyle(AccentButtonStyle(danger: true))
                            .disabled(model.busy)
                            .help("Discard all guest changes and credentials")
                    }
                    .padding(.top, 6)
                }
            }

            Card(title: "agent — codex", subtitle: "Runs inside the sandbox as user `agent` in /workspace") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if model.agentSignedIn {
                            Chip(text: "signed in", color: Theme.green)
                        } else if model.agentInstalled {
                            Chip(text: "signed out", color: Theme.amber)
                        } else {
                            Chip(text: model.vmState == .running ? "installing…" : "sandbox stopped",
                                 color: Theme.secondary)
                        }
                        if !model.agentVersion.isEmpty {
                            Text(model.agentVersion)
                                .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        if model.signInInProgress && !model.agentSignedIn {
                            ProgressView().controlSize(.small)
                            Button("Cancel") {
                                model.hub?.cancelCodexLogin()
                                model.signInInProgress = false
                            }
                            .buttonStyle(OutlineButtonStyle())
                        } else if !model.agentSignedIn {
                            Button("Sign in Codex") { model.signInCodex() }
                                .buttonStyle(AccentButtonStyle())
                                .disabled(!model.agentInstalled || !model.bridgeConnected)
                        }
                    }
                    Text("Sign-in uses your ChatGPT account via the browser; the session lives only inside the sandbox and is erased by Reset.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }

            Card(title: "about this sandbox") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Separate Linux kernel; no host filesystem share.")
                    bullet("Outbound NAT internet only — nothing exposed on your network.")
                    bullet("Stop preserves the disk. Reset discards every guest change.")
                    bullet("Messages to paired devices are end-to-end encrypted.")
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(Theme.mono(12)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - Conversation

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHash(title: "conversation")
                Spacer()
                Chip(text: model.agentSignedIn ? "codex" : "agent offline",
                     color: model.agentSignedIn ? Theme.green : Theme.amber)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chat) { line in
                            HStack(alignment: .top) {
                                if line.role == "user" { Spacer(minLength: 80) }
                                Text(line.text.isEmpty ? "…" : line.text)
                                    .textSelection(.enabled)
                                    .font(line.role == "agent" ? Theme.mono(12) : .system(size: 13))
                                    .foregroundStyle(Theme.text)
                                    .padding(10)
                                    .background(line.role == "user" ? Theme.accent.opacity(0.18) : Theme.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(line.role == "user" ? Theme.accent.opacity(0.4) : Theme.border,
                                                lineWidth: 1))
                                if line.role != "user" { Spacer(minLength: 80) }
                            }
                            .id(line.id)
                        }
                    }.padding(16)
                }
                .onChange(of: model.chat.last?.text) {
                    if let last = model.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                TextField("Message Codex — ! runs a raw command", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.isEmpty || model.streaming)
            }
            .padding(12)
        }
        .background(Theme.bg)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.sendPrompt(text)
    }
}

// MARK: - Devices

struct DevicesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(hash: "paired devices", title: "Devices") {
            Card(title: "paired devices", subtitle: "Each device holds its own keys and can be revoked independently") {
                VStack(alignment: .leading, spacing: 10) {
                    if model.devices.isEmpty {
                        Text("No paired devices yet.")
                            .font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                    } else {
                        ForEach(model.devices, id: \.id) { device in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Theme.text)
                                            .strikethrough(device.revoked)
                                        if device.revoked { Chip(text: "revoked", color: Theme.red) }
                                    }
                                    Text("\(device.fingerprint) · paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                if !device.revoked {
                                    Button("Revoke") { model.revoke(device.id) }
                                        .buttonStyle(AccentButtonStyle(danger: true))
                                }
                            }
                            .padding(.vertical, 4)
                            if device.id != model.devices.last?.id {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                    Button("Pair new device") { model.startPairing() }
                        .buttonStyle(AccentButtonStyle())
                        .padding(.top, 6)
                }
            }
        }
        .alert("Can't pair right now", isPresented: Binding(get: { model.pairingErrorMessage != nil },
                                                            set: { if !$0 { model.pairingErrorMessage = nil } })) {
            Button("OK") { model.pairingErrorMessage = nil }
        } message: {
            Text(model.pairingErrorMessage ?? "")
        }
    }
}

struct PairingSheet: View {
    @EnvironmentObject var model: AppModel

    var qrImage: NSImage? {
        guard let json = model.pairingPayloadJSON else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(json.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    var body: some View {
        VStack(spacing: 14) {
            SectionHash(title: "pair")
            Text("Scan with your iPhone")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            if let qr = qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 260, height: 260)
                    .padding(10)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("Expires in 2 minutes · single use\nMac fingerprint \(model.macFingerprint)")
                .font(Theme.mono(11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
            HStack {
                Button("Copy payload") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.pairingPayloadJSON ?? "", forType: .string)
                }
                .buttonStyle(OutlineButtonStyle())
                Button("Done") { model.pairingPayloadJSON = nil }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Developer access

struct DeveloperAccessView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(hash: "developer access", title: "Developer Access") {
            Card(title: "ssh + scp", subtitle: "Localhost-only, tunneled over virtio — never exposed to your network") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Chip(text: model.developerAccessInfo == nil ? "locked" : "unlocked",
                             color: model.developerAccessInfo == nil ? Theme.secondary : Theme.amber)
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.developerAccessInfo != nil },
                                                 set: { _ in model.toggleDeveloperAccess() }))
                            .toggleStyle(.switch)
                            .disabled(model.vmState != .running)
                    }
                    Text("Unlocking SSH grants full control of the sandbox — including any credentials inside it — and bypasses agent tool approvals.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    if let info = model.developerAccessInfo {
                        Divider().overlay(Theme.border)
                        Text(info.command)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.green)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        HStack {
                            Button("Copy SSH command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(info.command, forType: .string)
                            }
                            .buttonStyle(OutlineButtonStyle())
                            Button("Copy instructions for Codex") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(info.instructions, forType: .string)
                            }
                            .buttonStyle(OutlineButtonStyle())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(hash: "activity", title: "Activity") {
            Card(title: "event log", subtitle: "Transport, pairing, and agent events") {
                VStack(alignment: .leading, spacing: 3) {
                    if model.eventLog.isEmpty {
                        Text("No events yet.").font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(Array(model.eventLog.suffix(120).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
