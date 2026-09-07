import Foundation
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var draft: String = ""
    /// Photos/files staged in the composer tray, sent with the next message.
    var pendingAttachments: [Attachment] = []
    /// Inline reason when an attachment was refused (too large, unreadable).
    var attachmentHint: String?
    /// Mic button runtime (design §4.3).
    let dictation = SpeechDictation()
    /// A send is in flight (ack not yet received).
    var isStreaming: Bool = false
    /// Live "what is the agent doing" signal, mapped from real gateway events.
    var activity: AgentActivity = .idle
    /// The gateway run active for this thread — set from the `chat.send` ack, cleared by the
    /// run's final/aborted/error frame. Drives the Stop button.
    private(set) var activeRunId: String?
    /// Tool calls of the current run (real `session.tool` signals only).
    private(set) var timeline = ToolTimeline()

    let thread: ChatThread
    private let settings: SettingsStore
    /// Shared multi-agent connection (one socket for all agents), behind the seam.
    private let sync: SyncSource
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var toolTask: Task<Void, Never>?
    @ObservationIgnored private var runEndTask: Task<Void, Never>?
    /// Idempotency keys already rendered locally — used to drop the gateway's echo of
    /// our own sends (PRD-handshake P3 self-echo → no double-render).
    private var seenKeys: Set<String> = []
    // ponytail: protocol defaults; wire the hello-ok policy if a probe ever shows different limits.
    private let attachmentPolicy = AttachmentPolicy.default

    deinit {
        // Views create one view model per push; without this every closed thread would keep
        // four live event loops registered on the shared connection.
        subscription?.cancel()
        activityTask?.cancel()
        toolTask?.cancel()
        runEndTask?.cancel()
    }

    init(thread: ChatThread, sync: SyncSource, settings: SettingsStore) {
        self.thread = thread
        self.sync = sync
        self.settings = settings
        messages = [
            ChatMessage(role: .assistant,
                        text: settings.isConfigured
                            ? "Connected to \(thread.title). Text anything."
                            : "Demo mode — \(thread.title). Try \"what is the status?\" or pair your gateway in Settings.")
        ]
    }

    /// Loads history and starts the live fan-in subscription. Called once from the view.
    func start() {
        Task { await loadHistory() }
        subscribeToPeers()
        subscribeToActivity()
        subscribeToTools()
        subscribeToRunEnds()
    }

    /// Sending is blocked while a run is active: the button is Stop until the run ends
    /// (design §4.6), so a follow-up can never overwrite the stoppable run.
    var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
            && !isStreaming && activeRunId == nil
    }

    var canStop: Bool { activeRunId != nil }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isStreaming else { return }
        draft = ""
        pendingAttachments = []

        // Optimistic UI: the user message appears immediately, tagged with an idempotency
        // key so its broadcast echo can be reconciled/deduped.
        let idempotencyKey = UUID().uuidString
        seenKeys.insert(idempotencyKey)
        messages.append(ChatMessage(role: .user, text: text, attachments: attachments,
                                    clientMessageId: idempotencyKey))
        timeline.reset()

        if settings.isConfigured {
            Task { await deliver(text: text, attachments: attachments, idempotencyKey: idempotencyKey) }
        } else {
            streamDemoReply()
        }
    }

    /// Re-send a failed user turn under a fresh idempotency key (design §4.6).
    func retry(_ message: ChatMessage) async {
        guard message.role == .user, message.failed,
              let idx = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let key = UUID().uuidString
        seenKeys.insert(key)
        messages[idx].failed = false
        messages[idx].clientMessageId = key
        if settings.isConfigured {
            await deliver(text: message.text, attachments: message.attachments, idempotencyKey: key)
        } else {
            streamDemoReply()
        }
    }

    /// Stop the active run (`chat.abort`). The streaming bubble is marked aborted — not failed.
    func stop() async {
        guard let runId = activeRunId else { return }
        do {
            try await sync.abort(sessionKey: thread.sessionKey, agentId: thread.agentId, runId: runId)
        } catch {
            return // the run may still be going; keep Stop available
        }
        activeRunId = nil
        isStreaming = false
        timeline.closeAll()
        if let idx = messages.lastIndex(where: {
            $0.role == .assistant && ($0.isStreaming || $0.clientMessageId == "chat-run:\(runId)")
        }) {
            messages[idx].isStreaming = false
            messages[idx].aborted = true
        }
    }

    func toggleDictation() {
        dictation.toggle(draft: draft) { [weak self] in self?.draft = $0 }
    }

    // MARK: - Attachment intake (design §4.2)

    func addPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                attachmentHint = "Couldn't read that photo."
                continue
            }
            addImage(data: data, fileName: "photo-\(pendingAttachments.count + 1).jpg")
        }
    }

    func addCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 1) else { return }
        addImage(data: data, fileName: "camera-\(Int(Date().timeIntervalSince1970)).jpg")
    }

    /// Any image → one JPEG re-encode (2048 px / 0.8), then the per-image cap.
    func addImage(data: Data, fileName: String) {
        guard case .reencodeImage(let maxEdge, let quality) = AttachmentBudget.plan(
                fileName: fileName, mimeType: "image/jpeg", bytes: data.count, isImage: true, policy: attachmentPolicy),
              let encoded = ImageReencoder.jpeg(from: data, maxEdge: maxEdge, quality: quality) else {
            attachmentHint = "Couldn't read that image."
            return
        }
        if case .tooLarge(let max) = AttachmentBudget.verifyImage(bytes: encoded.data.count, policy: attachmentPolicy) {
            attachmentHint = "Image is still over \(max / 1_048_576) MB after resizing."
            return
        }
        let name = (fileName as NSString).deletingPathExtension + ".jpg"
        pendingAttachments.append(Attachment(kind: .image, fileName: name, mimeType: "image/jpeg",
                                             data: encoded.data, width: encoded.width, height: encoded.height))
        attachmentHint = nil
    }

    /// Files: small text inlines as a fence in the draft; images re-encode; the rest attach.
    func addFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Size first: never read a multi-GB pick into memory just to reject it.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > attachmentPolicy.maxBytes {
                attachmentHint = "\(url.lastPathComponent) is over \(attachmentPolicy.maxBytes / 1_048_576) MB."
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                attachmentHint = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                addImage(data: data, fileName: url.lastPathComponent)
                continue
            }
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            switch AttachmentBudget.plan(fileName: url.lastPathComponent, mimeType: mime,
                                         bytes: data.count, isImage: false, policy: attachmentPolicy) {
            case .inlineFence(let lang):
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("```") {
                    // A file with its own fences would break the wrapper; attach it instead.
                    pendingAttachments.append(Attachment(kind: .file, fileName: url.lastPathComponent,
                                                         mimeType: mime, data: data))
                } else {
                    let fence = AttachmentBudget.fence(fileName: url.lastPathComponent, lang: lang, text: text)
                    draft += (draft.isEmpty ? "" : "\n\n") + fence
                }
                attachmentHint = nil
            case .tooLarge(let max):
                attachmentHint = "\(url.lastPathComponent) is over \(max / 1_048_576) MB."
            case .attach, .reencodeImage:
                pendingAttachments.append(Attachment(kind: .file, fileName: url.lastPathComponent,
                                                     mimeType: mime, data: data))
                attachmentHint = nil
            }
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    /// Drives the real send()/stream pipeline with a canned prompt.
    /// Used for screenshot verification via the `--seed-demo` launch arg.
    func seedDemo() {
        draft = ProcessInfo.processInfo.environment["SEED_TEXT"] ?? "what is the status?"
        send()
    }

    // MARK: - Fan-in (SyncSource)

    private func loadHistory() async {
        do {
            let history = try await sync.loadHistory(sessionKey: thread.sessionKey, agentId: thread.agentId)
            guard !history.isEmpty else { return }
            messages.insert(contentsOf: history, at: 0)
            for m in history { if let k = m.clientMessageId { seenKeys.insert(k) } }
        } catch {
            // Non-fatal: history backfill is best-effort; offline/demo has none.
        }
    }

    private func subscribeToPeers() {
        subscription?.cancel()
        subscription = Task { [weak self, sync, key = thread.sessionKey] in
            do {
                for try await message in sync.subscribe(sessionKey: key) {
                    guard let self else { break }
                    self.ingest(remote: message)
                }
            } catch {
                // Subscription ended/failed; v1 does not auto-retry (see loop notes).
            }
        }
    }

    private func subscribeToActivity() {
        activityTask?.cancel()
        activityTask = Task { [weak self, sync, key = thread.sessionKey] in
            for await a in sync.activityStream(sessionKey: key) {
                guard let self, !Task.isCancelled else { break }
                self.activity = a
                if a == .idle { self.timeline.closeAll() } // lifecycle end / chat final|aborted|error
            }
        }
    }

    /// Clears Stop only for the run that actually ended — a late terminal frame from an
    /// earlier run must not disarm a newer one.
    private func subscribeToRunEnds() {
        runEndTask?.cancel()
        runEndTask = Task { [weak self, sync, key = thread.sessionKey] in
            for await runId in sync.runEnds(sessionKey: key) {
                guard let self, !Task.isCancelled else { break }
                if runId == self.activeRunId { self.activeRunId = nil }
            }
        }
    }

    private func subscribeToTools() {
        toolTask?.cancel()
        toolTask = Task { [weak self, sync, key = thread.sessionKey] in
            for await event in sync.toolEvents(sessionKey: key) {
                guard let self, !Task.isCancelled else { break }
                self.timeline.apply(event)
            }
        }
    }

    /// Upserts a broadcast message from the gateway: streaming `chat-run:*` updates
    /// replace their bubble in place; echoes of our own sends are dropped.
    private func ingest(remote: ChatMessage) {
        defer { noteRunEnd(remote) }
        guard let key = remote.clientMessageId else { messages.append(remote); return }
        if let idx = messages.lastIndex(where: { $0.clientMessageId == key }) {
            // In-place update for streaming runs; duplicate echoes are dropped.
            if key.hasPrefix("chat-run:") {
                // Mutate in place so aborted/failed/attachments survive later frames of the run.
                messages[idx].text = remote.text
                messages[idx].isStreaming = remote.isStreaming
            }
            return
        }
        if seenKeys.contains(key) { return } // echo of our optimistic send
        seenKeys.insert(key)
        messages.append(remote)
    }

    private func noteRunEnd(_ remote: ChatMessage) {
        guard let run = activeRunId, remote.clientMessageId == "chat-run:\(run)", !remote.isStreaming else { return }
        activeRunId = nil
    }

    // MARK: - Send paths

    /// Path A: WS write-of-record with an idempotency key. The reply and any peer-device
    /// turns arrive back via `subscribe()`; the ack's runId arms Stop.
    private func deliver(text: String, attachments: [Attachment], idempotencyKey: String) async {
        // The whole frame must fit the gateway's payload limit; base64 inflates attachments.
        if case .payloadTooLarge(let max) = AttachmentBudget.checkPayload(
            messageBytes: text.utf8.count, attachmentBytes: attachments.map(\.data.count),
            policy: attachmentPolicy) {
            attachmentHint = "Message is over \(max / 1_048_576) MB with its attachments. Remove one and retry."
            markFailed(idempotencyKey)
            return
        }
        isStreaming = true
        do {
            let runId = try await sync.send(sessionKey: thread.sessionKey, agentId: thread.agentId,
                                            text: text, idempotencyKey: idempotencyKey,
                                            attachments: attachments)
            activeRunId = runId ?? idempotencyKey // LIVE: the gateway adopts the idempotencyKey as runId
        } catch {
            markFailed(idempotencyKey)
        }
        isStreaming = false
    }

    private func markFailed(_ idempotencyKey: String) {
        if let idx = messages.lastIndex(where: { $0.clientMessageId == idempotencyKey }) {
            messages[idx].failed = true
        }
    }

    /// Demo mode: canned local stream (CLAUDE.md — must be preserved). The assistant
    /// bubble fills optimistically from deltas.
    private func streamDemoReply() {
        var assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistant)
        let assistantId = assistant.id
        isStreaming = true

        let client = GatewayClient(host: "", token: "", model: settings.model)
        let history = messages.filter { !$0.isStreaming }

        Task {
            do {
                for try await token in client.streamReply(history: history) {
                    assistant.text += token
                    update(assistantId, with: assistant)
                }
                assistant.isStreaming = false
                update(assistantId, with: assistant)
            } catch {
                assistant.isStreaming = false
                assistant.failed = true
                if assistant.text.isEmpty {
                    assistant.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                update(assistantId, with: assistant)
            }
            isStreaming = false
        }
    }

    private func update(_ id: UUID, with message: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = message
    }
}
