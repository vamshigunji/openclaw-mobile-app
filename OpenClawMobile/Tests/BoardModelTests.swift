import XCTest
@testable import OpenClawMobile

/// Board rules (design §5.1–§5.3). Every row is decoded from the fixtures, never hand-built:
/// precedence cases mutate a decoded row so the shape stays the gateway's.
final class BoardModelTests: XCTestCase {
    private var sessions: [SessionSummary] = []
    private var tasks: [TaskSummary] = []

    private func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    override func setUpWithError() throws {
        sessions = try JSONDecoder().decode(SessionListResponse.self, from: fixture("sessions.list.json")).sessions
        tasks = try JSONDecoder().decode(TaskListResponse.self, from: fixture("tasks.list.json")).tasks
    }

    private func session(_ key: String) throws -> SessionSummary {
        try XCTUnwrap(sessions.first { $0.key == key })
    }

    // MARK: - Decode (P4.1)

    func testDecodesFixtures() throws {
        XCTAssertEqual(sessions.count, 9)
        XCTAssertEqual(tasks.count, 4)
        let attach = try session("agent:main:task-attach")
        XCTAssertEqual(attach.agentId, "main")
        XCTAssertEqual(attach.label, "Wire up attachments")
        XCTAssertEqual(attach.status, .running)
        XCTAssertEqual(attach.hasActiveRun, true)
        XCTAssertEqual(attach.worktree?.repoRoot, "/Users/dev/openclaw-mobile-app")
        XCTAssertEqual(attach.childSessions, ["agent:main:task-attach:sub-1"])
        XCTAssertEqual(attach.estimatedCostUsd, 0.42)
        let task = try XCTUnwrap(tasks.first { $0.id == "t-0001" })
        XCTAssertEqual(task.status, .running)
        XCTAssertEqual(task.lastToolName, "Edit")
        XCTAssertEqual(task.diffStat?.added, 41)
    }

