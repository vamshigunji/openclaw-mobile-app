import XCTest
@testable import OpenClawMobile

/// Activity indicator mapping — every verb maps to a REAL signal captured off the
/// live gateway wire (2026-07-22). Golden frames below are verbatim shapes:
/// `session.tool` carries `data.{phase,name}` (name is claude-cli style: WebSearch,
/// Bash), `agent` carries `stream` + `data.phase`, `chat` carries `state`.
/// No verb exists without a signal; unknown signals fall back to Working — never a guess.
final class AgentActivityTests: XCTestCase {
    func env(_ json: String) throws -> InboundEnvelope {
        try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }
    func activity(_ json: String) throws -> AgentActivity? {
        AgentActivity.from(try env(json))
    }

    // MARK: - session.tool (the tool verbs) — LIVE-captured shape

    func testWebSearchToolStart() throws {
        let a = try activity(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"WebSearch","args":{"query":"x"}},"agentId":"main"}}
        """#)
        XCTAssertEqual(a, .searchingWeb)
        XCTAssertEqual(a?.label, "Searching the web")
    }

    func testBashToolStart() throws {
        let a = try activity(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"Bash","args":{"command":"ls"}},"agentId":"main"}}
        """#)
        XCTAssertEqual(a, .runningCommand)
    }

    func testToolResultFallsBackToWorking() throws {
        // A finished tool returns to generic Working — the next signal refines it.
        let a = try activity(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"result","name":"WebSearch","isError":false},"agentId":"main"}}
        """#)
        XCTAssertEqual(a, .working)
    }

    func testToolNameMappingIsCaseInsensitiveAndCovers12Set() {
        XCTAssertEqual(AgentActivity.forTool("websearch"), .searchingWeb)
        XCTAssertEqual(AgentActivity.forTool("WebFetch"), .browsing)
        XCTAssertEqual(AgentActivity.forTool("Read"), .readingFiles)
        XCTAssertEqual(AgentActivity.forTool("LS"), .readingFiles)
        XCTAssertEqual(AgentActivity.forTool("Grep"), .searchingFiles)
        XCTAssertEqual(AgentActivity.forTool("Glob"), .searchingFiles)
        XCTAssertEqual(AgentActivity.forTool("Edit"), .editingFiles)
        XCTAssertEqual(AgentActivity.forTool("Write"), .editingFiles)
        XCTAssertEqual(AgentActivity.forTool("TodoWrite"), .planning)
        XCTAssertEqual(AgentActivity.forTool("Task"), .delegating)
        XCTAssertEqual(AgentActivity.forTool("memory_search"), .checkingMemory)
        XCTAssertEqual(AgentActivity.forTool("Skill"), .usingSkill)
    }

    func testUnknownToolFallsBackToWorkingNeverGuesses() {
        XCTAssertEqual(AgentActivity.forTool("SomeFuturePlugin"), .working)
    }

    // MARK: - agent stream signals — LIVE-captured

    func testThinkingStream() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"thinking",
         "data":{"progressTokens":50},"agentId":"main"}}
        """#), .thinking)
    }

    func testAssistantStreamIsTyping() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"assistant",
         "data":{"text":"H","delta":"H"},"agentId":"main"}}
        """#), .typing)
    }

    func testLifecycleEndIsIdle() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"lifecycle",
         "data":{"phase":"end"},"agentId":"main"}}
        """#), .idle)
    }

    func testLifecycleStartIsWorking() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"lifecycle",
         "data":{"phase":"start"},"agentId":"main"}}
        """#), .working)
    }

    func testApprovalStream() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"agent","payload":{"runId":"r","stream":"approval","agentId":"main"}}
        """#), .waitingApproval)
    }

    // MARK: - chat state

    func testChatDeltaIsTyping() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"chat","payload":{"runId":"r","state":"delta","deltaText":"x","agentId":"main"}}
        """#), .typing)
    }

    func testChatFinalIsIdle() throws {
        XCTAssertEqual(try activity(#"""
        {"type":"event","event":"chat","payload":{"runId":"r","state":"final","agentId":"main"}}
        """#), .idle)
    }

    // MARK: - non-activity noise is ignored (nil = no change)

    func testHealthAndTickYieldNoChange() throws {
        XCTAssertNil(try activity(#"{"type":"event","event":"health","payload":{"ok":true}}"#))
        XCTAssertNil(try activity(#"{"type":"event","event":"tick","payload":{"ts":1}}"#))
    }

    // MARK: - labels are verb-ing style, idle has none

    func testLabels() {
        XCTAssertNil(AgentActivity.idle.label)
        XCTAssertEqual(AgentActivity.thinking.label, "Thinking…")
        XCTAssertEqual(AgentActivity.planning.label, "Planning…")
        XCTAssertEqual(AgentActivity.delegating.label, "Delegating")
        XCTAssertFalse(AgentActivity.idle.isActive)
        XCTAssertTrue(AgentActivity.searchingWeb.isActive)
    }
}
