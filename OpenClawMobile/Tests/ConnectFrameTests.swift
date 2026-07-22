import XCTest
@testable import OpenClawMobile

/// Connect-frame shape per .docs/protocol.md §4 (LIVE-verified fields).
final class ConnectFrameTests: XCTestCase {
    func params(_ frame: [String: Any]) -> [String: Any] { frame["params"] as! [String: Any] }

    func testTokenConnectCarriesSignedDevice() throws {
        let id = DeviceIdentity()
        let device = try DeviceAuth.deviceParams(
            identity: id, nonce: "n1", role: "operator",
            scopes: ["operator.read", "operator.write"],
            signatureToken: "tok", signedAtMs: 1)
        let frame = GatewayFrames.connect(auth: .token("tok"), device: device)
        let p = params(frame)
        XCTAssertEqual(frame["method"] as? String, "connect")
        XCTAssertEqual((p["client"] as? [String: Any])?["id"] as? String, "openclaw-ios")
        XCTAssertEqual((p["auth"] as? [String: String])?["token"], "tok")
        XCTAssertNil((p["auth"] as? [String: String])?["bootstrapToken"])
        XCTAssertEqual((p["device"] as? [String: Any])?["id"] as? String, id.deviceId)
        XCTAssertEqual(p["scopes"] as? [String], ["operator.read", "operator.write"])
        XCTAssertEqual(p["role"] as? String, "operator")
        // must be JSON-serializable
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: frame))
    }

    func testPairingConnectUsesBootstrapTokenField() throws {
        let frame = GatewayFrames.connect(auth: .bootstrap("SETUP-123"), device: nil)
        let auth = params(frame)["auth"] as? [String: String]
        XCTAssertEqual(auth?["bootstrapToken"], "SETUP-123")
        XCTAssertNil(auth?["token"])
    }

    func testEmptyAuthWhenNoCredentials() throws {
        let frame = GatewayFrames.connect(auth: .none, device: nil)
        XCTAssertEqual((params(frame)["auth"] as? [String: String])?.isEmpty, true)
    }
}
