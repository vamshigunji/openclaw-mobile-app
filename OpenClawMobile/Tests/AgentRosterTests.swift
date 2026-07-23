import XCTest
@testable import OpenClawMobile

/// Agent roster decode + per-agent routing. Golden JSON is the LIVE `agents.list`
/// payload captured 2026-07-22 (agent `main` has no name/identity), plus a
/// second agent with a full identity block to exercise emoji/avatar decode.
final class AgentRosterTests: XCTestCase {
    static let liveJSON = #"""
    {"defaultId":"main","mainKey":"main","scope":"per-sender","agents":[
      {"id":"main","workspace":"/Users/apple/.openclaw/workspace","workspaceGit":true,
       "agentRuntime":{"id":"claude-cli","source":"model"},
       "model":{"primary":"anthropic/claude-opus-4-8"}},
      {"id":"indian-timer","name":"Indian-Timer",
       "identity":{"emoji":"🇮🇳","avatarUrl":"https://x/a.png","theme":"green"},
       "workspace":"/Users/apple/.openclaw/agents/indian-timer",
       "model":{"primary":"anthropic/claude-haiku-4-5"}}
    ]}
    """#

    func decode() throws -> AgentsListResult {
        try JSONDecoder().decode(AgentsListResult.self, from: Data(Self.liveJSON.utf8))
    }

    func testDecodesRosterWithDefaultAndTwoAgents() throws {
        let r = try decode()
        XCTAssertEqual(r.defaultId, "main")
        XCTAssertEqual(r.agents.count, 2)
    }

    func testAgentWithoutNameFallsBackToId() throws {
        let main = try XCTUnwrap(decode().agents.first { $0.id == "main" })
        XCTAssertEqual(main.displayName, "main")          // no name → id
        XCTAssertNil(main.emoji)
        XCTAssertEqual(main.model, "anthropic/claude-opus-4-8")
        XCTAssertEqual(main.workspace, "/Users/apple/.openclaw/workspace")
    }

    func testAgentWithIdentityDecodesEmojiAndName() throws {
        let it = try XCTUnwrap(decode().agents.first { $0.id == "indian-timer" })
        XCTAssertEqual(it.displayName, "Indian-Timer")
        XCTAssertEqual(it.emoji, "🇮🇳")
        XCTAssertEqual(it.avatarUrl, "https://x/a.png")
        XCTAssertEqual(it.model, "anthropic/claude-haiku-4-5")
    }

    /// Texting an agent uses the FULL canonical key agent:<id>:main + matching
    /// agentId (LIVE 2026-07-22: a bare key + separate agentId is rejected).
    func testCanonicalSessionKeyForAgent() {
        XCTAssertEqual(GatewayWSSyncSource.sessionKey(forAgent: "main"), "agent:main:main")
        XCTAssertEqual(GatewayWSSyncSource.sessionKey(forAgent: "indian-timer"), "agent:indian-timer:main")
    }

    // MARK: - Per-agent event routing (the shared subscribe stream carries ALL agents)

    func env(_ json: String) throws -> InboundEnvelope {
        try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }

    func testChatEventCarriesAgentIdForRouting() throws {
        let e = try env(#"""
        {"type":"event","event":"chat","payload":{"runId":"r1","agentId":"indian-timer",
         "sessionKey":"agent:indian-timer:main","seq":4,"state":"final",
         "message":{"role":"assistant","content":[{"type":"text","text":"3:42 PM IST"}]}}}
        """#)
        XCTAssertEqual(e.broadcastAgentId, "indian-timer")
        XCTAssertTrue(e.matchesAgent("indian-timer"))
        XCTAssertFalse(e.matchesAgent("main"))   // must NOT leak into main's thread
        XCTAssertTrue(e.matchesAgent(nil))       // nil = accept all
    }

    func testSessionMessageEventCarriesAgentId() throws {
        let e = try env(#"""
        {"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:main",
         "agentId":"main","message":{"role":"user","content":"hi","idempotencyKey":"k:user"}}}
        """#)
        XCTAssertEqual(e.broadcastAgentId, "main")
    }

    // MARK: - Demo roster is never empty

    func testDemoRosterHasSeveralAgents() async throws {
        let agents = try await DemoSyncSource().listAgents()
        XCTAssertGreaterThanOrEqual(agents.count, 2)
        XCTAssertTrue(agents.contains { $0.emoji != nil }) // demo agents look real
    }
}
