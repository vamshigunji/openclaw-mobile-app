import XCTest
@testable import OpenClawMobile

/// Board loading and live refresh (design §5.6/§5.7).
@MainActor
final class BoardViewModelTests: XCTestCase {
    /// Serves the fixtures and lets a test push a `sessions.changed` tick.
    private final class StubSync: SyncSource, @unchecked Sendable {
        var sessions: [SessionSummary] = []
        var tasks: [TaskSummary] = []
        var agents: [AgentSummary] = [AgentSummary(id: "main", name: "main"),
                                      AgentSummary(id: "writer", name: "Writer"),
                                      AgentSummary(id: "researcher", name: "Researcher")]
        var listCalls = 0
        var changes: AsyncStream<Void>.Continuation?
        var failNext = false

        func listAgents() async throws -> [AgentSummary] { agents }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> { AsyncThrowingStream { $0.finish() } }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { nil }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
        func listSessions() async throws -> [SessionSummary] {
            listCalls += 1
            if failNext { failNext = false; throw GatewayError.unreachable("boom") }
            return sessions
        }
        func listTasks() async throws -> [TaskSummary] { tasks }
        func sessionChanges() -> AsyncStream<Void> { AsyncStream { self.changes = $0 } }
    }

    private func fixtures() throws -> ([SessionSummary], [TaskSummary]) {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let s = try JSONDecoder().decode(SessionListResponse.self,
                                         from: Data(contentsOf: dir.appendingPathComponent("sessions.list.json")))
        let t = try JSONDecoder().decode(TaskListResponse.self,
                                         from: Data(contentsOf: dir.appendingPathComponent("tasks.list.json")))
        return (s.sessions, t.tasks)
    }

    private func makeViewModel(_ sync: StubSync) -> BoardViewModel {
        BoardViewModel(sync: sync, isConfigured: true)
    }

    func testLoadsLanesFromTheGateway() async throws {
        let sync = StubSync()
        (sync.sessions, sync.tasks) = try fixtures()
        let vm = makeViewModel(sync)
        await vm.load()
        XCTAssertFalse(vm.board.isEmpty)
        XCTAssertEqual(vm.board.lanes.first?.key, "openclaw-mobile-app")
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.board.card("agent:main:task-attach"))
    }

    func testSessionsChangedRefreshesWithoutAManualReload() async throws {
        let sync = StubSync()
        (sync.sessions, sync.tasks) = try fixtures()
        let vm = makeViewModel(sync)
        vm.start()
        let loaded = await waitUntil { !vm.board.isEmpty }
        XCTAssertTrue(loaded)
        let callsAfterLoad = sync.listCalls

        // The gateway says the roster moved: a running card finished.
        sync.sessions = sync.sessions.map { row in
            guard row.key == "agent:main:task-attach" else { return row }
            var updated = row
            updated.status = .done
            updated.hasActiveRun = false
            return updated
        }
        sync.changes?.yield()

        let moved = await waitUntil { vm.board.card("agent:main:task-attach")?.column == .done }
        XCTAssertTrue(moved, "a sessions.changed event should re-read the board")
        XCTAssertGreaterThan(sync.listCalls, callsAfterLoad)
    }

    func testFailureSurfacesAnErrorAndKeepsTheLastBoard() async throws {
        let sync = StubSync()
        (sync.sessions, sync.tasks) = try fixtures()
        let vm = makeViewModel(sync)
        await vm.load()
        let lanesBefore = vm.board.lanes.count
        sync.failNext = true
        await vm.load()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.board.lanes.count, lanesBefore, "a failed refresh must not blank the board")
    }

    func testDemoModeRendersLanesWithoutAGateway() async {
        let vm = BoardViewModel(sync: DemoSyncSource(), isConfigured: false)
        await vm.load()
        XCTAssertGreaterThanOrEqual(vm.board.lanes.count, 3, "demo board stands alone for screenshots")
        XCTAssertTrue(vm.board.lanes.contains { !($0.columns[.running] ?? []).isEmpty })
        XCTAssertNil(vm.error)
    }

    func testAgentFilterNarrowsTheBoard() async throws {
        let sync = StubSync()
        (sync.sessions, sync.tasks) = try fixtures()
        let vm = makeViewModel(sync)
        await vm.load()
        vm.agentFilter = "writer"
        XCTAssertFalse(vm.board.isEmpty)
        XCTAssertTrue(vm.board.lanes.flatMap(\.cards).allSatisfy { $0.session.agentId == "writer" })
        vm.agentFilter = nil
        XCTAssertTrue(vm.board.lanes.flatMap(\.cards).contains { $0.session.agentId == "main" })
    }
}
