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
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)

                    // Machine-level rows live in the footer, not the agent
                    // list: they are about this Mac, no matter which agent.
                    VStack(alignment: .leading, spacing: 8) {
                        Divider().overlay(Theme.border)
                        sidebarFooterRow(tag: "tailscale", label: "this mac",
                                         dot: macFooterOK ? Theme.green : Theme.amber)
                        sidebarFooterRow(tag: "chariot", label: "account", dot: nil)
                        sidebarFooterRow(tag: "log", label: "activity", dot: Theme.green)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .background(Theme.sidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            } detail: {
                Group {
                    switch selection {
                    case "chariot": ChariotAccountView()
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

    /// Footer "this mac" dot mirrors the machine-wide wires: amber whenever
    /// the tailnet needs attention (the transport itself dying is fatal-screen
    /// territory, not a dot).
    private var macFooterOK: Bool {
        guard model.hub?.tailscaleEnabled == true else { return true }
        if case .ready = model.tailnetStatus { return true }
        return false
    }

    private func sidebarFooterRow(tag: String, label: String, dot: Color?) -> some View {
        Button {
            selection = tag
        } label: {
            HStack(spacing: 8) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                } else {
                    Circle().fill(Color.clear).frame(width: 7, height: 7)
                }
                Text(label)
                    .font(Theme.mono(12))
                    .foregroundStyle(selection == tag ? Theme.text : Theme.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}

struct AgentSidebarRow: View {
    @EnvironmentObject var model: AppModel
    let agent: AgentViewState

    var body: some View {
        let down = model.wiring(for: agent).down.count
        HStack(spacing: 9) {
            Circle()
                .fill(down > 0 ? Theme.amber : Theme.green)
                .frame(width: 8, height: 8)
            Text(agent.name).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(down > 0 ? "\(down) to wire" : "ready")
                .font(Theme.mono(10.5))
                .foregroundStyle(down > 0 ? Theme.amber : Theme.green)
        }
        .padding(.vertical, 3)
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
    @State private var showPackCreator = false

    var body: some View {
        Group {
            if model.agents.isEmpty {
                FirstAgentHero()
            } else {
                fleetPage
            }
        }
        .sheet(isPresented: $showPackCreator) {
            CreatePackSheet { _ in model.refresh() }
        }
    }

    private var fleetPage: some View {
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
            Card(title: "packs") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.packs.isEmpty {
                        Text("No packs yet.").font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                    } else {
                        ForEach(model.packs) { pack in
                            HStack {
                                Text(pack.name).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text("v\(pack.version) · \(pack.dir)")
                                    .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                                Spacer()
                            }
                        }
                    }
                    Text(model.hub?.paths.packsDirectory.path ?? "—")
                        .font(Theme.mono(11)).foregroundStyle(Theme.green)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    Text("A pack is a folder with pack.json, markdown (AGENTS.md, SOUL.md, MEMORY.seed.md), skills/, and tools/. Editing a pack updates its agents on their next turn.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 8) {
                        Button("New Pack") { showPackCreator = true }
                            .buttonStyle(AccentButtonStyle())
                        Button("Reveal in Finder") { model.revealPacksDirectory() }
                            .buttonStyle(OutlineButtonStyle())
                        Spacer()
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

/// Empty-fleet hero: what an agent is and the three steps to a working one.
struct FirstAgentHero: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("◇")
                .font(Theme.mono(26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.accent.opacity(0.5), lineWidth: 2))
            Text("Create your first agent")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 20)
            Text("A pack in its own sandbox, driven by a model you pick. You'll see exactly what needs wiring up — most of it once, ever.")
                .font(.system(size: 14))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
                .padding(.top, 12)
            Button("New Agent") {
                model.refresh()
                model.showCreateSheet = true
            }
            .buttonStyle(AccentButtonStyle())
            .padding(.top, 24)

            HStack(spacing: 0) {
                heroStep("1 · create", "Pack, harness, power.")
                Divider().overlay(Theme.border)
                heroStep("2 · wire up", "A few sign-ins, shown as a diagram.")
                Divider().overlay(Theme.border)
                heroStep("3 · pair", "Scan a QR. Chat anywhere.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            .padding(.top, 36)
        }
        .frame(maxWidth: 460)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    private func heroStep(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.mono(11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CreateAgentSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedPack: String?
    @State private var showPackCreator = false
    @State private var harness: HarnessKind = .codex
    @State private var power: PowerSourceKind = .chatgpt
    @State private var modelOverride = ""
    @State private var localBaseURL = ""

    private var chariotSignedIn: Bool {
        if case .signedIn = model.chariotSignIn { return true }
        return false
    }

    /// ChatGPT is codex-only; when the harness changes away from codex, the
    /// power picker moves off it rather than offering an invalid combination.
    private var availablePowers: [PowerSourceKind] {
        harness.supportsChatGPTLogin ? [.chatgpt, .chariot, .local] : [.chariot, .local]
    }

    private func powerLabel(_ power: PowerSourceKind) -> String {
        switch power {
        case .chatgpt: return "ChatGPT sign-in"
        case .chariot: return "Chariot account"
        case .local: return "Local model"
        }
    }

    private var createBlocker: String? {
        guard selectedPack != nil else { return "Choose a pack." }
        if power == .chariot && !chariotSignedIn {
            return "Sign in to your Chariot account first (sidebar → Chariot Account)."
        }
        if power == .local {
            let base = localBaseURL.isEmpty ? model.localModelDefaultBaseURL : localBaseURL
            if base.isEmpty { return "Enter a local server URL (e.g. http://127.0.0.1:11434/v1)." }
            let modelName = modelOverride.isEmpty ? model.localModelDefaultModel : modelOverride
            if modelName.isEmpty && harness.defaultModel == nil { return "Enter a model name." }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHash(title: "new agent")
            Text("Create an agent")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            if model.packs.isEmpty {
                Text("No packs found in\n\(model.hub?.paths.packsDirectory.path ?? "-")")
                    .font(Theme.mono(11)).foregroundStyle(Theme.secondary)
                Button("Create a pack") { showPackCreator = true }
                    .buttonStyle(AccentButtonStyle())
            } else {
                HStack {
                    Text("PACK").font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("New Pack…") { showPackCreator = true }
                        .buttonStyle(OutlineButtonStyle())
                }
                ForEach(model.packs) { pack in
                    Button {
                        selectedPack = pack.dir
                    } label: {
                        HStack {
                            Image(systemName: selectedPack == pack.dir ? "circle.inset.filled" : "circle")
                                .foregroundStyle(selectedPack == pack.dir ? Theme.accent : Theme.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("\(pack.packID) · v\(pack.version) · \(pack.dir)")
                                    .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }

                Divider().overlay(Theme.border)
                Text("HARNESS").font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                Picker("", selection: $harness) {
                    ForEach(HarnessKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: harness) {
                    if !availablePowers.contains(power) { power = .chariot }
                }

                Text("POWERED BY").font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                Picker("", selection: $power) {
                    ForEach(availablePowers, id: \.self) { kind in
                        Text(powerLabel(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch power {
                case .chatgpt:
                    Text("You'll sign in with your ChatGPT account after the agent boots; the credential lives only inside its sandbox.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                case .chariot:
                    Text(chariotSignedIn
                         ? "Model calls are metered to your Chariot account. Leave the model empty to use your account default."
                         : "Sign in to your Chariot account first (sidebar → Chariot Account).")
                        .font(.system(size: 11))
                        .foregroundStyle(chariotSignedIn ? Theme.secondary : Theme.amber)
                    TextField("model override (optional, e.g. openai/gpt-mini-latest)", text: $modelOverride)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                case .local:
                    TextField("server URL — default: \(model.localModelDefaultBaseURL.isEmpty ? "none set" : model.localModelDefaultBaseURL)",
                              text: $localBaseURL)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                    TextField("model — default: \(model.localModelDefaultModel.isEmpty ? (harness.defaultModel ?? "none set") : model.localModelDefaultModel)",
                              text: $modelOverride)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                    Text("Point this at any OpenAI-compatible server on your Mac (Ollama, LM Studio, llama-server). The guest reaches it only through the app's broker — it stays bound to localhost.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            HStack {
                if let blocker = createBlocker, selectedPack != nil {
                    Text(blocker).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                }
                Spacer()
                Button("Close") { model.showCreateSheet = false }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    guard let pack = selectedPack else { return }
                    model.createAgent(fromPack: pack,
                                      harness: harness,
                                      powerSource: power,
                                      model: modelOverride.isEmpty ? nil : modelOverride,
                                      localBaseURL: localBaseURL.isEmpty ? nil : localBaseURL)
                    model.showCreateSheet = false
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(createBlocker != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPackCreator) {
            // A pack made mid-flow is what the user wants to use: refresh the
            // list and preselect it.
            CreatePackSheet { dir in
                model.refresh()
                selectedPack = dir
            }
        }
    }
}

// MARK: - Agent detail

struct AgentDetailView: View {
    @EnvironmentObject var model: AppModel
    let agentID: String
    @State private var draft = ""
    @State private var showControls = false
    @State private var selectedWire: WireID = .tailnet
    /// Unsaved model-override edit; nil = showing the persisted value.
    @State private var modelDraft: String?

    init(agentID: String, manage: Bool = false, wire: WireID = .tailnet) {
        self.agentID = agentID
        _showControls = State(initialValue: manage)
        _selectedWire = State(initialValue: wire)
    }

    var agent: AgentViewState? { model.agent(agentID) }

    var body: some View {
        if let agent {
            let wires = model.wiring(for: agent)
            VStack(spacing: 0) {
                header(agent, wires: wires)
                if showControls {
                    manage(agent, wires: wires)
                } else {
                    chat(agent, wires: wires)
                }
            }
            .background(Theme.bg)
        } else {
            Text("Agent not found").foregroundStyle(Theme.secondary)
        }
    }

    private func header(_ agent: AgentViewState, wires: [WireInfo]) -> some View {
        let down = wires.down.count
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                SectionHash(title: agent.name.lowercased())
                HStack(spacing: 11) {
                    Text(agent.name)
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Chip(text: down > 0 ? "\(down) wire\(down > 1 ? "s" : "") down" : "ready",
                         color: down > 0 ? Theme.amber : Theme.green)
                    if model.busyAgents.contains(agent.id) { ProgressView().controlSize(.small) }
                }
            }
            Spacer()
            HStack(spacing: 0) {
                headerTab("Chat", active: !showControls) { showControls = false }
                headerTab("Manage", active: showControls) { showControls = true }
            }
            .padding(3)
            .background(Color(red: 0.11, green: 0.11, blue: 0.129))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 30)
        .padding(.top, 22)
    }

    private func headerTab(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(active ? .white : Theme.text.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(active ? Theme.accent : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Chat

    private func chat(_ agent: AgentViewState, wires: [WireInfo]) -> some View {
        let chatReady = wires.chatReady
        return VStack(spacing: 0) {
            WiringStrip(wires: wires) {
                selectedWire = wires.down.first?.id ?? .tailnet
                showControls = true
            }
            .padding(.horizontal, 30)
            .padding(.top, 16)
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
            if !chatReady {
                Text("\(agent.name) can't reply until its wiring is complete.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
            }
            HStack(spacing: 10) {
                TextField(chatReady ? "Message \(agent.name) — ! runs a raw command"
                                    : "Finish wiring to start chatting…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .onSubmit(send)
                    .disabled(!chatReady)
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(chatReady && !draft.isEmpty ? Theme.accent : Color(red: 0.165, green: 0.165, blue: 0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!chatReady || draft.isEmpty || model.streamingAgents.contains(agent.id))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 30)
            .padding(.bottom, 24)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.sendPrompt(text, to: agentID)
    }

    // MARK: Manage

    private func manage(_ agent: AgentViewState, wires: [WireInfo]) -> some View {
        var wire = wires.first { $0.id == selectedWire } ?? wires[0]
        // While the brokered browser dance runs, the extras row below owns the
        // power node's UI (spinner + cancel); a second live button would race it.
        let signingIn = wire.id == .power && model.signInProgress.contains(agent.id)
        if signingIn { wire.action = nil }
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WiringDiagram(wires: wires, selected: $selectedWire)
                WireDetailCard(wire: wire,
                               actionBlocker: actionBlocker(for: wire, agent: agent),
                               onAction: { perform($0, agent: agent) }) {
                    wireExtras(for: wire, agent: agent, signingIn: signingIn)
                }
                manageFooter(agent)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionBlocker(for wire: WireInfo, agent: AgentViewState) -> String? {
        switch wire.action?.kind {
        case .codexSignIn:
            return agent.signInBlocker
        case .startSandbox:
            return model.busyAgents.contains(agent.id) ? "working…" : nil
        default:
            return nil
        }
    }

    private func perform(_ action: WireAction, agent: AgentViewState) {
        switch action {
        case .pairQR: model.startPairing(agent.id)
        case .tailscaleSignIn: model.tailscaleSignIn()
        case .tailscaleReauth: model.tailscaleReauthenticate()
        case .tailscaleConnect: model.tailscaleConnect()
        case .startSandbox: model.startAgent(agent.id)
        case .codexSignIn: model.signInCodex(agent.id)
        case .chariotSignIn: model.chariotAccountSignIn()
        }
    }

    /// Node-specific rows under the detail description. Everything the old
    /// Manage cards could do survives here, attached to the node it belongs to.
    @ViewBuilder
    private func wireExtras(for wire: WireInfo, agent: AgentViewState, signingIn: Bool) -> some View {
        switch wire.id {
        case .phone:
            phoneExtras(agent)
        case .sandbox:
            sandboxExtras(agent)
        case .power:
            powerExtras(agent, signingIn: signingIn)
        case .tailnet, .mac:
            EmptyView()
        }
    }

    @ViewBuilder
    private func phoneExtras(_ agent: AgentViewState) -> some View {
        if !agent.devices.isEmpty {
            Divider().overlay(Theme.border)
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
            }
            Button("Show pairing QR") { model.startPairing(agent.id) }
                .buttonStyle(OutlineButtonStyle())
        }
    }

    @ViewBuilder
    private func sandboxExtras(_ agent: AgentViewState) -> some View {
        if agent.vmState == .running {
            HStack(spacing: 10) {
                Button("Stop sandbox") { model.stopAgent(agent.id) }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(model.busyAgents.contains(agent.id))
                Spacer()
            }
        }
        Divider().overlay(Theme.border)
        HStack {
            Text("developer ssh")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Chip(text: model.devAccess[agent.id] == nil ? "locked" : "unlocked",
                 color: model.devAccess[agent.id] == nil ? Theme.secondary : Theme.amber)
            Spacer()
            Toggle("", isOn: Binding(get: { model.devAccess[agent.id] != nil },
                                     set: { _ in model.toggleDeveloperAccess(agent.id) }))
                .toggleStyle(.switch)
                .disabled(agent.vmState != .running)
        }
        if let info = model.devAccess[agent.id] {
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
                Button("Copy instructions for \(agent.harness.displayName)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.instructions, forType: .string)
                }
                .buttonStyle(OutlineButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func powerExtras(_ agent: AgentViewState, signingIn: Bool) -> some View {
        if signingIn {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Complete the ChatGPT sign-in in your browser…")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.secondary)
                Button("Cancel sign-in") { model.cancelSignIn(agent.id) }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        if agent.agentReady && !agent.agentVersion.isEmpty {
            Text(agent.agentVersion).font(Theme.mono(11)).foregroundStyle(Theme.secondary)
        }
        if agent.powerSource != .chatgpt {
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                TextField("model — empty = default", text: Binding(
                    get: { modelDraft ?? agent.model },
                    set: { modelDraft = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.mono(11))
                    .frame(maxWidth: 320)
                Button("Apply") {
                    model.setAgentModel(agent.id, model: modelDraft ?? agent.model)
                    modelDraft = nil
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(modelDraft == nil || modelDraft == agent.model)
                Spacer()
            }
            Text("A model change applies from the agent's next start.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private func manageFooter(_ agent: AgentViewState) -> some View {
        HStack(spacing: 14) {
            Text("ssh: \(model.devAccess[agent.id] == nil ? "locked" : "unlocked")")
            Text("·")
            Text("instance \(agent.id.prefix(8))")
            Spacer()
            Button("Reset") { model.resetAgent(agent.id) }
                .buttonStyle(AccentButtonStyle(danger: true))
                .disabled(model.busyAgents.contains(agent.id))
                .help("Re-clone the disk and repopulate the workspace from the pack")
        }
        .font(Theme.mono(12))
        .foregroundStyle(Theme.secondary.opacity(0.8))
    }
}

// MARK: - Chariot account

struct ChariotAccountView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(hash: "chariot", title: "Chariot Account") {
            Card(title: "account",
                 subtitle: "Powers agents through the Chariot model proxy, metered to your account") {
                VStack(alignment: .leading, spacing: 10) {
                    switch model.chariotSignIn {
                    case .signedOut:
                        Text("Not signed in. Agents created with the Chariot power source need this account link.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Button("Sign in to Chariot") { model.chariotAccountSignIn() }
                            .buttonStyle(AccentButtonStyle())
                    case .pending(let approveURL):
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for browser approval…")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        }
                        Text(approveURL)
                            .font(Theme.mono(10)).foregroundStyle(Theme.green)
                            .textSelection(.enabled)
                        HStack {
                            Button("Reopen approval page") {
                                if let url = URL(string: approveURL) { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(OutlineButtonStyle())
                            Button("Start over") { model.chariotAccountSignIn() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                    case .signedIn(let email):
                        HStack(spacing: 8) {
                            Chip(text: "signed in", color: Theme.green)
                            Text(email ?? "")
                                .font(Theme.mono(12)).foregroundStyle(Theme.text)
                            Spacer()
                            Button("Sign out") { model.chariotAccountSignOut() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        Text("New chariot-powered agents register under this account; each gets its own metered proxy token, stored only on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    case .failed(let message):
                        Text(message).font(.system(size: 12)).foregroundStyle(Theme.red)
                        Button("Try again") { model.chariotAccountSignIn() }
                            .buttonStyle(AccentButtonStyle())
                    }
                }
            }

            Card(title: "local model defaults",
                 subtitle: "Used by local-powered agents that don't set their own server or model") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("server URL, e.g. http://127.0.0.1:11434/v1",
                              text: $model.localModelDefaultBaseURL)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                    TextField("model, e.g. muse-glimmer:30b",
                              text: $model.localModelDefaultModel)
                        .textFieldStyle(.roundedBorder).font(Theme.mono(11))
                    HStack(spacing: 8) {
                        Button("Save") { model.saveLocalModelDefaults() }
                            .buttonStyle(AccentButtonStyle())
                        Button("Test connection") { model.testLocalModelServer() }
                            .buttonStyle(OutlineButtonStyle())
                        Spacer()
                        Text(model.statusLine).font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                    }
                    Text("Run any OpenAI-compatible server (Ollama, LM Studio, llama-server). It can stay bound to localhost — guests reach it only through the app's vsock broker.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }
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
