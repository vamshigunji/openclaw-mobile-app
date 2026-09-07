import XCTest
@testable import OpenClawMobile

/// First-run gate (loop P1.1): a stranger sees what this app talks to, and what pairing
/// does, before anyone asks them for a setup code. It shows once and never returns.
@MainActor
final class FirstRunTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "first-run-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testShowsOnAFreshInstall() {
        let gate = FirstRunGate(defaults: defaults, isConfigured: false)
        XCTAssertTrue(gate.shouldShow, "a fresh install has never seen the explanation")
    }

    func testHiddenOnceDismissed() {
        var gate = FirstRunGate(defaults: defaults, isConfigured: false)
        gate.markSeen()
        XCTAssertFalse(gate.shouldShow)
        // A new instance reads the same store — the answer survives a relaunch.
        XCTAssertFalse(FirstRunGate(defaults: defaults, isConfigured: false).shouldShow)
    }

    func testNeverShowsForAnAlreadyPairedDevice() {
        // Upgrading from an older build: a host is configured, so this is not a first run.
        let gate = FirstRunGate(defaults: defaults, isConfigured: true)
        XCTAssertFalse(gate.shouldShow, "someone already paired; do not explain pairing to them")
    }

    func testCopyNamesTheGatewayAndWhatPairingDoes() {
        // The screen has to answer "what is this talking to?" and "what am I agreeing to?"
        let body = FirstRunGate.explanation.joined(separator: " ").lowercased()
        XCTAssertTrue(body.contains("gateway"), "say what it connects to")
        XCTAssertTrue(body.contains("own"), "say it is the user's own server, not ours")
        XCTAssertTrue(body.contains("key"), "say pairing creates a key for this device")
        XCTAssertFalse(body.contains("lorem"))
        for line in FirstRunGate.explanation {
            XCTAssertFalse(line.isEmpty)
            XCTAssertLessThan(line.count, 200, "keep each line readable on a phone")
        }
        XCTAssertFalse(FirstRunGate.title.isEmpty)
        XCTAssertFalse(FirstRunGate.continueTitle.isEmpty)
    }
}
