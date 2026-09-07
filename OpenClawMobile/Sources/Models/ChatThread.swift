import Foundation

/// One conversation target: a gateway session plus the agent that owns it. The roster opens an
/// agent's main thread; a Board card opens the task's own session (design §4.1).
struct ChatThread: Hashable, Sendable {
    let sessionKey: String
    let agentId: String
    let title: String
    let emoji: String?

    /// Canonical main-thread key — LIVE-verified 2026-07-22: `agent:<id>:main` + matching agentId.
    static func mainKey(agentId: String) -> String { "agent:\(agentId):main" }

    static func main(for agent: AgentSummary) -> ChatThread {
        ChatThread(sessionKey: mainKey(agentId: agent.id), agentId: agent.id,
                   title: agent.displayName, emoji: agent.emoji)
    }

    var isMain: Bool { sessionKey == Self.mainKey(agentId: agentId) }
}
