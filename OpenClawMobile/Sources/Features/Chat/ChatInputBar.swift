import SwiftUI

struct ChatInputBar: View {
    @Binding var text: String
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message agent…", text: $text, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Theme.bgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .stroke(Theme.borderColor, lineWidth: Theme.border)
                )
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.bgPrimary)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Theme.accent : Theme.borderColor)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgPrimary)
        .overlay(Rectangle().frame(height: Theme.border).foregroundStyle(Theme.borderColor), alignment: .top)
    }
}
