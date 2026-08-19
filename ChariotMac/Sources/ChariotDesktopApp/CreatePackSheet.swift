import SwiftUI
import ChariotCore

/// "New Pack" sheet: builds a pack folder from typed-in content — the in-app
/// alternative to hand-assembling one in Finder. It covers the markdown that
/// defines an agent (instructions, personality, seed memory); richer
/// structure (tools/, skills/, VM sizing) remains a file edit in the created
/// folder, which the packs card can reveal.
struct CreatePackSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Folder name of the pack that was just created — lets the New Agent
    /// sheet preselect it.
    var onCreated: ((String) -> Void)? = nil

    @State private var name = ""
    @State private var instructions = ""
    @State private var soul = ""
    @State private var seedMemory = ""

    private var createBlocker: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the pack a name."
        }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Write the agent's instructions."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHash(title: "new pack")
            Text("Create a pack")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            Text("A pack is what an agent is made of. Every agent created from it gets these files in its sandbox — edits here land on the agent's next turn.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)

            fieldHeader("NAME")
            TextField("e.g. Health Coach", text: $name)
                .textFieldStyle(.roundedBorder).font(.system(size: 13))

            fieldHeader("INSTRUCTIONS — AGENTS.md",
                        detail: "who the agent is, what it does, how it answers")
            editor($instructions, height: 170)
            if instructions.isEmpty {
                Button("Start from a template") { instructions = Self.template(for: name) }
                    .buttonStyle(OutlineButtonStyle())
            }

            fieldHeader("PERSONALITY — SOUL.md", detail: "optional · tone and character")
            editor($soul, height: 60)

            fieldHeader("SEED MEMORY — MEMORY.seed.md",
                        detail: "optional · written once on a fresh instance; the agent owns it afterwards")
            editor($seedMemory, height: 60)

            HStack {
                if let blocker = createBlocker {
                    Text(blocker).font(Theme.mono(10)).foregroundStyle(Theme.amber)
                } else {
                    Text("Add tools/ and skills/ later by editing the created folder.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Create Pack") {
                    if let dir = model.createPack(name: name, instructions: instructions,
                                                  soul: soul, seedMemory: seedMemory) {
                        onCreated?(dir)
                        dismiss()
                    }
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(createBlocker != nil)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func fieldHeader(_ label: String, detail: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.mono(10)).foregroundStyle(Theme.secondary)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(Theme.secondary.opacity(0.7))
            }
        }
        .padding(.top, 4)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.text)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    /// Skeleton in the shape of the bundled packs, so a first pack starts
    /// from working conventions instead of a blank page.
    static func template(for name: String) -> String {
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = display.isEmpty ? "Agent" : display
        return """
        # \(who)

        You are **\(who)**, a ... (one line: the job this agent does).

        ## What you do

        - ...
        - Keep working files under /workspace/ so they survive between turns.

        ## Voice

        - ...
        """
    }
}
