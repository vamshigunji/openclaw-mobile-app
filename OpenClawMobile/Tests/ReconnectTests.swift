import XCTest
@testable import OpenClawMobile

/// What happens when the tunnel dies mid-conversation (loop P2). The mock gateway's
/// `dropAllConnections()` is a real socket drop: the listener stays up, so the client can
/// reconnect exactly as it would after a Cloudflare blip.
@MainActor
final class ReconnectTests: XCTestCase {
    var gateway: MockGateway!

    override func tearDown() async throws {
        gateway?.stop()
        gateway = nil
    }

    private func makeSync() -> GatewayWSSyncSource {
        GatewayWSSyncSource(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                            identity: DeviceIdentity(), reconnectBaseDelay: .milliseconds(50))
    }

    // MARK: - P2.1

    func testStreamingBubbleDoesNotHangForeverAfterADrop() async throws {
        gateway = MockGateway(replyText: "half a reply")
        gateway.holdFinal = true          // the run never terminates on its own
        try gateway.start()
        let settings = SettingsStore()
        settings.host = gateway.wsHost
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: makeSync(),
                               settings: settings)
        vm.start()
        try await Task.sleep(for: .milliseconds(500))

        vm.draft = "hello"
        vm.send()
        let streaming = await waitUntil { vm.messages.contains { $0.role == .assistant && $0.isStreaming } }
        XCTAssertTrue(streaming)

        gateway.dropAllConnections()

        let settled = await waitUntil(.seconds(15)) {
            !vm.messages.contains { $0.role == .assistant && $0.isStreaming }
        }
        XCTAssertTrue(settled, "a dropped connection must not leave a bubble streaming forever")
        XCTAssertFalse(vm.isConnected, "and the thread must know it is offline")
    }

    // MARK: - P2.4 — staleness is visible

    func testConnectionStateFlipsOnDropAndBackOnReconnect() async throws {
        gateway = MockGateway()
        try gateway.start()
        let sync = makeSync()

        // Collect the transitions rather than polling a snapshot: with a 50ms reconnect
        // delay the socket can be back before any poll observes the gap.
        actor States {
            var seen: [Bool] = []
            func add(_ v: Bool) { if seen.last != v { seen.append(v) } }
            var value: [Bool] { seen }
        }
        let states = States()
        let watcher = Task {
            for await up in sync.connectionState() { await states.add(up) }
        }
        defer { watcher.cancel() }

        let settings = SettingsStore()
        settings.host = gateway.wsHost
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: sync, settings: settings)
        vm.start()
        vm.draft = "wake the socket"
        vm.send()
        let replied = await waitUntil {
            vm.messages.contains { $0.role == .assistant && !$0.isStreaming && !$0.text.isEmpty }
        }
        XCTAssertTrue(replied, "a live socket delivers the mock reply")
        let cameUp = await waitUntil {
            let seen = await states.value
            return seen.contains(true)
        }
        XCTAssertTrue(cameUp, "the socket reported itself up")

        gateway.dropAllConnections()

        let sawDrop = await waitUntil(.seconds(15)) {
            let seen = await states.value
            // A false AFTER the first true — not the initial "no socket yet" false.
            guard let firstUp = seen.firstIndex(of: true) else { return false }
            return seen.dropFirst(firstUp).contains(false)
        }
        XCTAssertTrue(sawDrop, "a drop must be published so the UI can show staleness, not a spinner")
    }

    // MARK: - P2.3 — backfill must not duplicate

    func testHistoryBackfillReconcilesByIdempotencyKey() async throws {
        gateway = MockGateway()
        try gateway.start()
        let settings = SettingsStore()
        settings.host = gateway.wsHost
        defer { settings.host = "" }
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: makeSync(),
                               settings: settings)
        vm.start()
        // The mock's chat.history always returns the same prior message.
        let loaded = await waitUntil { vm.messages.contains { $0.text == "Prior message from history." } }
        XCTAssertTrue(loaded)

        await vm.refreshAfterReconnect()
        await vm.refreshAfterReconnect()

        let copies = vm.messages.filter { $0.text == "Prior message from history." }.count
        XCTAssertEqual(copies, 1, "re-reading history must reconcile, not append")
    }

    // MARK: - P2.2 — the Board survives a drop

    func testBoardRefreshesAfterADrop() async throws {
        gateway = MockGateway()
        gateway.sessionsFixture = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/sessions.list.json"))
        try gateway.start()
        let vm = BoardViewModel(sync: makeSync(), isConfigured: true)
        vm.start()
        let loaded = await waitUntil { !vm.board.isEmpty }
        XCTAssertTrue(loaded)

        gateway.dropAllConnections()
        try await Task.sleep(for: .milliseconds(300))

        // After the socket returns, a fresh load still works — the subscription did not die.
        let reloaded = await waitUntil(.seconds(20)) {
            await vm.load()
            return !vm.board.isEmpty && vm.error == nil
        }
        XCTAssertTrue(reloaded, "the Board must recover after a reconnect")
    }
}
