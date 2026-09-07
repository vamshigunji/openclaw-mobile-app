import XCTest
@testable import OpenClawMobile

/// Pairing failures must each name their own fix (loop P1.2). A raw error string is not a
/// recovery instruction, and two different problems must not read the same.
final class PairingFailureCopyTests: XCTestCase {
    private let reasons: [PairingFlow.FailureReason] = [
        .expiredCode, .badHost, .unreachable, .timeout, .cameraDenied,
    ]

    func testEveryReasonHasADistinctHeadlineAndRecovery() {
        let headlines = reasons.map(\.headline)
        let recoveries = reasons.map(\.recovery)
        XCTAssertEqual(Set(headlines).count, reasons.count, "two failures must not read alike")
        XCTAssertEqual(Set(recoveries).count, reasons.count)
        for reason in reasons {
            XCTAssertFalse(reason.headline.isEmpty)
            XCTAssertGreaterThan(reason.recovery.count, 25, "\(reason): say what to do, not just what broke")
        }
    }

    func testRecoveryTextNamesAnActionNotAnErrorCode() {
        let verbs = ["scan", "check", "start", "approve", "paste", "generate", "make sure", "open"]
        for reason in reasons {
            let text = reason.recovery.lowercased()
            XCTAssertTrue(verbs.contains { text.contains($0) }, "\(reason) recovery must tell the user what to do")
            // No raw SCREAMING_CASE codes leaking into user-facing copy.
            XCTAssertNil(text.range(of: "[A-Z_]{6,}", options: .regularExpression),
                         "\(reason) leaks an error code")
        }
    }

    // MARK: - Mapping real errors onto the right reason

    func testUnreachableHostMapsToUnreachable() {
        XCTAssertEqual(PairingFlow.FailureReason.from(GatewayError.unreachable("connection lost")), .unreachable)
        XCTAssertEqual(PairingFlow.FailureReason.from(URLError(.cannotConnectToHost)), .unreachable)
        XCTAssertEqual(PairingFlow.FailureReason.from(URLError(.timedOut)), .unreachable)
        XCTAssertEqual(PairingFlow.FailureReason.from(URLError(.networkConnectionLost)), .unreachable)
    }

    func testBadHostMapsToBadHost() {
        XCTAssertEqual(PairingFlow.FailureReason.from(URLError(.cannotFindHost)), .badHost)
        XCTAssertEqual(PairingFlow.FailureReason.from(URLError(.unsupportedURL)), .badHost)
        XCTAssertEqual(PairingFlow.FailureReason.from(GatewayError.unreachable("bad host URL")), .badHost)
    }

    func testExpiredBootstrapMapsToExpiredCode() {
        XCTAssertEqual(PairingFlow.FailureReason.from(GatewayError.bootstrapExpired), .expiredCode)
    }

    func testUnknownErrorFallsBackToOtherButStillGivesRecoveryText() {
        struct Weird: Error {}
        let reason = PairingFlow.FailureReason.from(Weird())
        guard case .other = reason else { return XCTFail("unknown errors keep their detail") }
        XCTAssertGreaterThan(reason.recovery.count, 25)
        XCTAssertFalse(reason.headline.isEmpty)
    }
}
