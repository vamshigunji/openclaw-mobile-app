import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if message.isStreaming && message.text.isEmpty {
                    TypingIndicator()
                } else {
                    Text(message.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.failed {
                    Text("failed — tap to retry not wired in prototype")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(AgentStatus.failed.color)
                }
            }
            .padding(10)
            .background(isUser ? Theme.userBubble : Theme.agentBubble)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(isUser ? Theme.accent.opacity(0.6) : Theme.borderColor,
                            lineWidth: Theme.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

/// Three-dot "agent is generating" indicator (PRD §3.3 streaming state).
struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase == Double(i) ? 1 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { phase = 2 }
        }
    }
}
