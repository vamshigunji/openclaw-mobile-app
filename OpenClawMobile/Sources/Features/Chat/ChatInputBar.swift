import PhotosUI
import SwiftUI

/// Composer: attach menu (+), text field, mic, send/stop; a tray of staged attachments and an
/// inline hint sit above the field (design §4.2/§4.3).
struct ChatInputBar: View {
    @Binding var text: String
    let canSend: Bool
    let onSend: () -> Void
    var canStop = false
    var onStop: () -> Void = {}
    var attachments: [Attachment] = []
    var hint: String? = nil
    var isDictating = false
    var onRemoveAttachment: (Attachment) -> Void = { _ in }
    var onPhotos: ([PhotosPickerItem]) -> Void = { _ in }
    var onCameraImage: (UIImage) -> Void = { _ in }
    var onFiles: ([URL]) -> Void = { _ in }
    var onMic: () -> Void = {}

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments, onRemove: onRemoveAttachment)
            }
            if let hint {
                Text(hint).font(Theme.Font.caption).foregroundStyle(Theme.warn)
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                TextField("Message…", text: $text, axis: .vertical)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius)
                            .stroke(Theme.borderColor, lineWidth: Theme.border)
                    )
                    .onSubmit(onSend)
                micButton
                if canStop && !canSend {
                    iconButton("stop.fill", label: "Stop", fill: Theme.brand, action: onStop)
                } else {
                    iconButton("arrow.up", label: "Send", fill: canSend ? Theme.brand : Theme.borderStrong, action: onSend)
                        .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.elevated)
        .overlay(Rectangle().frame(height: Theme.border).foregroundStyle(Theme.borderColor), alignment: .top)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            onPhotos(items)
            photoItems = []
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onImage: onCameraImage).ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { onFiles(urls) }
        }
    }

    private var attachMenu: some View {
        Menu {
            Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
            }
            Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
        }
        .accessibilityLabel("Attach")
    }

    private var micButton: some View {
        Button(action: onMic) {
            Image(systemName: isDictating ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isDictating ? .white : Theme.accent)
                .frame(width: 38, height: 38)
                .background(isDictating ? Theme.teal : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                    .stroke(isDictating ? Theme.teal : Theme.borderColor, lineWidth: Theme.border))
        }
        .accessibilityLabel(isDictating ? "Stop dictation" : "Dictate")
    }

    private func iconButton(_ symbol: String, label: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .accessibilityLabel(label)
    }
}
