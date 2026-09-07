import XCTest
@testable import OpenClawMobile

/// A thread's view model must go away when its view does, even while its four live event
/// loops are parked on streams that never finish (the shared connection is never torn down).
final class ChatViewModelLifecycleTests: XCTestCase {
    /// Streams that stay open forever, like a live gateway connection.
    private final class HoldingSync: SyncSource, @unchecked Sendable {
        var continuations: [Any] = []
        func listAgents() async throws -> [AgentSummary] { [] }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> {
            AsyncThrowingStream { self.continuations.append($0) }
        }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> {
            AsyncStream { self.continuations.append($0) }
        }
        func toolEvents(sessionKey: String) -> AsyncStream<ToolEvent> { AsyncStream { self.continuations.append($0) } }
        func runEnds(sessionKey: String) -> AsyncStream<String> { AsyncStream { self.continuations.append($0) } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { nil }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
    }

    @MainActor
    func testViewModelDeallocatesWhileStreamsAreOpen() async {
        let sync = HoldingSync()
        weak var weakVM: ChatViewModel?
        do {
            let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: sync, settings: SettingsStore())
            vm.start()
            weakVM = vm
            let subscribed = await waitUntil { sync.continuations.count == 4 }
            XCTAssertTrue(subscribed, "all four loops should be parked on open streams")
        }
        let gone = await waitUntil { weakVM == nil }
        XCTAssertTrue(gone, "the view model leaked: its subscription tasks retain it")
    }
}
