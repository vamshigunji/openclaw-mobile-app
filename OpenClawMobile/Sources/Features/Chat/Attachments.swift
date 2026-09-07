import SwiftUI

/// Decoded-size ceilings the gateway advertises in hello-ok `policy` (docs.openclaw.ai
/// gateway/protocol → hello-ok). Defaults are the documented gateway defaults, used when an
/// older gateway omits `policy`.
struct AttachmentPolicy: Equatable, Sendable {
    var maxBytes = 20 * 1024 * 1024        // per attachment (agents.defaults.mediaMaxMb)
    var maxImageBytes = 6 * 1024 * 1024    // per image (agent-hydration cap)
    var maxPayload = 25 * 1024 * 1024      // the whole encoded frame

    static let `default` = AttachmentPolicy()

    /// Reads `policy.attachments.{maxBytes,maxImageBytes}` and `policy.maxPayload` from a
    /// hello-ok frame (or its bare payload). Missing fields keep the defaults.
    static func from(helloOK data: Data) -> AttachmentPolicy {
        var policy = AttachmentPolicy()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return policy }
        let payload = (root["payload"] as? [String: Any]) ?? root
        guard let raw = payload["policy"] as? [String: Any] else { return policy }
        if let v = raw["maxPayload"] as? Int { policy.maxPayload = v }
        if let attachments = raw["attachments"] as? [String: Any] {
            if let v = attachments["maxBytes"] as? Int { policy.maxBytes = v }
            if let v = attachments["maxImageBytes"] as? Int { policy.maxImageBytes = v }
        }
        return policy
    }
}

/// Something the user attached from the composer (design §4.2).
struct Attachment: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case image, file }
    let id: UUID
    let kind: Kind
    let fileName: String
    let mimeType: String
    var data: Data
    var width: Int?
    var height: Int?

    init(id: UUID = UUID(), kind: Kind, fileName: String, mimeType: String, data: Data,
         width: Int? = nil, height: Int? = nil) {
        self.id = id; self.kind = kind; self.fileName = fileName; self.mimeType = mimeType
        self.data = data; self.width = width; self.height = height
    }

    /// Wire shape for `chat.send.attachments` (gateway `attachment-normalize.ts`).
    var wireParams: [String: Any] {
        var params: [String: Any] = [
            "type": kind == .image ? "image" : "file",
            "mimeType": mimeType,
            "fileName": fileName,
            "content": data.base64EncodedString(),
            "sizeBytes": data.count,
        ]
        if let width { params["width"] = width }
        if let height { params["height"] = height }
        return params
    }
}

/// Pure sizing rules: the composer asks `plan` before encoding, `verifyImage` after the
/// re-encode, and the send path asks `checkPayload` before framing.
enum AttachmentBudget {
    enum Plan: Equatable {
        case attach
        case reencodeImage(maxEdge: Int, quality: Double)
        case inlineFence(lang: String)
        case tooLarge(max: Int)
    }
    enum Check: Equatable { case ok, tooLarge(max: Int), payloadTooLarge(max: Int) }

    static let imageMaxEdge = 2048
    static let imageQuality = 0.8
    static let inlineTextLimit = 64 * 1024
    static let textExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "md", "txt", "log", "sh", "zsh",
        "bash", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "sql", "toml", "xml",
        "html", "css", "csv", "env", "conf", "ini", "plist", "gradle", "dockerfile", "makefile",
    ]

    static func plan(fileName: String, mimeType: String, bytes: Int, isImage: Bool,
                     policy: AttachmentPolicy) -> Plan {
        if isImage { return .reencodeImage(maxEdge: imageMaxEdge, quality: imageQuality) }
        if bytes > policy.maxBytes { return .tooLarge(max: policy.maxBytes) }
        if bytes <= inlineTextLimit, let lang = textLanguage(fileName: fileName, mimeType: mimeType) {
            return .inlineFence(lang: lang)
        }
        return .attach
    }

    static func verifyImage(bytes: Int, policy: AttachmentPolicy) -> Check {
        bytes > policy.maxImageBytes ? .tooLarge(max: policy.maxImageBytes) : .ok
    }

    /// base64 inflates 4/3 (+ per-attachment JSON overhead); the frame must fit `maxPayload`.
    static func checkPayload(messageBytes: Int, attachmentBytes: [Int], policy: AttachmentPolicy) -> Check {
        let encoded = messageBytes + attachmentBytes.reduce(0) { $0 + ($1 + 2) / 3 * 4 + 200 }
        return encoded > policy.maxPayload ? .payloadTooLarge(max: policy.maxPayload) : .ok
    }

    /// A text file inlined so the agent reads it directly.
    static func fence(fileName: String, lang: String, text: String) -> String {
        "`\(fileName)`:\n```\(lang)\n\(text)\n```"
    }

    /// Fence language for a text-like file; nil for binaries.
    static func textLanguage(fileName: String, mimeType: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return ext }
        if ext.isEmpty, textExtensions.contains(fileName.lowercased()) { return fileName.lowercased() }
        if mimeType.hasPrefix("text/") || mimeType == "application/json" || mimeType.hasSuffix("+json")
            || mimeType.hasSuffix("source") {
            return ext.isEmpty ? "text" : ext
        }
        return nil
    }
}

/// Thumbnails for images, chips for files — inside a bubble or the composer tray.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    var onRemove: ((Attachment) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        thumbnail(attachment)
                        if let onRemove {
                            Button { onRemove(attachment) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.body)
                                    .foregroundStyle(Theme.text, Theme.bg)
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove \(attachment.fileName)")
                        }
                    }
                }
            }
            .padding(.top, onRemove == nil ? 0 : 6)
        }
    }

    @ViewBuilder
    private func thumbnail(_ attachment: Attachment) -> some View {
        if attachment.kind == .image, let image = UIImage(data: attachment.data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
                .accessibilityLabel(attachment.fileName)
        } else {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind == .image ? "photo" : "doc")
                Text(attachment.fileName).font(Theme.Font.monoCaption).lineLimit(1)
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: Theme.border))
        }
    }
}

/// One resize pass: longest edge ≤ `maxEdge`, JPEG at `quality` (HEIC and friends become JPEG).
enum ImageReencoder {
    static func jpeg(from data: Data, maxEdge: Int, quality: Double) -> (data: Data, width: Int, height: Int)? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, CGFloat(maxEdge) / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let out = resized.jpegData(compressionQuality: quality) else { return nil }
        return (out, Int(target.width), Int(target.height))
    }
}

/// System camera (UIImagePickerController) — returns the captured photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
