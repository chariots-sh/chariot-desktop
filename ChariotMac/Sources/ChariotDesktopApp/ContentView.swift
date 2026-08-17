import SwiftUI
import AppKit
import ChariotCore
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?

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
        } else if model.needsBaseImage {
            // Nothing in the fleet UI works without the guest image, so setup
            // takes the whole window rather than sitting behind an empty list.
            FirstRunView()
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
                        Section("agents") {
                            ForEach(model.agents) { agent in
                                AgentSidebarRow(agent: agent).tag("agent:\(agent.id)")
                            }
                            Button {
                                model.refresh()
                                model.showCreateSheet = true
                            } label: {
                                Label {
                                    Text("New Agent").font(.system(size: 13))
                                } icon: {
                                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                        Section("system") {
                            SidebarRow(icon: "network", title: "Tailscale").tag("tailscale")
                            SidebarRow(icon: "list.bullet.rectangle", title: "Activity").tag("log")
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
                .background(Theme.sidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            } detail: {
                Group {
                    switch selection {
                    case "tailscale": TailscaleView()
                    case "log": ActivityView()
                    case .some(let tag) where tag.hasPrefix("agent:"):
                        AgentDetailView(agentID: String(tag.dropFirst("agent:".count)))
                    default: FleetHomeView()
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
            .sheet(isPresented: $model.showCreateSheet) {
                CreateAgentSheet()
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
            .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                                set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
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

struct AgentSidebarRow: View {
    let agent: AgentViewState

    var stateColor: Color {
        switch agent.vmState {
        case .running: return Theme.green
        case .starting, .stopping: return Theme.amber
        case .failed: return Theme.red
        default: return Theme.secondary
        }
    }

    var subtitle: String {
        guard agent.vmState == .running else { return agent.vmState.rawValue }
        return agent.codexSignedIn ? "codex signed in" : "codex signed out"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(Theme.mono(10)).foregroundStyle(Theme.secondary)
            }
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

// MARK: - Fleet home (no agent selected)

struct FleetHomeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(hash: "agents", title: "Agents") {
            Card(title: "your agents", subtitle: "Each agent runs its own disposable Linux VM, populated from a pack") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.agents.isEmpty {
                        Text("No agents yet. Drop a pack folder into the packs directory and create one.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    } else {
                        ForEach(model.agents) { agent in
                            HStack {
                                AgentSidebarRow(agent: agent)
                                Spacer()
                                Text(agent.packID).font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                    HStack {
                        Button("New Agent") {
                            model.refresh()
                            model.showCreateSheet = true
                        }
                        .buttonStyle(AccentButtonStyle())
                        Spacer()
                        Text(model.statusLine).font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 6)
                }
            }
            Card(title: "packs directory") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.hub?.paths.packsDirectory.path ?? "—")
                        .font(Theme.mono(11)).foregroundStyle(Theme.green)
                        .textSelection(.enabled)
                    Text("A pack is a folder with pack.json, markdown (AGENTS.md, SOUL.md, MEMORY.seed.md), skills/, and tools/. Editing a pack updates its agents on their next turn.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

struct CreateAgentSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHash(title: "new agent")
            Text("Create an agent from a pack")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            if model.packs.isEmpty {
                Text("No packs found in\n\(model.hub?.paths.packsDirectory.path ?? "-")\n\nDrop a pack folder (e.g. guardian.pack) there and reopen this sheet.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
            } else {
                ForEach(model.packs) { pack in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("\(pack.packID) · v\(pack.version) · \(pack.dir)")
                                .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Button("Create") {
                            model.createAgent(fromPack: pack.dir)
                            model.showCreateSheet = false
                        }
                        .buttonStyle(AccentButtonStyle())
                    }
                    .padding(.vertical, 4)
                    if pack.id != model.packs.last?.id {
                        Divider().overlay(Theme.border)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close") { model.showCreateSheet = false }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Agent detail

struct AgentDetailView: View {
    @EnvironmentObject var model: AppModel
    let agentID: String
    @State private var draft = ""
    @State private var showControls = false

    var agent: AgentViewState? { model.agent(agentID) }

    var stateColor: Color {
        switch agent?.vmState {
        case .running: return Theme.green
        case .starting, .stopping: return Theme.amber
        case .failed: return Theme.red
        default: return Theme.secondary
        }
    }

    var body: some View {
        if let agent {
            VStack(spacing: 0) {
                header(agent)
                Divider().overlay(Theme.border)
                if showControls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            controlsCard(agent)
                            devicesCard(agent)
                            developerCard(agent)
                        }
                        .padding(20)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    chat(agent)
                }
            }
            .background(Theme.bg)
        } else {
            Text("Agent not found").foregroundStyle(Theme.secondary)
        }
    }

    private func header(_ agent: AgentViewState) -> some View {
        HStack(spacing: 10) {
            SectionHash(title: agent.name.lowercased())
            Chip(text: agent.vmState.rawValue, color: stateColor)
            if agent.bridgeConnected {
                Chip(text: agent.codexSignedIn ? "codex signed in" : "codex signed out",
                     color: agent.codexSignedIn ? Theme.green : Theme.amber)
            }
            if model.busyAgents.contains(agent.id) { ProgressView().controlSize(.small) }
            Spacer()
            Picker("", selection: $showControls) {
                Text("Chat").tag(false)
                Text("Manage").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Why Codex sign-in cannot start yet, or nil when it can.
    ///
    /// Ordered the way the agent actually comes up: the VM boots, the vsock
    /// bridge connects, then cloud-init finishes installing Codex. First boot
    /// takes roughly 40 seconds, so all three of these are states a user will
    /// see in normal use rather than error conditions.
    private func signInBlocker(_ agent: AgentViewState) -> String? {
        switch agent.vmState {
        case .notCreated, .stopped, .failed:
            return "Press Start first."
        case .stopping:
            return "Agent is stopping."
        case .starting:
            return "Waiting for the agent to boot…"
        case .running:
            if !agent.bridgeConnected { return "Waiting for the guest bridge…" }
            if !agent.codexInstalled { return "Installing Codex in the guest…" }
            return nil
        }
    }

    private func controlsCard(_ agent: AgentViewState) -> some View {
        Card(title: "sandbox", subtitle: "Pack \(agent.packID) · instance \(agent.id.prefix(8))") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Start") { model.startAgent(agent.id) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(model.busyAgents.contains(agent.id) || agent.vmState == .running)
                    Button("Stop") { model.stopAgent(agent.id) }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.busyAgents.contains(agent.id) || agent.vmState != .running)
                    Spacer()
                    Button("Reset") { model.resetAgent(agent.id) }
                        .buttonStyle(AccentButtonStyle(danger: true))
                        .disabled(model.busyAgents.contains(agent.id))
                        .help("Re-clone the disk and repopulate the workspace from the pack")
                }
                Divider().overlay(Theme.border)
                HStack(spacing: 8) {
                    if agent.codexSignedIn {
                        Chip(text: "codex \(agent.codexVersion)", color: Theme.green)
                    } else if model.signInProgress.contains(agent.id) {
                        ProgressView().controlSize(.small)
                        Button("Cancel sign-in") { model.cancelSignIn(agent.id) }
                            .buttonStyle(OutlineButtonStyle())
                    } else {
                        Button("Sign in Codex") { model.signInCodex(agent.id) }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(signInBlocker(agent) != nil)
                        // A greyed-out button still leaves "why?" unanswered,
                        // and every reason here is temporary — the guest is
                        // booting, or Codex is still installing. Say which.
                        if let blocker = signInBlocker(agent) {
                            Text(blocker)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    Spacer()
                }
                Text("Sign-in uses your ChatGPT account via the browser; the session lives only inside this agent's sandbox and is erased by Reset.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func devicesCard(_ agent: AgentViewState) -> some View {
        Card(title: "paired devices", subtitle: "Pairing is per agent — scanning this QR binds a phone to \(agent.name) only") {
            VStack(alignment: .leading, spacing: 10) {
                if agent.devices.isEmpty {
                    Text("No paired devices yet.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.secondary)
                } else {
                    ForEach(agent.devices) { device in
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
                                Button("Revoke") { model.revoke(device.id, agentID: agent.id) }
                                    .buttonStyle(AccentButtonStyle(danger: true))
                            }
                        }
                        .padding(.vertical, 4)
                        if device.id != agent.devices.last?.id {
                            Divider().overlay(Theme.border)
                        }
                    }
                }
                Button("Show pairing QR") { model.startPairing(agent.id) }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.top, 6)
            }
        }
    }

    private func developerCard(_ agent: AgentViewState) -> some View {
        Card(title: "developer access", subtitle: "Localhost-only SSH, tunneled over virtio — never exposed to your network") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Chip(text: model.devAccess[agent.id] == nil ? "locked" : "unlocked",
                         color: model.devAccess[agent.id] == nil ? Theme.secondary : Theme.amber)
                    Spacer()
                    Toggle("", isOn: Binding(get: { model.devAccess[agent.id] != nil },
                                             set: { _ in model.toggleDeveloperAccess(agent.id) }))
                        .toggleStyle(.switch)
                        .disabled(agent.vmState != .running)
                }
                Text("Unlocking SSH grants full control of this sandbox — including any credentials inside it — and bypasses agent tool approvals.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                if let info = model.devAccess[agent.id] {
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

    private func chat(_ agent: AgentViewState) -> some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.chats[agent.id] ?? []) { line in
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
                .onChange(of: (model.chats[agent.id] ?? []).last?.text) {
                    if let last = (model.chats[agent.id] ?? []).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                TextField("Message \(agent.name) — ! runs a raw command", text: $draft, axis: .vertical)
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
                    .disabled(draft.isEmpty || model.streamingAgents.contains(agent.id))
            }
            .padding(12)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.sendPrompt(text, to: agentID)
    }
}

// MARK: - Tailscale

struct TailscaleView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var statusColor: Color {
        switch model.tailnetStatus {
        case .ready: return Theme.green
        case .connecting, .launching: return Theme.amber
        case .needsLogin, .keyExpired: return Theme.amber
        case .error: return Theme.red
        case .stopped: return Theme.secondary
        }
    }

    var body: some View {
        Page(hash: "tailscale", title: "Tailscale") {
            Card(title: "embedded node", subtitle: "This Mac runs its own Tailscale node — no separate Tailscale app needed") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(text: model.tailnetStatus.label, color: statusColor)
                        Spacer()
                    }
                    KVRow(key: "machine name", value: model.tailnetInfo?.dnsName ?? "—")
                    KVRow(key: "tailnet", value: model.tailnetInfo?.tailnet ?? "—")
                    KVRow(key: "transport", value: model.transportMode)
                    KVRow(key: "tls", value: tlsDescription)
                    KVRow(key: "key expires", value: keyExpiryDescription)
                    KVRow(key: "mac fingerprint", value: model.macFingerprint)

                    if case .needsLogin = model.tailnetStatus {
                        Text("This Mac needs to join your tailnet. Sign in with the same Tailscale account your iPhone uses.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    if case .keyExpired = model.tailnetStatus {
                        Text("The node's Tailscale key expired. Reauthenticate to reconnect — or disable key expiry for this machine in the Tailscale admin console.")
                            .font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }

                    HStack(spacing: 8) {
                        if case .needsLogin = model.tailnetStatus {
                            Button("Sign in to Tailscale") { model.tailscaleSignIn() }
                                .buttonStyle(AccentButtonStyle())
                        } else if case .stopped = model.tailnetStatus {
                            Button("Connect") { model.tailscaleConnect() }
                                .buttonStyle(AccentButtonStyle())
                        } else {
                            Button("Reauthenticate") { model.tailscaleReauthenticate() }
                                .buttonStyle(OutlineButtonStyle())
                            Button("Disconnect") { model.tailscaleDisconnect() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        Button("Open Tailscale status") { model.openTailscaleAdmin() }
                            .buttonStyle(OutlineButtonStyle())
                        Spacer()
                        Button("Reset…") { confirmReset = true }
                            .buttonStyle(AccentButtonStyle(danger: true))
                    }
                    .padding(.top, 6)
                }
            }

            Card(title: "how the phone connects") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Install the official Tailscale app on your iPhone and sign in to the same tailnet.")
                    bullet("The agent service is reachable only inside your tailnet on TCP 443 — never on your LAN or the public internet.")
                    bullet("Tailnet access is transport only: phones still pair by QR code — per agent — and every message stays end-to-end encrypted.")
                    bullet("Tailscale is free for personal use (up to 6 users); commercial deployments need a paid plan.")
                }
            }
        }
        .confirmationDialog(
            "Reset Tailscale networking?",
            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Delete node identity and reset", role: .destructive) { model.tailscaleReset() }
        } message: {
            Text("This deletes the local Tailscale node identity. The Mac will disappear from your tailnet and you must sign in to Tailscale again. Paired phones stay paired but cannot reconnect until the node is re-authenticated.")
        }
    }

    private var tlsDescription: String {
        guard let info = model.tailnetInfo else { return "—" }
        return info.tailscaleTLS
            ? "Tailscale-issued certificate (tailnet HTTPS enabled)"
            : "self-signed certificate, pinned via pairing QR"
    }

    private var keyExpiryDescription: String {
        guard let expiry = model.tailnetInfo?.keyExpiry else { return "—" }
        return expiry.formatted(date: .abbreviated, time: .shortened)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(Theme.mono(12)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
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
            Text("Expires in 2 minutes · single use · pairs to this agent only\nMac fingerprint \(model.macFingerprint)")
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
