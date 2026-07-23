import Foundation

/// The multi-device / multi-agent sync seam (PRD-handshake Path E / seam toward Path D).
///
/// Abstracts **roster + history + subscribe** away from any single transport so the
/// UI never talks to `GatewayClient` (or a future BFF) directly. In Path A this is
/// backed by the gateway's protocol-v4 WS RPC (`GatewayWSSyncSource`); a future
/// Path D backs the same protocol with a backend-for-frontend without UI changes.
///
/// Multi-agent: one connection carries every agent's traffic. `subscribe` filters
/// the shared event stream to a single agent so each thread only sees its own.
///
/// Sending stays on the WS write path with a client idempotency key (see
/// `GatewayWSSyncSource.send`). Pairing / challenge-signing is owned by
/// `.docs/protocol.md` and is NOT re-implemented here.
protocol SyncSource: Sendable {
    /// The agent roster (Path A: `agents.list`). Slack-style team list.
    func listAgents() async throws -> [AgentSummary]

    /// Snapshot/replay backfill for one agent's session (`chat.history`).
    /// Returns oldest-first. Errors surface as `GatewayError`.
    func loadHistory(agentId: String) async throws -> [ChatMessage]

    /// Live fan-in for ONE agent: yields every message the gateway broadcasts for
    /// `agentId` (including turns from other paired devices), filtered out of the
    /// shared connection-wide stream. `agentId == nil` accepts all agents.
    func subscribe(agentId: String?) -> AsyncThrowingStream<ChatMessage, Error>
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
    func loadHistory(agentId: String) async throws -> [ChatMessage] { [] }

    func subscribe(agentId: String?) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish() // no remote peers in demo mode
        }
    }
}
