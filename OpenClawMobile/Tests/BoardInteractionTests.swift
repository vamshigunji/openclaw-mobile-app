import XCTest
@testable import OpenClawMobile

/// Board writes (design §5.5). Every gesture maps to exactly one real RPC; the frames are
/// asserted against the in-process mock gateway, and a rejected write rolls the board back.
@MainActor
final class BoardInteractionTests: XCTestCase {
    var gateway: MockGateway!

    override func setUp() async throws {
        gateway = MockGateway()
        gateway.sessionsFixture = try fixtureData("sessions.list.json")
        gateway.tasksFixture = try fixtureData("tasks.list.json")
        try gateway.start()
    }

    override func tearDown() async throws {
        gateway?.stop()
        gateway = nil
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)"))
    }

    private func loadedBoard() async throws -> BoardViewModel {
        let sync = GatewayWSSyncSource(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                                       identity: DeviceIdentity())
        let vm = BoardViewModel(sync: sync, isConfigured: true)
        await vm.load()
        XCTAssertFalse(vm.board.isEmpty, "fixtures should load over the wire")
        return vm
    }

    private func params(of method: String) throws -> [String: Any] {
        let frame = try XCTUnwrap(gateway.receivedFrames.last { ($0["method"] as? String) == method },
                                  "no \(method) frame was sent")
        return try XCTUnwrap(frame["params"] as? [String: Any])
    }

    // MARK: - Archive / unarchive

    func testArchiveSendsPatchWithExpectedSessionId() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:main:task-attach"))
        await vm.archive(card, archived: true)

        let p = try params(of: "sessions.patch")
        XCTAssertEqual(p["key"] as? String, "agent:main:task-attach")
        XCTAssertEqual(p["expectedSessionId"] as? String, "s-task-0002", "guards against a stale row")
        XCTAssertEqual(p["archived"] as? Bool, true)
        XCTAssertEqual(vm.board.card("agent:main:task-attach")?.column, .done, "moves optimistically")
    }

    func testUnarchiveSendsArchivedFalse() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:main:task-old"))
        XCTAssertEqual(card.column, .done)
        await vm.archive(card, archived: false)
        XCTAssertEqual(try params(of: "sessions.patch")["archived"] as? Bool, false)
    }

    // MARK: - Lane move

    func testLaneMoveSendsOnlyCategory() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:main:task-attach"))
        await vm.move(card, toLane: "Website redesign")

        let p = try params(of: "sessions.patch")
        XCTAssertEqual(p["category"] as? String, "Website redesign")
        XCTAssertNil(p["archived"], "a lane move must not touch archived state")
        XCTAssertTrue(vm.board.lanes.contains { $0.key == "Website redesign" &&
            $0.cards.contains { $0.id == "agent:main:task-attach" } })
    }

    func testLaneNamesOfferedAreTheOnesOnTheBoard() async throws {
        let vm = try await loadedBoard()
        XCTAssertEqual(Set(vm.laneNames), ["openclaw-mobile-app", "Website redesign", "Researcher"])
    }

    // MARK: - Start a backlog card

    func testStartSendsChatSendToTheCardsSession() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:researcher:read-rfc"))
        XCTAssertEqual(card.column, .backlog)
        await vm.start(card, note: "focus on the handshake section")

        let p = try params(of: "chat.send")
        XCTAssertEqual(p["sessionKey"] as? String, "agent:researcher:read-rfc")
        XCTAssertEqual(p["agentId"] as? String, "researcher")
        let message = try XCTUnwrap(p["message"] as? String)
        XCTAssertTrue(message.contains("Summarize the transport RFC"), "the card title is the ask")
        XCTAssertTrue(message.contains("focus on the handshake section"), "extra notes ride along")
    }

    func testStartWithoutNotesSendsJustTheTitle() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:researcher:read-rfc"))
        await vm.start(card, note: "")
        XCTAssertEqual(try params(of: "chat.send")["message"] as? String, "Summarize the transport RFC")
    }

    // MARK: - Stop and cancel

    func testStopRunSendsChatAbort() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:main:task-attach"))
        await vm.stop(card)
        let p = try params(of: "chat.abort")
        XCTAssertEqual(p["sessionKey"] as? String, "agent:main:task-attach")
        XCTAssertEqual(p["agentId"] as? String, "main")
    }

    func testCancelTaskSendsTasksCancelWithItsId() async throws {
        let vm = try await loadedBoard()
        let card = try XCTUnwrap(vm.board.card("agent:main:task-attach"))
        let task = try XCTUnwrap(card.tasks.first { $0.status == .running })
        await vm.cancel(task)
        XCTAssertEqual(try params(of: "tasks.cancel")["taskId"] as? String, task.id)
    }

    // MARK: - New task

    func testNewTaskSendsSessionsCreate() async throws {
        let vm = try await loadedBoard()
        await vm.createTask(title: "Audit the keychain code", agentId: "main", lane: "openclaw-mobile-app")
        let p = try params(of: "sessions.create")
        XCTAssertEqual(p["agentId"] as? String, "main")
        XCTAssertEqual(p["label"] as? String, "Audit the keychain code")
        XCTAssertEqual(p["category"] as? String, "openclaw-mobile-app")
        XCTAssertNil(p["message"], "creating a card does not start the work")
    }

    // MARK: - Failure rollback

    func testRejectedPatchRestoresTheBoardAndReportsWhy() async throws {
        let vm = try await loadedBoard()
        let before = vm.board.card("agent:main:task-attach")?.column
        gateway.failNextPatch = true
        let card = try XCTUnwrap(vm.board.card("agent:main:task-attach"))
        await vm.archive(card, archived: true)

        XCTAssertEqual(vm.board.card("agent:main:task-attach")?.column, before,
                       "a rejected write rolls the optimistic move back")
        XCTAssertNotNil(vm.error)
    }
}
