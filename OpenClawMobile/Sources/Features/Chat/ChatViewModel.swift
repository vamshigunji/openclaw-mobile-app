import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var draft: String = ""
    var isStreaming: Bool = false
    var errorText: String?

    private let settings: SettingsStore
    /// Multi-device fan-in seam (history + subscribe). Backed by the gateway WS in
    /// Path A, by a future BFF in Path D — the view model never depends on the
    /// concrete transport for history/subscribe.
    private let sync: SyncSource
    private let sessionId: String
    private var subscription: Task<Void, Never>?
    /// Idempotency keys already rendered locally — used to drop the gateway's echo of
    /// our own sends (PRD-handshake P3 self-echo → no double-render).
    private var seenKeys: Set<String> = []

    init(settings: SettingsStore) {
        self.settings = settings
        self.sessionId = "default" // v1: a single conversation
        self.sync = settings.isConfigured
            ? GatewayWSSyncSource(host: settings.host, token: settings.token)
            : DemoSyncSource()
        messages = [
            ChatMessage(role: .assistant,
                        text: settings.isConfigured
                            ? "Connected. Text your agent anything — e.g. \"what is the status?\""
                            : "Demo mode — no Gateway yet. Try \"what is the status?\" or add your VPS in Settings.")
        ]
    }

    /// Loads history and starts the live fan-in subscription. Called once from the view.
    func start() {
        Task { await loadHistory() }
        subscribeToPeers()
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        errorText = nil

        // Optimistic UI: user message appears immediately, tagged with an idempotency
        // key so its broadcast echo can be reconciled/deduped.
        let idempotencyKey = UUID().uuidString
        seenKeys.insert(idempotencyKey)
        messages.append(ChatMessage(role: .user, text: text, clientMessageId: idempotencyKey))

        if settings.isConfigured {
            sendOverWS(text: text, idempotencyKey: idempotencyKey)
        } else {
            streamDemoReply()
        }
    }

    /// Drives the real send()/stream pipeline with a canned prompt.
    /// Used for screenshot verification via the `--seed-demo` launch arg.
    func seedDemo() {
        draft = "what is the status?"
        send()
    }

    // MARK: - Fan-in (SyncSource)

    private func loadHistory() async {
        do {
            let history = try await sync.loadHistory(sessionId: sessionId)
            guard !history.isEmpty else { return }
            messages.insert(contentsOf: history, at: 0)
            for m in history { if let k = m.clientMessageId { seenKeys.insert(k) } }
        } catch {
            // Non-fatal: history backfill is best-effort; offline/demo has none.
        }
    }

    private func subscribeToPeers() {
        subscription?.cancel()
        subscription = Task { [sessionId] in
            do {
                for try await message in sync.subscribe(sessionId: sessionId) {
                    ingest(remote: message)
                }
            } catch {
                // Subscription ended/failed; v1 does not auto-retry (see loop notes).
            }
        }
    }

    /// Appends a broadcast message from the gateway, skipping the echo of our own sends.
    private func ingest(remote: ChatMessage) {
        if let key = remote.clientMessageId, seenKeys.contains(key) { return }
        if let key = remote.clientMessageId { seenKeys.insert(key) }
        messages.append(remote)
    }

    // MARK: - Send paths

    /// Path A: WS write-of-record with an idempotency key. The reply and any
    /// peer-device turns arrive back via `subscribe()`.
    private func sendOverWS(text: String, idempotencyKey: String) {
        guard let ws = sync as? GatewayWSSyncSource else { return }
        isStreaming = true
        Task {
            do {
                try await ws.send(sessionId: sessionId, text: text, idempotencyKey: idempotencyKey)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if let idx = messages.lastIndex(where: { $0.clientMessageId == idempotencyKey }) {
                    messages[idx].failed = true
                }
            }
            isStreaming = false
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
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isStreaming = false
        }
    }

    private func update(_ id: UUID, with message: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = message
    }
}
