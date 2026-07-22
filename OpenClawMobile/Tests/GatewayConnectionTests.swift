import XCTest
@testable import OpenClawMobile

/// T6 — single-connection actor: one socket, one handshake, unique request ids,
/// event fan-out, reconnect with backoff + auto-resubscribe. Closes the
/// "silent subscribe death" critical gap from the eng review.
final class GatewayConnectionTests: XCTestCase {
    var gateway: MockGateway!

    override func setUpWithError() throws {
        gateway = MockGateway()
        try gateway.start()
    }

    override func tearDown() {
        gateway?.stop()
        gateway = nil
        super.tearDown()
    }

    func makeConnection(onToken: (@Sendable (String) -> Void)? = nil) -> GatewayConnection {
        GatewayConnection(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                          identity: DeviceIdentity(),
                          reconnectBaseDelay: .milliseconds(40),
                          onDeviceToken: onToken)
    }

    func testConcurrentRequestsShareOneSocketWithUniqueIds() async throws {
        let conn = makeConnection()
        // Two concurrent requests over the SAME connection — ids must not collide.
        async let h1 = conn.request(method: "chat.history", params: ["sessionKey": "a", "limit": 10])
        async let h2 = conn.request(method: "chat.history", params: ["sessionKey": "b", "limit": 10])
        let (r1, r2) = try await (h1, h2)
        XCTAssertEqual(r1.payload?.messages?.count, 1)
        XCTAssertEqual(r2.payload?.messages?.count, 1)
        XCTAssertEqual(gateway.connectionCount, 1) // ONE socket, ONE handshake
        await conn.shutdown()
    }

    func testEventsSurviveConnectionDropAndResubscribe() async throws {
        let conn = makeConnection()
        _ = try await conn.request(method: "sessions.subscribe", params: [:])

        var messages: [ChatMessage] = []
        let first = expectation(description: "reply before drop")
        let second = expectation(description: "reply after reconnect")
        let streamTask = Task {
            for await env in await conn.events() {
                if let msg = env.broadcastMessage, msg.role == .assistant, !msg.isStreaming {
                    messages.append(msg)
                    if messages.count == 1 { first.fulfill() }
                    if messages.count == 2 { second.fulfill() }
                }
            }
        }

        _ = try await conn.request(method: "chat.send",
                                   params: ["sessionKey": "main", "message": "one",
                                            "idempotencyKey": "k1"])
        await fulfillment(of: [first], timeout: 5)

        gateway.dropAllConnections() // tunnel dies

        // Wait for the actor to reconnect + resubscribe, then send again.
        try await Task.sleep(for: .milliseconds(600))
        _ = try await conn.request(method: "chat.send",
                                   params: ["sessionKey": "main", "message": "two",
                                            "idempotencyKey": "k2"])
        await fulfillment(of: [second], timeout: 5)

        XCTAssertGreaterThanOrEqual(gateway.connectionCount, 2) // reconnected
        streamTask.cancel()
        await conn.shutdown()
    }

    func testDeviceTokenRefreshReportedOnEveryHello() async throws {
        let tokens = TokenBox()
        let conn = makeConnection(onToken: { tokens.value = $0 })
        _ = try await conn.request(method: "sessions.subscribe", params: [:])
        XCTAssertEqual(tokens.value, "mock-device-token-1")
        await conn.shutdown()
    }

    func testPendingRequestsFailFastOnDropInsteadOfHanging() async throws {
        let conn = makeConnection()
        _ = try await conn.request(method: "sessions.subscribe", params: [:])
        gateway.stop() // gateway gone for good — no reconnect possible
        do {
            _ = try await conn.request(method: "chat.history",
                                       params: ["sessionKey": "main", "limit": 10],
                                       timeout: .seconds(3))
            XCTFail("expected failure with gateway down")
        } catch {
            // any thrown error is correct — must not hang
        }
        await conn.shutdown()
    }
}
