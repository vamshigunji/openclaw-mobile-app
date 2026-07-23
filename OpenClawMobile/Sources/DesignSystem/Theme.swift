import SwiftUI

/// OpenClaw Design Language (PRD §4). Dark mode only for v1.
enum Theme {
    // Backgrounds
    static let bgPrimary   = Color(hex: 0x0E0F12)
    static let bgSecondary = Color(hex: 0x1E2026)

    // Accent
    static let accent      = Color(hex: 0x22C55E) // terminal green

    // Text
    static let textPrimary   = Color(hex: 0xE5E7EB)
    static let textSecondary = Color(hex: 0x9CA3AF)

    // Bubbles
    static let userBubble  = Color(hex: 0x14351F)   // dark green tint, green border on top
    static let agentBubble = Color(hex: 0x1E2026)   // near-black/gray

    // Geometry — strict 4px, 1px borders, no shadows
    static let radius: CGFloat = 4
    static let border: CGFloat = 1
    static let borderColor = Color(hex: 0x2A2D34)
}

/// Status → color mapping (PRD §4).
enum AgentStatus: String, Codable, CaseIterable {
    case working, waiting, blocked, failed, done, idle

    var color: Color {
        switch self {
        case .working: return Color(hex: 0x22C55E)
        case .waiting: return Color(hex: 0xF59E0B)
        case .blocked: return Color(hex: 0xA855F7)
        case .failed:  return Color(hex: 0xEF4444)
        case .done, .idle: return Color(hex: 0x6B7280)
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Waiting on You"
        case .blocked: return "Blocked"
        case .failed:  return "Failed"
        case .done:    return "Done"
        case .idle:    return "Idle"
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
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("Idle")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
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
            Circle().fill(status.color).frame(width: 7, height: 7)
            Text(status.label)
                .font(.system(.caption2, design: .monospaced))
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
