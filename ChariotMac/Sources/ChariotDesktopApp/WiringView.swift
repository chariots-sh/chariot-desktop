import SwiftUI
import ChariotCore

// The wiring model: everything between the phone and a working agent, drawn
// as five nodes — Phone → Tailnet → This Mac → Sandbox → Power. Each node is
// either wired (ok) or needs setup (warn), and warn nodes carry the one
// action that fixes them. Chat and the sidebar summarize the same five wires.

enum WireID: String, CaseIterable, Identifiable {
    case phone, tailnet, mac, sandbox, power
    var id: String { rawValue }
}

enum WireAction {
    case pairQR
    case tailscaleSignIn
    case tailscaleReauth
    case tailscaleConnect
    case startSandbox
    case codexSignIn
    case chariotSignIn
}

struct WireInfo: Identifiable {
    let id: WireID
    /// Diagram card label ("Phone", "Codex").
    let label: String
    let icon: String
    /// Detail card title ("codex sign-in").
    let title: String
    let scope: String
    let machineWide: Bool
    let ok: Bool
    /// Short status under the diagram card ("paired" / "needs login").
    let statusText: String
    let desc: String
    var action: (label: String, kind: WireAction)? = nil
    /// Small print next to the action button ("covers every agent").
    var note: String = ""
    /// Shown as "✓ …" when the wire is up.
    var doneNote: String = ""
    /// Blocks chat when down. Phone and tailnet are remote-access wires:
    /// they count as "to wire" but chatting from this Mac works without them.
    var requiredForChat: Bool = true
}

