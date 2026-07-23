import XCTest
@testable import OpenClawMobile

/// E2E against the in-process protocol-v4 mock gateway (T4).
/// Exercises the REAL client stack — GatewayWSSyncSource sockets, DeviceAuth
/// signing, PairingFlow retries — over real WebSockets on loopback. The mock
/// verifies the Ed25519 signature server-side, so these tests fail if the
/// serialization ever drifts from the live-verified protocol.
final class MockGatewayE2ETests: XCTestCase {
    var gateway: MockGateway!

    override func tearDown() {
        gateway?.stop()
        gateway = nil
        super.tearDown()
    }

    @MainActor
    func testFullPairingLadderThroughApproval() async throws {
        gateway = MockGateway(pendingApprovalsBeforeOK: 2)
        try gateway.start()

        let flow = PairingFlow(retryDelay: .milliseconds(50))
        var storedToken: String?
        let code = SetupCode(url: gateway.wsHost, bootstrapToken: "mock-bootstrap")
        let runner = PairingFlow.gatewayRunner(host: gateway.wsHost, code: code)

        let outcome = await flow.pair(runOnce: runner) { storedToken = $0 }

        XCTAssertEqual(outcome, .paired)
        XCTAssertEqual(storedToken, "mock-device-token-1")
        XCTAssertEqual(flow.lastRequestId, "mock-req-0001") // surfaced from PAIRING_REQUIRED
        XCTAssertGreaterThanOrEqual(gateway.verifiedSignatures, 3) // every attempt signed + verified
    }

    @MainActor
    func testExpiredCodeSurfacesRecoveryState() async throws {
        gateway = MockGateway(expiredCode: true)
        try gateway.start()

        let flow = PairingFlow(retryDelay: .milliseconds(50))
        let code = SetupCode(url: gateway.wsHost, bootstrapToken: "stale")
        let outcome = await flow.pair(
            runOnce: PairingFlow.gatewayRunner(host: gateway.wsHost, code: code)) { _ in }

        XCTAssertEqual(outcome, .failed)
        if case .failed(.expiredCode) = flow.step {} else {
            XCTFail("expected expiredCode, got \(flow.step)")
        }
    }

    func testChatRoundTripStreamsReply() async throws {
        gateway = MockGateway(replyText: "Streamed reply over loopback.")
        try gateway.start()

        let source = GatewayWSSyncSource(
            host: gateway.wsHost, auth: .token("mock-device-token-1"),
            identity: DeviceIdentity())

        // Subscribe (fan-in) and send on separate sockets — current architecture.
        var received: [ChatMessage] = []
        let gotFinal = expectation(description: "assistant final received")
        let subTask = Task {
            for try await msg in source.subscribe(agentId: nil) {
                received.append(msg)
                if msg.role == .assistant, !msg.isStreaming { gotFinal.fulfill(); break }
            }
        }
        try await Task.sleep(for: .milliseconds(300)) // let subscribe attach

        try await source.send(agentId: "main", text: "hi mock", idempotencyKey: "e2e-idem-1")

        await fulfillment(of: [gotFinal], timeout: 10)
        subTask.cancel()

        // Echo of our own send arrives with the client's idempotencyKey restored
        XCTAssertTrue(received.contains { $0.role == .user && $0.clientMessageId == "e2e-idem-1" })
        // Streaming updates share the stable chat-run key; final has full text
        let finals = received.filter { $0.role == .assistant && !$0.isStreaming }
        XCTAssertEqual(finals.last?.text, "Streamed reply over loopback.")
        XCTAssertEqual(finals.last?.clientMessageId, "chat-run:e2e-idem-1")
    }

    func testHistoryBackfill() async throws {
        gateway = MockGateway()
        try gateway.start()
        let source = GatewayWSSyncSource(
            host: gateway.wsHost, auth: .token("mock-device-token-1"),
            identity: DeviceIdentity())
        let history = try await source.loadHistory(agentId: "main")
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.text, "Prior message from history.")
    }
}
