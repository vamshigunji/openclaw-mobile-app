import SwiftUI

/// OpenClaw design tokens — the official palette (designs/2026-09-06-dev-suite-design.md §3.1,
/// sourced from openclaw/openclaw `docs/docs.json` + `ui/src/styles/base.css`). Dark only.
/// The ONLY home for color and radius values in the app (DesignSystemTests pins it).
enum Theme {
    // Surfaces
    static let bg       = Color(hex: 0x0E1015)   // screens, lists, board columns
    static let card     = Color(hex: 0x161920)   // cards, agent bubbles, fields
    static let elevated = Color(hex: 0x191C24)   // sheets, composer, headers

    // Lines — 1 px hairlines, never shadows
    static let borderColor  = Color(hex: 0x1E2028)
    static let borderStrong = Color(hex: 0x2E3040)  // focused / emphasized

    // Text
    static let text      = Color(hex: 0xF4F4F5)   // titles, names, input
    static let textBody  = Color(hex: 0xBCBCC0)   // message bodies
    static let textMuted = Color(hex: 0x8B8B94)   // captions, labels

    // Accents
    static let accent       = Color(hex: 0xFF5C5C)   // lobster red — tint, links, live dot
    static let accentSubtle = accent.opacity(0.10)   // user bubble fill, selected chips
    static let brand        = Color(hex: 0xD84A31)   // primary CTA fill, white text
    static let teal         = Color(hex: 0x14B8A6)   // running / activity
    static let ok     = Color(hex: 0x22C55E)
    static let warn   = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xF87171)

    // Bubbles
    static let userBubble  = accentSubtle
    static let agentBubble = card

    // Geometry — 6 pt controls/chips/fields, 10 pt cards/bubbles/sheets, 1 px borders
    static let radius: CGFloat = 6
    static let radiusCard: CGFloat = 10
    static let border: CGFloat = 1

    /// Type roles: system type for UI, mono only for code, paths, ids, keys, logs.
    enum Font {
        static let title: SwiftUI.Font = .system(.headline, weight: .semibold)
        static let body: SwiftUI.Font = .body
        static let caption: SwiftUI.Font = .caption
        static let label: SwiftUI.Font = .system(.caption2, weight: .medium)     // field labels, chips
        static let heading: SwiftUI.Font = .system(.title3, weight: .semibold)    // screen headers
        static let mono: SwiftUI.Font = .system(.body, design: .monospaced)
        static let monoCaption: SwiftUI.Font = .system(.caption, design: .monospaced)
    }
}

/// Status → color + SF Symbol. Single source of truth; status is never color alone.
enum AgentStatus: String, Codable, CaseIterable {
    case working, waiting, blocked, failed, done, idle

    var color: Color {
        switch self {
        case .working:           Theme.teal
        case .waiting, .blocked: Theme.warn
        case .failed:            Theme.danger
        case .done, .idle:       Theme.textMuted
        }
    }

    var symbol: String {
        switch self {
        case .working: "bolt.fill"
        case .waiting: "hand.raised.fill"
        case .blocked: "lock.fill"
        case .failed:  "xmark.octagon.fill"
        case .done:    "checkmark.circle.fill"
        case .idle:    "moon.zzz.fill"
        }
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .waiting: "Waiting on you"
        case .blocked: "Blocked"
        case .failed:  "Failed"
        case .done:    "Done"
        case .idle:    "Idle"
        }
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// Monospaced labeled text field — the app's one form input (used by Settings,
/// New Agent, Edit Agent). `secure` swaps to a SecureField.
struct MonoField: View {
    let label: String
    var placeholder: String = ""
    var secure: Bool = false
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Font.label)
                .foregroundStyle(Theme.textMuted)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .font(Theme.Font.mono)
            .foregroundStyle(Theme.text)
            .padding(10)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
        }
    }
}

/// Primary CTA: brand fill with white text (≥44pt tall). `secondary` = accent outline,
/// `destructive` = danger outline.
struct PrimaryButton: View {
    let title: String
    var secondary = false
    var destructive = false
    var disabled = false
    let action: () -> Void

    private var tint: Color { destructive ? Theme.danger : Theme.accent }
    private var outlined: Bool { secondary || destructive }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Font.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(outlined ? tint : .white)
                .background(outlined ? Color.clear : Theme.brand)
                .overlay(outlined
                    ? RoundedRectangle(cornerRadius: Theme.radius).stroke(tint, lineWidth: Theme.border)
                    : nil)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }
}

/// Live activity line for the chat header — a pulsing accent dot + the verb-ing
/// label ("Searching the web", "Thinking…"), each mapped from a real gateway
/// signal (`AgentActivity`). Idle shows a muted "Idle" so the header never jumps.
struct ActivityLine: View {
    let activity: AgentActivity
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            if let label = activity.label {
                Circle().fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                Text(label)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Idle")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .onAppear { pulse = true }
        .accessibilityLabel(activity.label ?? "Idle")
    }
}

/// Small color-coded status dot + label.
struct StatusBadge: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).font(.caption2)
            Text(status.label)
                .font(Theme.Font.caption)
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(status.color.opacity(0.4), lineWidth: Theme.border)
        )
    }
}
