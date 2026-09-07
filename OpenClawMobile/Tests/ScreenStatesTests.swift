import XCTest
@testable import OpenClawMobile

/// Empty states, error states, and control labels (loop P4.1, P4.2, P4.4). A screen with
/// nothing on it must say why, and a failure must never surface a raw code.
@MainActor
final class ScreenStatesTests: XCTestCase {
    /// A seam that fails every call.
    private final class FailingSync: SyncSource, @unchecked Sendable {
        func listAgents() async throws -> [AgentSummary] { throw GatewayError.unreachable("gateway is down") }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> { AsyncThrowingStream { $0.finish() } }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { nil }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
        func listSessions() async throws -> [SessionSummary] { throw GatewayError.unreachable("gateway is down") }
        func listTasks() async throws -> [TaskSummary] { [] }
    }

    /// A seam that succeeds with nothing in it.
    private final class EmptySync: SyncSource, @unchecked Sendable {
        func listAgents() async throws -> [AgentSummary] { [] }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> { AsyncThrowingStream { $0.finish() } }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { nil }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
        func listSessions() async throws -> [SessionSummary] { [] }
        func listTasks() async throws -> [TaskSummary] { [] }
    }

    // MARK: - P4.1 empty states

    func testEmptyBoardIsEmptyRatherThanFabricated() async {
        let vm = BoardViewModel(sync: EmptySync(), isConfigured: true)
        await vm.load()
        XCTAssertTrue(vm.board.isEmpty, "no sessions means no cards — never invented ones")
        XCTAssertNil(vm.error, "empty is not an error")
    }

    func testEveryBoardColumnHasEmptyCopy() {
        for column in BoardColumn.allCases {
            XCTAssertFalse(column.title.isEmpty)
            XCTAssertFalse(column.symbol.isEmpty, "\(column) needs an icon for its empty state")
        }
    }

    func testRosterNeverDeadEndsWhenTheGatewayReturnsNothing() async {
        let vm = AgentRosterViewModel(sync: EmptySync(), isConfigured: true)
        await vm.load()
        XCTAssertFalse(vm.agents.isEmpty, "fall back to main so the user always has a thread")
    }

    // MARK: - P4.1 error states

    func testBoardSurfacesAFailureWithoutBlankingTheScreen() async {
        let vm = BoardViewModel(sync: FailingSync(), isConfigured: true)
        await vm.load()
        let error = try? XCTUnwrap(vm.error)
        XCTAssertNotNil(error)
    }

    func testRosterSurfacesAFailureAndStillOffersAThread() async {
        let vm = AgentRosterViewModel(sync: FailingSync(), isConfigured: true)
        await vm.load()
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.agents.isEmpty, "a failed roster still leaves somewhere to go")
    }

    // MARK: - P4.2 error copy

    func testUserFacingErrorsAreSentencesNotCodes() async {
        let vm = BoardViewModel(sync: FailingSync(), isConfigured: true)
        await vm.load()
        let message = vm.error ?? ""
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(message.range(of: "[A-Z_]{6,}", options: .regularExpression),
                     "a raw code is not something a user can act on: \(message)")
    }

    func testGatewayErrorsAllHaveHumanDescriptions() {
        let errors: [GatewayError] = [
            .unauthorized, .unreachable("host down"), .badStatus(500),
            .pairingPending(requestId: "req-1"), .bootstrapExpired,
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertGreaterThan(text.count, 10, "\(error) needs a readable description")
            XCTAssertNil(text.range(of: "[A-Z_]{6,}", options: .regularExpression), "\(error) leaks a code")
        }
    }

    // MARK: - P4.4 every icon-only control is labelled

    func testNoIconOnlyControlIsMissingAnAccessibilityLabel() throws {
        let features = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Features")
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil)
        for case let url as URL in files! where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where line.contains("Button") || line.contains("label: {") {
                // A control whose visible content is only an Image needs a spoken name.
                // The window spans a full SwiftUI styling chain — a labelled control can
                // carry a dozen modifiers between the Image and its accessibilityLabel.
                let window = lines[i..<min(i + 16, lines.count)].joined(separator: "\n")
                let iconOnly = window.contains("Image(systemName:")
                    && window.range(of: #"\bText\(|\bLabel\("#, options: .regularExpression) == nil
                if iconOnly && !window.contains("accessibilityLabel") {
                    offenders.append("\(url.lastPathComponent):\(i + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "icon-only controls VoiceOver cannot name")
    }
}
