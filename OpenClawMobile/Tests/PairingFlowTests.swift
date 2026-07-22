import XCTest
@testable import OpenClawMobile

/// SetupCode parsing — the wedge's front door. Accepts the QR/paste blob
/// (base64url JSON {url, bootstrapToken}), a bare inner token, and rejects garbage.
final class SetupCodeTests: XCTestCase {
    // Real shape captured live 2026-07-21 (payload of `openclaw qr`)
    static let blob = "eyJ1cmwiOiJ3c3M6Ly9jZXJ0aWZpY2F0ZXMtZ2VvZ3JhcGh5LWFyaXNpbmctdm9uLnRyeWNsb3VkZmxhcmUuY29tIiwiYm9vdHN0cmFwVG9rZW4iOiJFTXRzNVUxM2VMamNKa1ROSUl5SGh2Mk10UXRkLVY4TzRVOHU5YmRMVzhRIn0"

    func testParsesFullBlobIntoHostAndToken() throws {
        let code = try XCTUnwrap(SetupCode.parse(Self.blob))
        XCTAssertEqual(code.url, "wss://certificates-geography-arising-von.trycloudflare.com")
        XCTAssertEqual(code.bootstrapToken, "EMts5U13eLjcJkTNIIyHhv2MtQtd-V8O4U8u9bdLW8Q")
    }

    func testParsesBareInnerToken() throws {
        let code = try XCTUnwrap(SetupCode.parse("EMts5U13eLjcJkTNIIyHhv2MtQtd-V8O4U8u9bdLW8Q"))
        XCTAssertNil(code.url) // bare token carries no host
        XCTAssertEqual(code.bootstrapToken, "EMts5U13eLjcJkTNIIyHhv2MtQtd-V8O4U8u9bdLW8Q")
    }

    func testTrimsWhitespaceAndNewlines() throws {
        let code = try XCTUnwrap(SetupCode.parse("  \(Self.blob)\n"))
        XCTAssertNotNil(code.url)
    }

    func testRejectsGarbage() {
        XCTAssertNil(SetupCode.parse(""))
        XCTAssertNil(SetupCode.parse("   "))
        XCTAssertNil(SetupCode.parse("not a code!!")) // illegal base64url chars + too short
    }

    func testBlobWithMissingTokenRejected() {
        // {"url":"wss://x"} — valid JSON blob but no bootstrapToken
        let b64 = Data(#"{"url":"wss://x"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertNil(SetupCode.parse(b64))
    }
}

/// PairingFlow state machine — drives the 6-state UI from the approved mockup.
/// Transport is injected as a closure so every transition is unit-testable.
@MainActor
final class PairingFlowTests: XCTestCase {
    func testHappyPathMintsTokenAndLandsPaired() async {
        let flow = PairingFlow(retryDelay: .zero)
        var stored: String?
        let outcome = await flow.pair(
            runOnce: { .minted("tok-123") },
            storeToken: { stored = $0 })
        XCTAssertEqual(outcome, .paired)
        XCTAssertEqual(stored, "tok-123")
        if case .paired = flow.step {} else { XCTFail("expected .paired, got \(flow.step)") }
    }

    func testPendingThenApprovedSurfacesRequestIdWhileWaiting() async {
        var calls = 0
        let flow = PairingFlow(retryDelay: .zero)
        _ = await flow.pair(
            runOnce: {
                calls += 1
                if calls < 3 { throw GatewayError.pairingPending(requestId: "654180ad-7d8a") }
                return .minted("tok")
            },
            storeToken: { _ in })
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(flow.lastRequestId, "654180ad-7d8a") // UI shows the approve command
        if case .paired = flow.step {} else { XCTFail("expected .paired") }
    }

    func testTimeoutAfterMaxAttempts() async {
        let flow = PairingFlow(maxAttempts: 4, retryDelay: .zero)
        let outcome = await flow.pair(
            runOnce: { throw GatewayError.pairingPending(requestId: nil) },
            storeToken: { _ in })
        XCTAssertEqual(outcome, .timedOut)
        if case .failed(.timeout) = flow.step {} else { XCTFail("expected .failed(.timeout)") }
    }

    func testExpiredCodeFailsImmediatelyWithRecoveryHint() async {
        let flow = PairingFlow(retryDelay: .zero)
        let outcome = await flow.pair(
            runOnce: { throw GatewayError.bootstrapExpired },
            storeToken: { _ in })
        XCTAssertEqual(outcome, .failed)
        if case .failed(.expiredCode) = flow.step {} else { XCTFail("expected .failed(.expiredCode)") }
    }

    func testAlreadyPairedConnectWithoutMintStillSucceeds() async {
        let flow = PairingFlow(retryDelay: .zero)
        let outcome = await flow.pair(runOnce: { .connected }, storeToken: { _ in })
        XCTAssertEqual(outcome, .paired)
    }

    func testCancelStopsRetrying() async {
        let flow = PairingFlow(maxAttempts: 100, retryDelay: .milliseconds(5))
        var calls = 0
        async let result = flow.pair(
            runOnce: {
                calls += 1
                if calls == 2 { await flow.cancel() }
                throw GatewayError.pairingPending(requestId: nil)
            },
            storeToken: { _ in })
        let outcome = await result
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(calls, 100)
    }
}

/// requestId extraction from the live PAIRING_REQUIRED frame (captured 2026-07-21).
final class PairingErrorDecodingTests: XCTestCase {
    func testPairingRequiredCarriesRequestId() throws {
        let json = #"""
        {"type":"res","id":"p0-connect","ok":false,"error":{"code":"NOT_PAIRED","message":"pairing required: device is not approved yet","details":{"code":"PAIRING_REQUIRED","reason":"not-paired","requestId":"c5c0c4eb-3274-46eb-b54a-e10336a209f7"}}}
        """#
        let env = try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(env.errorCode, "NOT_PAIRED")
        XCTAssertTrue(env.isPairingRequired)
        XCTAssertEqual(env.pairingRequestId, "c5c0c4eb-3274-46eb-b54a-e10336a209f7")
    }

    func testBootstrapExpiredDetected() throws {
        let json = #"""
        {"type":"res","id":"p0-connect","ok":false,"error":{"code":"INVALID_REQUEST","message":"unauthorized: bootstrap token invalid or expired (scan a fresh setup code)","details":{"code":"AUTH_BOOTSTRAP_TOKEN_INVALID","authReason":"bootstrap_token_invalid"}}}
        """#
        let env = try JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
        XCTAssertTrue(env.isBootstrapInvalid)
    }
}
