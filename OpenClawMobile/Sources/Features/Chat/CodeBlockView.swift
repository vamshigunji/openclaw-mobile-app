import SwiftUI

/// A fenced code block: language label, monospaced body, horizontal scroll, Copy (design §4.4).
struct CodeBlockView: View {
    let lang: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang ?? "code").font(Theme.Font.label).foregroundStyle(Theme.textMuted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Font.label)
                        .foregroundStyle(copied ? Theme.ok : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.elevated)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Theme.Font.monoCaption)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Theme.bg)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}
