import Foundation

/// The multi-device / multi-agent sync seam (PRD-handshake Path E / seam toward Path D).
///
/// Abstracts **roster + history + subscribe** away from any single transport so the
/// UI never talks to `GatewayClient` (or a future BFF) directly. In Path A this is
/// backed by the gateway's protocol-v4 WS RPC (`GatewayWSSyncSource`); a future
/// Path D backs the same protocol with a backend-for-frontend without UI changes.
///
/// Multi-agent: one connection carries every agent's traffic. Every method is keyed by
/// session (`agent:<id>:main` or a task session) so each thread only sees its own frames.
///
/// Sending stays on the WS write path with a client idempotency key (see
/// `GatewayWSSyncSource.send`). Pairing / challenge-signing is owned by
/// `.docs/protocol.md` and is NOT re-implemented here.
protocol SyncSource: Sendable {
    /// The agent roster (Path A: `agents.list`). Slack-style team list.
    func listAgents() async throws -> [AgentSummary]

    /// The agent's behavior/instructions (AGENTS.md), read directly (operator.read).
    /// nil when there's no readable instructions file. Demo returns a canned note.
    func loadInstructions(agentId: String) async throws -> String?

    /// Snapshot/replay backfill for one session (`chat.history`). Returns oldest-first.
    func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage]

    /// Live fan-in for ONE session: every message the gateway broadcasts for `sessionKey`
    /// (including turns from other paired devices), filtered out of the shared
    /// connection-wide stream. `nil` accepts all sessions.
    func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error>

    /// Live "what is the agent doing right now" for ONE session, mapped from the
    /// gateway's activity events (agent/session.tool/chat). `.idle` when a run ends.
    func activityStream(sessionKey: String) -> AsyncStream<AgentActivity>

    /// Send one user turn into a session (`chat.send`, operator.write) with a client
    /// idempotency key and optional native attachments. Returns the gateway `runId`.
    @discardableResult
    func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
              attachments: [Attachment]) async throws -> String?

    /// Stop the active run in a session (`chat.abort`, operator.write).
    func abort(sessionKey: String, agentId: String, runId: String?) async throws

    /// Live tool calls for ONE session (`session.tool` frames → `ToolEvent`). Default: none.
    func toolEvents(sessionKey: String) -> AsyncStream<ToolEvent>

    /// The runId of every run that ends in ONE session (`chat` final|aborted|error, lifecycle
    /// end|error). Lets a thread clear Stop for exactly the run that finished. Default: none.
    func runEnds(sessionKey: String) -> AsyncStream<String>
}

extension SyncSource {
    func toolEvents(sessionKey: String) -> AsyncStream<ToolEvent> { AsyncStream { $0.finish() } }
    func runEnds(sessionKey: String) -> AsyncStream<String> { AsyncStream { $0.finish() } }
}

/// Agent-main-thread and text-only conveniences over the session-keyed seam.
extension SyncSource {
    @discardableResult
    func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String) async throws -> String? {
        try await send(sessionKey: sessionKey, agentId: agentId, text: text,
                       idempotencyKey: idempotencyKey, attachments: [])
    }
    func loadHistory(agentId: String) async throws -> [ChatMessage] {
        try await loadHistory(sessionKey: ChatThread.mainKey(agentId: agentId), agentId: agentId)
    }
    func subscribe(agentId: String?) -> AsyncThrowingStream<ChatMessage, Error> {
        subscribe(sessionKey: agentId.map { ChatThread.mainKey(agentId: $0) })
    }
    func activityStream(agentId: String) -> AsyncStream<AgentActivity> {
        activityStream(sessionKey: ChatThread.mainKey(agentId: agentId))
    }
}

/// Demo-backed conformer: no gateway. Keeps the app usable/screenshottable with no
/// host configured (CLAUDE.md: the demo path must be preserved). Ships a small
/// canned roster so the agents list is never empty; replies come from
/// `GatewayClient.demoStream`, unchanged.
struct DemoSyncSource: SyncSource {
    static let demoAgents: [AgentSummary] = [
        AgentSummary(id: "main", name: "Assistant", emoji: "🤖",
                     model: "claude-opus-4-8", workspace: "~/workspace"),
        AgentSummary(id: "linkedin-team", name: "LinkedIn Team", emoji: "💼",
                     model: "claude-opus-4-8", workspace: "~/agents/linkedin"),
        AgentSummary(id: "indian-timer", name: "Indian-Timer", emoji: "🇮🇳",
                     model: "claude-haiku-4-5", workspace: "~/agents/indian-timer"),
    ]

    func listAgents() async throws -> [AgentSummary] { Self.demoAgents }
    func loadInstructions(agentId: String) async throws -> String? {
        "Demo agent — instructions live on a real gateway (pair in Settings)."
    }
    func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }

    func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish() // no remote peers in demo mode
        }
    }

    func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> {
        AsyncStream { $0.finish() } // demo agents have no live activity
    }

    /// Demo replies come from `GatewayClient.demoStream`; there is no gateway to ack.
    func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
              attachments: [Attachment]) async throws -> String? { nil }
    func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
}
