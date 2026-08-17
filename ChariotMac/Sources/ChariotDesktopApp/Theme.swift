import SwiftUI

/// chariots.sh visual language: near-black ground, bordered cards, monospace
/// structure, indigo accent.
enum Theme {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)        // #0B0B0D
    static let sidebar = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let card = Color(red: 0.075, green: 0.078, blue: 0.09)       // #131417
    static let cardHeader = Color(red: 0.09, green: 0.094, blue: 0.106)
    static let border = Color(red: 0.165, green: 0.17, blue: 0.19)      // #2A2C31
    static let text = Color(red: 0.925, green: 0.929, blue: 0.937)      // #ECEDEF
    static let secondary = Color(red: 0.545, green: 0.56, blue: 0.596)  // #8B8F98
    static let accent = Color(red: 0.427, green: 0.486, blue: 0.96)     // #6D7CF5
    static let green = Color(red: 0.29, green: 0.78, blue: 0.45)
    static let amber = Color(red: 0.95, green: 0.72, blue: 0.25)
    static let red = Color(red: 0.898, green: 0.282, blue: 0.302)       // #E5484D

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// "# section" header, chariots.sh style.
struct SectionHash: View {
    let title: String

    var body: some View {
        Text("# \(title)")
            .font(Theme.mono(12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.bottom, 2)
    }
}

/// Bordered card with a monospace header row.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.cardHeader)
            Divider().overlay(Theme.border)
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }
}

/// Uppercase mono key/value row ("STATUS   running").
struct KVRow: View {
    let key: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key.uppercased())
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Theme.mono(12))
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
            Spacer()
        }
    }
}

/// Status chip ("running", "hibernating $0.07/day"-style).
struct Chip: View {
    let text: String
    var color: Color = Theme.secondary

    var body: some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.45), lineWidth: 1))
    }
}

/// Both styles read `isEnabled` through a nested view — a ButtonStyle itself
/// gets no environment. Without this a `.disabled()` button paints exactly like
/// a live one, so pressing it appears to do nothing at all, with no hint that
/// the app is refusing rather than failing.
struct AccentButtonStyle: ButtonStyle {
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, danger: danger)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let danger: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.4))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background((danger ? Theme.red : Theme.accent).opacity(isEnabled ? 1 : 0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
        }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.mono(12, weight: .medium))
                .foregroundStyle(isEnabled ? Theme.text : Theme.secondary.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.border.opacity(isEnabled ? 1 : 0.5), lineWidth: 1))
                .opacity(configuration.isPressed && isEnabled ? 0.75 : 1)
        }
    }
}
