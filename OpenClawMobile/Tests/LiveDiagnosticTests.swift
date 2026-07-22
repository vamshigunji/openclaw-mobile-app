import XCTest
@testable import OpenClawMobile

/// TEMPORARY live-network diagnostics (2026-07-22): pairing failed in-app with
/// "Could not connect to the server" while Safari-in-sim reaches the tunnel.
/// Isolates the failing layer. Skipped unless LIVE_HOST is set.
final class LiveDiagnosticTests: XCTestCase {
    static let host = ProcessInfo.processInfo.environment["LIVE_HOST"] ?? ""

    override func setUpWithError() throws {
        try XCTSkipIf(Self.host.isEmpty, "LIVE_HOST not set")
    }

    func testA_HTTPSHealthFromSimulator() async throws {
        let url = URL(string: Self.host.replacingOccurrences(of: "wss://", with: "https://"))!
            .appendingPathComponent("health")
        let (data, resp) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("ok"))
    }

    func testB_RawWebSocketReceivesChallenge() async throws {
        let wsURL = try XCTUnwrap(GatewayWSSyncSource.wsURL(host: Self.host))
        print("DIAG wsURL = \(wsURL.absoluteString)")
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        let msg = try await task.receive() // gateway sends connect.challenge first
        task.cancel(with: .goingAway, reason: nil)
        if case .string(let s) = msg {
            print("DIAG first frame: \(s.prefix(120))")
            XCTAssertTrue(s.contains("connect.challenge"))
        } else {
            XCTFail("expected string frame")
        }
    }

    func testC_ConnectOnceWithGarbageBootstrapGetsProtocolError() async {
        let source = GatewayWSSyncSource(
            host: Self.host, auth: .bootstrap("garbage-token-diagnostic"),
            identity: DeviceIdentity())
        do {
            try await source.connectOnce()
            XCTFail("garbage bootstrap should not connect")
        } catch let e as GatewayError {
            // ANY GatewayError besides .unreachable proves transport + handshake work
            if case .unreachable(let m) = e { XCTFail("transport failed: \(m)") }
        } catch {
            XCTFail("transport-level error: \(error.localizedDescription)")
        }
    }
}
