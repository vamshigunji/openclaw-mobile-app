import XCTest
@testable import OpenClawMobile

/// Stop and Retry (design §4.6). Stop is exercised end-to-end against the in-process mock
/// gateway (real sockets, real `chat.abort` frame); Retry against a minimal flaky seam.
final class ChatStopRetryTests: XCTestCase {
    var gateway: MockGateway!

    override func tearDown() {
        gateway?.stop()
        gateway = nil
        super.tearDown()
    }

    // MARK: - Stop (P2.5)

    @MainActor
    func testStopSendsAbortAndMarksAborted() async throws {
        gateway = MockGateway(replyText: "a long reply that will be cut short")
        gateway.holdFinal = true // deltas arrive, the final never does → the run stays active
        try gateway.start()
        let (vm, settings) = makeChatViewModel(gateway: gateway)
        defer { settings.host = "" }
        let thread = vm.thread
        try await Task.sleep(for: .milliseconds(500)) // let subscribe attach (CI headroom)

        vm.draft = "stop me"
        vm.send()
        let streaming = await waitUntil { vm.messages.contains { $0.role == .assistant && $0.isStreaming } }
        XCTAssertTrue(streaming, "expected a streaming assistant bubble before stopping")
        XCTAssertTrue(vm.canStop)
        vm.draft = "a follow-up typed mid-run"
        XCTAssertFalse(vm.canSend, "sending is blocked while a run is active — the button stays Stop")

        await vm.stop()

        let aborted = await waitUntil { self.gateway.receivedMethods.contains("chat.abort") }
        XCTAssertTrue(aborted, "chat.abort should reach the gateway")
        let abort = gateway.receivedFrames.last { ($0["method"] as? String) == "chat.abort" }
        let params = abort?["params"] as? [String: Any]
        XCTAssertEqual(params?["sessionKey"] as? String, thread.sessionKey)
        XCTAssertEqual(params?["agentId"] as? String, "main")
        let bubble = vm.messages.last { $0.role == .assistant }
        XCTAssertEqual(bubble?.aborted, true, "stopped run is marked aborted…")
        XCTAssertEqual(bubble?.failed, false, "…not failed")
        XCTAssertEqual(bubble?.isStreaming, false)
        XCTAssertFalse(vm.canStop)
    }

    /// Seam whose abort always fails; send acks with the idempotency key as runId.
    private final class AbortFailsSync: SyncSource, @unchecked Sendable {
        func listAgents() async throws -> [AgentSummary] { [] }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> { AsyncThrowingStream { $0.finish() } }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { idempotencyKey }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {
            throw GatewayError.unreachable("abort failed")
        }
    }

    @MainActor
    func testStopKeepsRunArmedWhenAbortFails() async throws {
        let settings = SettingsStore()
        settings.host = "wss://stub.invalid"
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: AbortFailsSync(), settings: settings)
        vm.draft = "go"
        vm.send()
        let armed = await waitUntil { vm.canStop }
        XCTAssertTrue(armed)

        await vm.stop()

        XCTAssertTrue(vm.canStop, "the run may still be going; Stop stays available")
        XCTAssertFalse(vm.messages.contains { $0.aborted }, "nothing is marked aborted on a failed abort")
    }

    /// Seam that exposes its runEnds continuation so a test can end runs by id.
    private final class RunEndSync: SyncSource, @unchecked Sendable {
        var continuation: AsyncStream<String>.Continuation?
        func listAgents() async throws -> [AgentSummary] { [] }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> { AsyncThrowingStream { $0.finish() } }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func runEnds(sessionKey: String) -> AsyncStream<String> { AsyncStream { self.continuation = $0 } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? { idempotencyKey }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
    }

    @MainActor
    func testRunEndOnlyDisarmsTheMatchingRun() async throws {
        let sync = RunEndSync()
        let settings = SettingsStore()
        settings.host = "wss://stub.invalid"
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: sync, settings: settings)
        vm.start()
        let subscribed = await waitUntil { sync.continuation != nil }
        XCTAssertTrue(subscribed)

        vm.draft = "run"
        vm.send()
        let armed = await waitUntil { vm.canStop }
        XCTAssertTrue(armed)
        let runId = try XCTUnwrap(vm.activeRunId)

        sync.continuation?.yield("some-earlier-run")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(vm.canStop, "a late terminal frame from another run must not disarm Stop")

        sync.continuation?.yield(runId)
        let disarmed = await waitUntil { !vm.canStop }
        XCTAssertTrue(disarmed, "the matching runId ends the run")
    }

    // MARK: - Retry (P2.6)

    /// Minimal seam whose `send` fails once and records every idempotency key it sees.
    private final class FlakySync: SyncSource, @unchecked Sendable {
        var keys: [String] = []
        var failuresLeft = 1
        func listAgents() async throws -> [AgentSummary] { [] }
        func loadInstructions(agentId: String) async throws -> String? { nil }
        func loadHistory(sessionKey: String, agentId: String) async throws -> [ChatMessage] { [] }
        func subscribe(sessionKey: String?) -> AsyncThrowingStream<ChatMessage, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func activityStream(sessionKey: String) -> AsyncStream<AgentActivity> { AsyncStream { $0.finish() } }
        func send(sessionKey: String, agentId: String, text: String, idempotencyKey: String,
                  attachments: [Attachment]) async throws -> String? {
            keys.append(idempotencyKey)
            if failuresLeft > 0 { failuresLeft -= 1; throw GatewayError.unreachable("flaky") }
            return idempotencyKey
        }
        func abort(sessionKey: String, agentId: String, runId: String?) async throws {}
    }

    @MainActor
    func testRetryUsesNewIdempotencyKey() async throws {
        let sync = FlakySync()
        let settings = SettingsStore()
        settings.host = "wss://stub.invalid"
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: ChatThread.main(for: AgentSummary(id: "main")), sync: sync, settings: settings)

        vm.draft = "hello"
        vm.send()
        let failedFirst = await waitUntil { vm.messages.last?.failed == true }
        XCTAssertTrue(failedFirst, "first send should fail")
        let failed = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(failed.role, .user)

        await vm.retry(failed)

        XCTAssertEqual(sync.keys.count, 2)
        XCTAssertNotEqual(sync.keys[0], sync.keys[1], "retry must use a fresh idempotency key")
        let retried = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(retried.text, "hello")
        XCTAssertFalse(retried.failed)
        XCTAssertEqual(retried.clientMessageId, sync.keys[1])
    }
}
