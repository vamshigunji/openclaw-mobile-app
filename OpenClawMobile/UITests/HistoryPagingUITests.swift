import XCTest

/// A4 — the acceptance criterion the PRD predicted would fail first, and the one no unit
/// test can see: tapping "Load earlier messages" must leave the reader where they were,
/// NOT scroll them to the bottom.
///
/// `ChatView` scrolls to `"bottom"` whenever its tail signature changes. A prepended page
/// grows `messages.count` without changing the tail, so the handler must ignore it and the
/// anchor must restore the previously-oldest bubble. Both halves are invisible at the
/// view-model level — hence real taps.
///
/// REQUIRES the sandbox up and this device paired:
///     ./sandbox/up.sh
///     docker exec oc openclaw devices list
///     docker exec oc openclaw devices approve <requestId>
///
/// Run with:
///     xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj \
///       -scheme OpenClawMobileUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// SKIPS rather than fails when the gateway is unreachable or the session is short: an
/// absent sandbox is an environment fact, not a regression.
final class HistoryPagingUITests: XCTestCase {
    private var app: XCUIApplication!

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // OpenClawMobile
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        var alive = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(gatewayIsUp(),
                          "sandbox gateway not reachable — run ./sandbox/up.sh first")
        let token = try XCTUnwrap(sandboxToken, "sandbox/.token missing — run ./sandbox/up.sh")
        app = XCUIApplication()
        // NOT --seed-demo: that sends a live message and fires a real run on the agent.
        app.launchArguments = ["--skip-first-run"]
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token]
        app.launch()
    }

    /// Opens the first agent's thread by tapping it, the way a person would.
    private func openFirstThread() throws {
        let firstRow = app.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20),
                      "agent roster never rendered — is the device approved?")
        firstRow.tap()
    }

    private var loadEarlier: XCUIElement { app.buttons["Load earlier messages"] }

    /// The topmost message bubble realised in the thread, excluding the row's own label.
    ///
    /// Deliberately ONE element resolution. An earlier version enumerated
    /// `app.staticTexts.allElementsBoundByIndex` and hung the test host for the full 600s
    /// timeout against a 239-message thread — XCUITest builds the whole accessibility
    /// snapshot for that, and a chat thread is a big one.
    private func topmostBubble() -> XCUIElement {
        app.scrollViews.firstMatch
            .staticTexts
            .matching(NSPredicate(format: "label != %@ AND label != %@",
                                  "Load earlier messages", "Beginning of conversation"))
            .element(boundBy: 0)
    }

    /// The label of a bubble near the top that occurs EXACTLY ONCE in the thread, so it can
    /// be re-found after paging. Short turns ("ok", "yes") repeat constantly in a real
    /// transcript and make a label-based anchor meaningless.
    ///
    /// Bounded to the first few realised bubbles: enumerating the whole thread is what hung
    /// the earlier version of this test.
    private func uniqueAnchorLabelNearTop() -> String? {
        let scroll = app.scrollViews.firstMatch
        let bubbles = scroll.staticTexts
            .matching(NSPredicate(format: "label != %@ AND label != %@",
                                  "Load earlier messages", "Beginning of conversation"))
        for index in 0..<6 {
            let candidate = bubbles.element(boundBy: index)
            guard candidate.exists else { break }
            let label = candidate.label
            guard label.count >= 12 else { continue }          // too short to be distinctive
            if app.staticTexts.matching(NSPredicate(format: "label == %@", label)).count == 1 {
                return label
            }
        }
        return nil
    }

    /// A1 + A3 + A4 in one pass, because they share an expensive setup.
    func testTappingLoadEarlierPrependsWithoutJumpingToTheBottom() throws {
        try openFirstThread()

        // A1 — the row exists on a >200-message session.
        try XCTSkipUnless(loadEarlier.waitForExistence(timeout: 25),
                          "no 'Load earlier messages' row — this session is not over 200 messages")
        XCTAssertTrue(loadEarlier.isHittable, "the row must be tappable, not decorative")

        // The bubble near the top is the one A4 protects — but it must be UNIQUELY
        // identifiable. The first attempt anchored on the topmost bubble and drew "ok",
        // which appears many times in a real thread; `app.staticTexts["ok"]` is then
        // ambiguous and reports the anchor as missing whatever the view actually did.
        XCTAssertTrue(topmostBubble().waitForExistence(timeout: 15),
                      "no bubble rendered in the thread")
        let anchorLabel = try XCTUnwrap(uniqueAnchorLabelNearTop(),
                                        "no uniquely-labelled bubble near the top to anchor on")
        let screenHeight = app.windows.firstMatch.frame.height

        add({
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways   // evidence must survive a PASSING run too
            return shot
        }())
        loadEarlier.tap()

        // A4 — the anchor must still be on screen afterwards. Had the view jumped to the
        // bottom of a thread 200 messages longer, LazyVStack would have unloaded it entirely,
        // so `exists` going false IS the failure signal.
        let anchorAfter = app.staticTexts[anchorLabel]
        let survived = anchorAfter.waitForExistence(timeout: 20)
        // Evidence first, assertion second — a failure must leave a picture behind.
        add({
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways   // evidence must survive a PASSING run too
            return shot
        }())
        XCTAssertTrue(survived,
                      "A4 FAILED: anchor '\(anchorLabel)' is gone — the view scrolled away from it")

        XCTAssertTrue(anchorAfter.isHittable,
                      "A4 FAILED: anchor bubble exists but is not on screen")
        XCTAssertLessThan(anchorAfter.frame.minY, screenHeight * 0.75,
                          "A4 FAILED: anchor bubble was pushed toward the bottom of the screen")

        // A3 — the page arrived at the HEAD: the topmost bubble is now an older, different one.
        let newTop = topmostBubble()
        XCTAssertTrue(newTop.waitForExistence(timeout: 15), "thread lost its bubbles after paging")
        XCTAssertNotEqual(newTop.label, anchorLabel,
                          "A3 FAILED: nothing was prepended above the previously-oldest bubble")
    }
}
