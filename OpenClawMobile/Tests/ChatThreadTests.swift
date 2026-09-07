import XCTest
@testable import OpenClawMobile

/// Session-keyed threads (design §4.1): a thread is (sessionKey, agentId), the roster opens
/// `agent:<id>:main`, and inbound frames route by `payload.sessionKey` first. Frames below use
/// the live-shaped `session.message` payload MockGateway emits (sessionKey + agentId).
final class ChatThreadTests: XCTestCase {
    private func env(_ json: String) throws -> InboundEnvelope {
        try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }

    func testMainThreadUsesCanonicalSessionKey() {
        let agent = AgentSummary(id: "x", name: "X", emoji: "🦞")
        let thread = ChatThread.main(for: agent)
        XCTAssertEqual(thread.sessionKey, "agent:x:main")
        XCTAssertEqual(thread.agentId, "x")
        XCTAssertEqual(thread.title, "X")
        XCTAssertEqual(thread.emoji, "🦞")
        XCTAssertTrue(thread.isMain)
        XCTAssertFalse(ChatThread(sessionKey: "agent:x:task1", agentId: "x", title: "t", emoji: nil).isMain)
    }

    func testFrameWithSessionKeyMatchesOnlyThatSession() throws {
        let frame = try env(#"""
        {"type":"event","event":"session.message","payload":{"sessionKey":"agent:x:task1","agentId":"x",
         "message":{"role":"user","content":"hi","idempotencyKey":"k1:user"}}}
        """#)
        XCTAssertTrue(frame.matchesSession("agent:x:task1"))
        XCTAssertFalse(frame.matchesSession("agent:x:main"))
        XCTAssertFalse(frame.matchesSession("agent:y:task1"))
    }

    func testFrameWithoutSessionKeyFallsBackToMainThreadOfItsAgent() throws {
        // Activity frames captured live (AgentActivityTests) carry agentId but no sessionKey.
        let frame = try env(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"thinking","data":{},"agentId":"x"}}
        """#)
        XCTAssertTrue(frame.matchesSession("agent:x:main"))
        XCTAssertFalse(frame.matchesSession("agent:x:task1"), "never leak main-thread activity into a task thread")
        XCTAssertFalse(frame.matchesSession("agent:y:main"))
    }
}
