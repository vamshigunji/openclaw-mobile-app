import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var draft: String = ""
    var isStreaming: Bool = false

    let agent: AgentSummary
    private let settings: SettingsStore
    /// Shared multi-agent connection (one socket for all agents). Backed by the
    /// gateway WS in Path A, a future BFF in Path D — the view model never depends
    /// on the concrete transport.
    private let sync: SyncSource
    private var subscription: Task<Void, Never>?
    /// Idempotency keys already rendered locally — used to drop the gateway's echo of
    /// our own sends (PRD-handshake P3 self-echo → no double-render).
    private var seenKeys: Set<String> = []

    init(agent: AgentSummary, sync: SyncSource, settings: SettingsStore) {
        self.agent = agent
        self.sync = sync
        self.settings = settings
        messages = [
            ChatMessage(role: .assistant,
                        text: settings.isConfigured
                            ? "Connected to \(agent.displayName). Text anything."
                            : "Demo mode — \(agent.displayName). Try \"what is the status?\" or pair your gateway in Settings.")
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
        draft = ProcessInfo.processInfo.environment["SEED_TEXT"] ?? "what is the status?"
        send()
    }

    // MARK: - Fan-in (SyncSource)

    private func loadHistory() async {
        do {
            let history = try await sync.loadHistory(agentId: agent.id)
            guard !history.isEmpty else { return }
            messages.insert(contentsOf: history, at: 0)
            for m in history { if let k = m.clientMessageId { seenKeys.insert(k) } }
        } catch {
            // Non-fatal: history backfill is best-effort; offline/demo has none.
        }
    }

    private func subscribeToPeers() {
        subscription?.cancel()
        subscription = Task { [agentId = agent.id] in
            do {
                for try await message in sync.subscribe(agentId: agentId) {
                    ingest(remote: message)
                }
            } catch {
                // Subscription ended/failed; v1 does not auto-retry (see loop notes).
            }
        }
    }

    /// Upserts a broadcast message from the gateway: streaming `chat-run:*` updates
    /// replace their bubble in place; echoes of our own sends are dropped.
    private func ingest(remote: ChatMessage) {
        guard let key = remote.clientMessageId else { messages.append(remote); return }
        if let idx = messages.lastIndex(where: { $0.clientMessageId == key }) {
            // In-place update for streaming runs; duplicate echoes are dropped.
            if key.hasPrefix("chat-run:") {
                let id = messages[idx].id
                var updated = remote
                updated = ChatMessage(id: id, role: updated.role, text: updated.text,
                                      isStreaming: updated.isStreaming,
                                      clientMessageId: updated.clientMessageId)
                messages[idx] = updated
            }
            return
        }
        if seenKeys.contains(key) { return } // echo of our optimistic send
        seenKeys.insert(key)
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
                try await ws.send(agentId: agent.id, text: text, idempotencyKey: idempotencyKey)
            } catch {
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
            }
            isStreaming = false
        }
    }

    private func update(_ id: UUID, with message: ChatMessage) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx] = message
    }
}