extension AppModel {
    /// The five wires for one agent, in diagram order.
    func wiring(for agent: AgentViewState) -> [WireInfo] {
        let name = agent.name
        let pairedCount = agent.devices.filter { !$0.revoked }.count

        let phone = WireInfo(
            id: .phone, label: "Phone", icon: "iphone", title: "phone",
            scope: "this agent", machineWide: false,
            ok: pairedCount > 0,
            statusText: pairedCount > 0 ? "paired" : "not paired",
            desc: "Paired to \(name) by QR — that phone talks to \(name) only. End-to-end encrypted; Tailscale never sees message content.",
            action: pairedCount > 0 ? nil : ("Show pairing QR", .pairQR),
            note: "per agent",
            doneNote: pairedCount == 1 ? "paired to \(name)" : "\(pairedCount) devices paired",
            requiredForChat: false)

        let tailnet: WireInfo
        let tailnetDesc = "Optional. One sign-in with the account your iPhone uses, and every agent is reachable away from home — TCP 443 inside your tailnet, never your LAN or the internet."
        if hub?.tailscaleEnabled != true {
            tailnet = WireInfo(
                id: .tailnet, label: "Tailnet", icon: "globe", title: "tailnet",
                scope: "machine-wide · one-time", machineWide: true,
                ok: true, statusText: "local mode", desc: tailnetDesc,
                doneNote: "loopback dev mode — remote access disabled",
                requiredForChat: false)
        } else {
            let (ok, status, action): (Bool, String, (String, WireAction)?)
            switch tailnetStatus {
            case .ready: (ok, status, action) = (true, "connected", nil)
            case .needsLogin: (ok, status, action) = (false, "needs login", ("Sign in to Tailscale", .tailscaleSignIn))
            case .keyExpired: (ok, status, action) = (false, "key expired", ("Reauthenticate", .tailscaleReauth))
            case .stopped: (ok, status, action) = (false, "stopped", ("Connect", .tailscaleConnect))
            case .launching, .connecting: (ok, status, action) = (false, "connecting…", nil)
            case .error: (ok, status, action) = (false, "error", ("Connect", .tailscaleConnect))
            }
            tailnet = WireInfo(
                id: .tailnet, label: "Tailnet", icon: "globe", title: "tailnet",
                scope: "machine-wide · one-time", machineWide: true,
                ok: ok, statusText: status, desc: tailnetDesc,
                action: action.map { (label: $0.0, kind: $0.1) },
                note: "covers every agent",
                doneNote: "connected — all agents reachable remotely",
                requiredForChat: false)
        }

        let macOK = hub != nil
        let mac = WireInfo(
            id: .mac, label: "This Mac", icon: "desktopcomputer", title: "this mac",
            scope: "machine-wide", machineWide: true,
            ok: macOK,
            statusText: macOK ? "transport up" : "down",
            desc: "Runs the transport on 127.0.0.1:\(hub?.transportPort ?? 8787) and the embedded Tailscale node. Nothing to configure here.",
            doneNote: "transport running")

        let sshLocked = devAccess[agent.id] == nil
        let sandboxDesc = "\(agent.packID) · \(agent.harness.displayName) harness · instance \(agent.id.prefix(8)). SSH is \(sshLocked ? "locked" : "unlocked"); unlocking grants full control and bypasses tool approvals."
        let sandbox: WireInfo
        switch agent.vmState {
        case .running where agent.bridgeConnected:
            sandbox = WireInfo(id: .sandbox, label: "Sandbox", icon: "cube", title: "sandbox",
                               scope: "this agent", machineWide: false,
                               ok: true, statusText: "running", desc: sandboxDesc,
                               doneNote: "running")
        case .running, .starting:
            sandbox = WireInfo(id: .sandbox, label: "Sandbox", icon: "cube", title: "sandbox",
                               scope: "this agent", machineWide: false,
                               ok: false, statusText: "booting…", desc: sandboxDesc)
        case .stopping:
            sandbox = WireInfo(id: .sandbox, label: "Sandbox", icon: "cube", title: "sandbox",
                               scope: "this agent", machineWide: false,
                               ok: false, statusText: "stopping…", desc: sandboxDesc)
        case .notCreated, .stopped, .failed:
            sandbox = WireInfo(id: .sandbox, label: "Sandbox", icon: "cube", title: "sandbox",
                               scope: "this agent", machineWide: false,
                               ok: false,
                               statusText: agent.vmState == .failed ? "failed" : "stopped",
                               desc: sandboxDesc,
                               action: ("Start sandbox", .startSandbox),
                               note: "boots in ~40 s")
        }

        let power: WireInfo
        switch agent.powerSource {
        case .chatgpt:
            power = WireInfo(
                id: .power, label: "Codex", icon: "powerplug", title: "codex sign-in",
                scope: "this agent", machineWide: false,
                ok: agent.agentReady,
                statusText: agent.agentReady ? "signed in" : "signed out",
                desc: "\(name) is powered by your ChatGPT account. The session lives only inside this sandbox and is erased by Reset.",
                action: agent.agentReady ? nil : ("Sign in Codex", .codexSignIn),
                note: "erased by Reset",
                doneNote: "signed in — session lives in this sandbox only")
        case .chariot:
            let accountSignedIn: Bool
            if case .signedIn = chariotSignIn { accountSignedIn = true } else { accountSignedIn = false }
            power = WireInfo(
                id: .power, label: "Chariot", icon: "powerplug", title: "chariot account",
                scope: "this agent", machineWide: false,
                ok: agent.agentReady,
                statusText: agent.agentReady ? "ready" : (accountSignedIn ? "not ready" : "needs sign-in"),
                desc: "Model calls run through your Chariot account's metered proxy; the per-agent token stays on this Mac.",
                action: accountSignedIn ? nil : ("Sign in to Chariot", .chariotSignIn),
                doneNote: "metered to your Chariot account")
        case .local:
            power = WireInfo(
                id: .power, label: "Local", icon: "powerplug", title: "local model",
                scope: "this agent", machineWide: false,
                ok: agent.agentReady,
                statusText: agent.agentReady ? "ready" : "not ready",
                desc: "Model calls go to your local server through the app's broker — the server can stay bound to localhost.",
                doneNote: "connected to your local server")
        }

        return [phone, tailnet, mac, sandbox, power]
    }
}

extension Array where Element == WireInfo {
    var down: [WireInfo] { filter { !$0.ok } }
    /// "2 wires down — tailnet, codex sign-in" / "all wired"
    var stripText: String {
        let d = down
        guard !d.isEmpty else { return "all wired" }
        return "\(d.count) wire\(d.count > 1 ? "s" : "") down — \(d.map(\.title).joined(separator: ", "))"
    }
    /// Chat is possible: every wire the local transport depends on is up.
    var chatReady: Bool { down.allSatisfy { !$0.requiredForChat } }
}

