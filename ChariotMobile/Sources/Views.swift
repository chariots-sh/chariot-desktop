import SwiftUI
import VisionKit
#if canImport(AgentLinkKit)
import AgentLinkKit
#endif

struct WelcomeView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Chariot").font(.largeTitle).bold()
            Text("Chat with the coding agent running in the sandbox on your Mac.\n\nYour Mac and this device should be signed into the same iCloud account. Messages are end-to-end encrypted — the mailbox only ever sees ciphertext.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                model.phase = .scanner
            } label: {
                Label("Pair with a Mac", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }
}

struct ScannerView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var pasted = ""
    @State private var scannerAvailable = DataScannerViewController.isSupported && DataScannerViewController.isAvailable

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if scannerAvailable {
                    QRScannerRepresentable { payload in
                        model.pair(payloadJSON: payload)
                    }
                    .frame(maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                    Text("Point the camera at the QR code shown by Chariot Desktop.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Camera not available",
                                           systemImage: "camera.badge.ellipsis",
                                           description: Text("Paste the pairing payload below instead (Copy payload on the Mac)."))
                }
                // Image-import/paste fallback (design §13.6) — also the path
                // used on the simulator, which has no camera.
                VStack(spacing: 8) {
                    TextField("Paste pairing payload", text: $pasted, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3, reservesSpace: true)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Pair") {
                        model.pair(payloadJSON: pasted)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pasted.isEmpty)
                }
                .padding(.horizontal)
                Spacer()
            }
            .navigationTitle("Scan to pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { model.phase = .welcome }
                }
            }
        }
    }
}

/// Live QR scanning via DataScannerViewController (design §13.6): QR-only,
/// stops after the first recognized code so repeated frames cannot trigger
/// multiple pairing attempts.
struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onPayload: (String) -> Void
        private var consumed = false

        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !consumed else { return }
            for item in added {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    consumed = true
                    scanner.stopScanning()
                    onPayload(payload)
                    return
                }
            }
        }
    }
}

struct PairingProgressView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large)
            Text(model.pairingStatus).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }
}

struct RevokedView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.shield").font(.system(size: 56)).foregroundStyle(.red)
            Text("Access revoked").font(.title2).bold()
            Text("The Mac revoked this device. Messages can no longer be decrypted. Pair again from Chariot Desktop to reconnect.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
            Button("Unpair and start over", role: .destructive) { model.unpair() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ConversationView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.chat) { message in
                                ChatBubble(message: message).id(message.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: model.chat.last?.text) {
                        if let last = model.chat.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Message — ! runs a command", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("composer")
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("sendButton")
                }
                .padding(10)
            }
            .navigationTitle(model.macOnline ? "Agent" : "Agent (Mac offline)")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.send(text)
    }
}

struct ChatBubble: View {
    let message: PhoneChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(message.role == "agent" ? .system(.footnote, design: .monospaced) : .body)
                    .textSelection(.enabled)
                if message.pending {
                    Label("Queued", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            if message.role != "user" { Spacer(minLength: 48) }
        }
    }

    private var background: Color {
        switch message.role {
        case "user": return Color.accentColor.opacity(0.25)
        case "system": return Color.orange.opacity(0.15)
        default: return Color(.secondarySystemBackground)
        }
    }
}

struct ConnectionDetailsView: View {
    @EnvironmentObject var model: PhoneModel
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section("Mac") {
                    LabeledContent("Name", value: model.record?.macDisplayName ?? "—")
                    LabeledContent("Status", value: model.macOnline ? "Online" : "Offline")
                    LabeledContent("Sandbox", value: model.sandboxState)
                    LabeledContent("Mac fingerprint", value: model.record?.macIdentity.fingerprint ?? "—")
                        .font(.footnote.monospaced())
                }
                Section("Connection") {
                    LabeledContent("Mode", value: model.connectionMode)
                    LabeledContent("Epoch", value: "\(model.record?.epoch ?? 0)")
                    LabeledContent("Last push received",
                                   value: model.lastPushAt?.formatted(date: .omitted, time: .standard) ?? "never")
                    LabeledContent("Last activity",
                                   value: model.lastActivity?.formatted(date: .omitted, time: .standard) ?? "—")
                    LabeledContent("Paired",
                                   value: model.record?.pairedAt.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
                Section("This device") {
                    LabeledContent("Fingerprint", value: model.fingerprint)
                        .font(.footnote.monospaced())
                }
                Section {
                    Button("Remove this Mac", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Removing deletes local keys and messages. The Mac can also revoke this device remotely.")
                }
            }
            .navigationTitle("Connection")
            .confirmationDialog("Remove this Mac and delete local keys?",
                                isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { model.unpair() }
            }
        }
    }
}
