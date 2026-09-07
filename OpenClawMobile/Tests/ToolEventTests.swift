import XCTest
@testable import OpenClawMobile

/// Tool-call timeline (design §4.5): `session.tool` frames become entries with the tool's
/// real name and a summary taken from its args; nothing is invented. Frames are the verbatim
/// live captures from AgentActivityTests (2026-07-22).
final class ToolEventTests: XCTestCase {
    private func env(_ json: String) throws -> InboundEnvelope {
        try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }

    func testWebSearchStartSummarizesQuery() throws {
        let e = ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"WebSearch","args":{"query":"x"}},"agentId":"main"}}
        """#))
        XCTAssertEqual(e, ToolEvent(name: "WebSearch", summary: "x", phase: .start))
    }

    func testBashStartSummarizesCommand() throws {
        let e = ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"Bash","args":{"command":"ls"}},"agentId":"main"}}
        """#))
        XCTAssertEqual(e, ToolEvent(name: "Bash", summary: "ls", phase: .start))
    }

    func testMissingArgsYieldNilSummaryNeverAGuess() throws {
        let e = ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"SomeFuturePlugin"},"agentId":"main"}}
        """#))
        XCTAssertEqual(e?.name, "SomeFuturePlugin")
        XCTAssertNil(e?.summary)
    }

    func testSummaryPrefersCommandThenFilePathOverQuery() throws {
        let e = ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"Read","args":{"query":"q","file_path":"Sources/App.swift","limit":20}},"agentId":"main"}}
        """#))
        XCTAssertEqual(e?.summary, "Sources/App.swift")
    }

    func testSummaryIsTruncatedTo80Characters() throws {
        let long = String(repeating: "a", count: 200)
        let e = ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"Bash","args":{"command":"\#(long)"}},"agentId":"main"}}
        """#))
        XCTAssertEqual(e?.summary?.count, 80)
        XCTAssertTrue(e?.summary?.hasSuffix("…") == true)
    }

    func testNonToolFramesAreNotEvents() throws {
        XCTAssertNil(ToolEvent.from(try env(#"{"type":"event","event":"chat","payload":{"runId":"r","state":"delta","deltaText":"x","agentId":"main"}}"#)))
        XCTAssertNil(ToolEvent.from(try env(#"{"type":"event","event":"tick","payload":{"ts":1}}"#)))
    }

    func testResultPhaseClosesTheOpenEntry() throws {
        var timeline = ToolTimeline()
        timeline.apply(ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"start","name":"WebSearch","args":{"query":"x"}},"agentId":"main"}}
        """#))!)
        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertTrue(timeline.entries[0].isRunning)
        timeline.apply(ToolEvent.from(try env(#"""
        {"type":"event","event":"session.tool","payload":{"runId":"r","stream":"tool",
         "data":{"phase":"result","name":"WebSearch","isError":false},"agentId":"main"}}
        """#))!)
        XCTAssertEqual(timeline.entries.count, 1, "a result closes the entry, it does not add one")
        XCTAssertFalse(timeline.entries[0].isRunning)
        XCTAssertEqual(timeline.entries[0].summary, "x")
    }

    func testCloseAllEndsEveryRunningEntry() throws {
        var timeline = ToolTimeline()
        for name in ["Bash", "Read"] {
            timeline.apply(ToolEvent(name: name, summary: nil, phase: .start))
        }
        timeline.closeAll()
        XCTAssertEqual(timeline.entries.map(\.isRunning), [false, false])
        XCTAssertEqual(timeline.entries.map(\.name), ["Bash", "Read"])
    }
}
