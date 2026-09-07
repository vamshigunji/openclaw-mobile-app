import SwiftUI

/// One turn. Agent turns are full-width cards with a small emoji/name header
/// (Control-UI style); user turns sit right-aligned on an accent-tinted card.
struct MessageBubble: View {
    let message: ChatMessage
    var agentName: String? = nil
    var agentEmoji: String? = nil
    var onRetry: (() -> Void)? = nil

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser, let agentName {
                    HStack(spacing: 6) {
                        Text(agentEmoji ?? "🖥").font(Theme.Font.caption)
                        Text(agentName).font(Theme.Font.label).foregroundStyle(Theme.textMuted)
                    }
                }
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments)
                }
                if message.isStreaming && message.text.isEmpty {
                    TypingIndicator()
                } else if !message.text.isEmpty {
                    segmentsView
                }
                if message.failed {
                    Button { onRetry?() } label: {
                        Label("Failed to send. Retry", systemImage: "arrow.clockwise")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
                if message.aborted {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(12)
            .background(isUser ? Theme.userBubble : Theme.agentBubble)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusCard)
                    .stroke(isUser ? Theme.accent.opacity(0.5) : Theme.borderColor, lineWidth: Theme.border)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
            .contextMenu { menu }
        }
    }

    private var segments: [MessageSegmenter.Segment] { MessageSegmenter.segments(message.text) }

    /// Prose renders inline markdown only; fenced code becomes a CodeBlockView.
    private var segmentsView: some View {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            switch segment.kind {
            case .prose:
                if !segment.body.isEmpty {
                    Text(inlineMarkdown(segment.body))
                        .font(Theme.Font.body)
                        .foregroundStyle(isUser ? Theme.text : Theme.textBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                }
            case .code(let lang):
                CodeBlockView(lang: lang, code: segment.body)
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder private var menu: some View {
        Button { UIPasteboard.general.string = message.text } label: {
            Label("Copy text", systemImage: "doc.on.doc")
        }
        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
            if case .code(let lang) = segment.kind {
                Button { UIPasteboard.general.string = segment.body } label: {
                    Label("Copy code" + (lang.map { " (\($0))" } ?? ""), systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }
}

/// Three-dot "agent is generating" indicator.
struct TypingIndicator: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.teal)
                    .frame(width: 6, height: 6)
                    .opacity(phase == Double(i) ? 1 : 0.3)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) { phase = 2 }
        }
    }
}