    func testUnknownFieldsAndMissingOptionalsDoNotFailDecoding() throws {
        let json = Data(#"{"sessions":[{"key":"agent:x:y","sessionId":"s1","agentId":"x","futureField":{"a":1}}]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionListResponse.self, from: json)
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertNil(decoded.sessions[0].status)
        XCTAssertEqual(decoded.sessions[0].archived, false, "missing bools default to false")
    }

    func testUnknownStatusStringDecodesAsNilNotACrash() throws {
        let json = Data(#"{"sessions":[{"key":"agent:x:y","sessionId":"s1","agentId":"x","status":"teleporting"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionListResponse.self, from: json)
        XCTAssertNil(decoded.sessions[0].status)
    }

    // MARK: - Column rule (P4.2, design §5.2)

    func testColumnRuleForEachFixtureRow() throws {
        XCTAssertEqual(BoardColumn.for(try session("agent:main:task-attach")), .running, "status running")
        XCTAssertEqual(BoardColumn.for(try session("agent:writer:pricing-page")), .running, "queued waits in Running")
        XCTAssertEqual(BoardColumn.for(try session("agent:main:task-migrate")), .needsYou, "failed")
        XCTAssertEqual(BoardColumn.for(try session("agent:writer:landing-copy")), .needsYou, "done + unread = replied")
        XCTAssertEqual(BoardColumn.for(try session("agent:main:task-old")), .done, "archived")
        XCTAssertEqual(BoardColumn.for(try session("agent:main:main")), .done, "done")
        XCTAssertEqual(BoardColumn.for(try session("agent:researcher:read-rfc")), .backlog, "never ran")
    }

    func testArchivedBeatsRunning() throws {
        var row = try session("agent:main:task-attach")
        row.archived = true
        XCTAssertEqual(BoardColumn.for(row), .done)
    }

    func testRunningBeatsUnread() throws {
        var row = try session("agent:main:task-attach")
        row.unread = true
        XCTAssertEqual(BoardColumn.for(row), .running)
    }

    func testHasActiveRunAloneIsRunning() throws {
        var row = try session("agent:main:task-old")
        row.archived = false
        row.status = .done
        row.hasActiveRun = true
        XCTAssertEqual(BoardColumn.for(row), .running)
    }

    func testKilledAndTimeoutNeedYou() throws {
        var row = try session("agent:main:task-attach")
        row.hasActiveRun = false
        for status in [SessionRunStatus.killed, .timeout, .failed] {
            row.status = status
            XCTAssertEqual(BoardColumn.for(row), .needsYou, "\(status) needs a human")
        }
    }

    func testRowWithActivityButNoStatusIsNotBacklog() throws {
        var row = try session("agent:researcher:read-rfc")
        row.lastActivityAt = 1788805000000
        XCTAssertEqual(BoardColumn.for(row), .done, "it ran at some point; only never-run rows are Backlog")
    }

    // MARK: - Lane rule (P4.3, design §5.3)

    private var agents: [AgentSummary] {
        [AgentSummary(id: "main", name: "main", workspace: "/Users/dev/agent-workspaces/main"),
         AgentSummary(id: "writer", name: "Writer"),
         AgentSummary(id: "researcher", name: "Researcher")]
    }

    func testCategoryWinsOverEverything() throws {
        var row = try session("agent:writer:landing-copy")
        row.worktree = SessionSummary.Worktree(id: "w", branch: "b", repoRoot: "/Users/dev/other-repo")
        XCTAssertEqual(ProjectLane.key(for: row, agents: agents), "Website redesign")
    }

    func testWorktreeRepoRootBeatsExecCwd() throws {
        let row = try session("agent:main:task-attach")
        XCTAssertEqual(ProjectLane.key(for: row, agents: agents), "openclaw-mobile-app")
    }

    func testExecCwdUsedWhenNoWorktree() throws {
        var row = try session("agent:writer:landing-copy")
        row.category = nil
        XCTAssertEqual(ProjectLane.key(for: row, agents: agents), "marketing-site")
    }

    func testSpawnedCwdUsedWhenNoExecCwd() throws {
        var row = try session("agent:main:task-old")
        row.category = nil
        XCTAssertEqual(ProjectLane.key(for: row, agents: agents), "openclaw-mobile-app")
    }

    func testAgentWorkspaceThenAgentName() throws {
        let researcher = try session("agent:researcher:read-rfc")
        XCTAssertEqual(ProjectLane.key(for: researcher, agents: agents), "Researcher",
                       "no workspace on that agent → its display name")
        var mainRow = try session("agent:main:main")
        mainRow.category = nil
        XCTAssertEqual(ProjectLane.key(for: mainRow, agents: agents), "main",
                       "agent workspace last component")
    }

    // MARK: - Assembly (P4.4, P4.5)

    private func board() throws -> Board {
        Board.make(sessions: sessions, tasks: tasks, agents: agents)
    }

    func testMainAndGlobalRowsAreHiddenByDefault() throws {
        let keys = try board().lanes.flatMap { $0.columns.values.flatMap { $0 } }.map(\.session.key)
        XCTAssertFalse(keys.contains("agent:main:main"), "main threads live on the Agents tab")
        XCTAssertFalse(keys.contains("global:notes"), "global sessions are not board work")
    }

    func testChildFoldsIntoItsParentAsASubtask() throws {
        let board = try board()
        let keys = board.lanes.flatMap { $0.columns.values.flatMap { $0 } }.map(\.session.key)
        XCTAssertFalse(keys.contains("agent:main:task-attach:sub-1"), "a spawned child is not its own card")
        let parent = try XCTUnwrap(board.card("agent:main:task-attach"))
        XCTAssertEqual(parent.children.map(\.key), ["agent:main:task-attach:sub-1"])
    }

    func testOrphanChildKeepsItsOwnCard() throws {
        var orphan = try session("agent:main:task-attach:sub-1")
        orphan.spawnedBy = "agent:main:vanished"
        let board = Board.make(sessions: [orphan], tasks: [], agents: agents)
        XCTAssertNotNil(board.card("agent:main:task-attach:sub-1"))
    }

    func testTasksAttachToTheirSessionCard() throws {
        let board = try board()
        let card = try XCTUnwrap(board.card("agent:main:task-attach"))
        XCTAssertEqual(Set(card.tasks.map(\.id)), ["t-0001", "t-0002"])
        XCTAssertEqual(card.taskSummary, "1 running · 1 done")
        let failing = try XCTUnwrap(board.card("agent:main:task-migrate"))
        XCTAssertEqual(failing.taskSummary, "1 failed")
    }

    func testCardTitleFallsBackThroughLabelThenTitleThenPreviewThenKey() throws {
        var row = try session("agent:main:task-attach")
        XCTAssertEqual(BoardCard(session: row, tasks: [], children: []).title, "Wire up attachments")
        row.label = nil
        XCTAssertEqual(BoardCard(session: row, tasks: [], children: []).title, "Wire up attachments", "derivedTitle")
        row.derivedTitle = nil
        XCTAssertEqual(BoardCard(session: row, tasks: [], children: []).title,
                       "Re-encoding the image before upload…", "first line of the preview")
        row.lastMessagePreview = nil
        XCTAssertEqual(BoardCard(session: row, tasks: [], children: []).title, "agent:main:task-attach")
    }

    func testLaneAndCardOrdering() throws {
        let board = try board()
        XCTAssertEqual(board.lanes.first?.key, "openclaw-mobile-app",
                       "a lane with running work sorts first")
        let running = try XCTUnwrap(board.lanes.first?.columns[.running])
        XCTAssertEqual(running.map(\.session.key), ["agent:main:task-attach"])
        let website = try XCTUnwrap(board.lanes.first { $0.key == "Website redesign" })
        XCTAssertEqual(website.columns[.needsYou]?.map(\.session.key), ["agent:writer:landing-copy"])
    }

    func testPinnedCardsSortAboveTheRest() throws {
        var a = try session("agent:writer:landing-copy")   // pinned, older
        var b = try session("agent:writer:pricing-page")
        a.category = "Shared"; b.category = "Shared"
        b.status = .done; b.unread = true; b.lastActivityAt = 1788809000000 // newer, unpinned
        let board = Board.make(sessions: [a, b], tasks: [], agents: agents)
        let column = try XCTUnwrap(board.lanes.first?.columns[.needsYou])
        XCTAssertEqual(column.map(\.session.key), ["agent:writer:landing-copy", "agent:writer:pricing-page"])
    }
}