extension AgentViewState {
    /// Why the power sign-in is not usable yet, or nil when it is.
    /// Ordered the way the agent actually comes up: the VM boots, the vsock
    /// bridge connects, then cloud-init finishes installing the harness.
    var signInBlocker: String? {
        let harnessName = harness.displayName
        switch vmState {
        case .notCreated, .stopped, .failed:
            return "Start the sandbox first."
        case .stopping:
            return "Agent is stopping."
        case .starting:
            return "Waiting for the agent to boot…"
        case .running:
            if !bridgeConnected { return "Waiting for the guest bridge…" }
            if !agentInstalled {
                if let error = agentInstallError, !error.isEmpty {
                    return "\(harnessName) install failed, retrying: \(error)"
                }
                return "Installing \(harnessName) in the guest…"
            }
            return nil
        }
    }
}

// MARK: - Shared atoms

/// 9pt status dot; warn dots pulse like the prototype's cpulse keyframes.
struct WireDot: View {
    let ok: Bool
    var size: CGFloat = 9
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(ok ? Theme.green : Theme.amber)
            .frame(width: size, height: size)
            .opacity(ok ? 1 : (dim ? 0.35 : 1))
            .animation(ok ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: dim)
            .onAppear { dim = true }
    }
}

// MARK: - Chat wiring strip

struct WiringStrip: View {
    let wires: [WireInfo]
    let onFix: () -> Void

    private var hasWarn: Bool { !wires.down.isEmpty }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                ForEach(Array(wires.enumerated()), id: \.element.id) { index, wire in
                    WireDot(ok: wire.ok)
                        .help(wire.label)
                    if index < wires.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 16, height: 1.5)
                    }
                }
            }
            Text(wires.stripText)
                .font(Theme.mono(12))
                .foregroundStyle(hasWarn ? Theme.amber : Theme.secondary)
                .lineLimit(1)
            Spacer()
            if hasWarn {
                Button("Fix in Manage →", action: onFix)
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, hasWarn ? 8 : 10)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .stroke(hasWarn ? Theme.amber.opacity(0.35) : Theme.border, lineWidth: 1))
    }
}

// MARK: - Manage: node diagram

struct WiringDiagram: View {
    let wires: [WireInfo]
    @Binding var selected: WireID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(wires.enumerated()), id: \.element.id) { index, wire in
                    nodeCard(wire)
                    if index < wires.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.14))
                            .frame(height: 1.5)
                            .frame(width: 26)
                    }
                }
            }
            HStack(spacing: 14) {
                legend(color: Theme.green, text: "ready")
                legend(color: Theme.amber, text: "needs setup")
                Spacer()
                Text("click a node")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
            }
            .padding(.top, 11)
            .overlay(alignment: .top) {
                Divider().overlay(Theme.border.opacity(0.6))
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    private func nodeCard(_ wire: WireInfo) -> some View {
        let color = wire.ok ? Theme.green : Theme.amber
        return Button {
            selected = wire.id
        } label: {
            VStack(spacing: 0) {
                Image(systemName: wire.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(color)
                    .frame(height: 20)
                Text(wire.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 7)
                Text(wire.statusText)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(color)
                    .padding(.top, 2)
                    .lineLimit(1)
            }
            .padding(.top, 14)
            .padding(.bottom, 11)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.1), lineWidth: 1))
            .overlay {
                if selected == wire.id {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.accent, lineWidth: 2)
                        .padding(-3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.mono(10.5)).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - Manage: selected-node detail

struct WireDetailCard<Extras: View>: View {
    let wire: WireInfo
    /// Disabled reason for the action button; nil = actionable now.
    var actionBlocker: String?
    let onAction: (WireAction) -> Void
    /// Node-specific rows under the description (device list, model field…).
    @ViewBuilder var extras: Extras

    private var statusColor: Color { wire.ok ? Theme.green : Theme.amber }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(wire.title)
                    .font(Theme.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Chip(text: wire.statusText, color: statusColor)
                Spacer()
                Chip(text: wire.scope,
                     color: wire.machineWide ? Theme.accent.opacity(0.9) : Theme.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 13) {
                Text(wire.desc)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 680, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !wire.ok, let action = wire.action {
                    HStack(spacing: 10) {
                        Button(action.label) { onAction(action.kind) }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(actionBlocker != nil)
                        Text(actionBlocker ?? wire.note)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if wire.ok && !wire.doneNote.isEmpty {
                    Text("✓ \(wire.doneNote)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.green)
                }
                extras
            }
            .padding(.horizontal, 20)
            .padding(.top, 15)
            .padding(.bottom, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(wire.ok ? Theme.border : Theme.amber.opacity(0.4), lineWidth: 1))
    }
}
