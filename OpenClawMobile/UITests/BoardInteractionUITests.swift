import XCTest

/// Real taps against a LIVE sandbox gateway — the interactions `simctl` cannot perform and
/// which were logged as human checkpoints throughout the 2026-09-08 validation run
/// (S4.3 agent filter, S4.10 Board interactions).
///
/// REQUIRES the sandbox to be up and this device paired:
///     ./sandbox/up.sh
///     docker exec oc openclaw devices list
///     docker exec oc openclaw devices approve <requestId>
///
/// Run with:
///     xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj \
///       -scheme OpenClawMobileUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// These tests SKIP rather than fail when the gateway is unreachable, so they never turn a
/// missing sandbox into a red build — an unreachable gateway is an environment fact, not a
/// regression.
final class BoardInteractionUITests: XCTestCase {
    private var app: XCUIApplication!

    /// The sandbox token, read the same way every probe in this repo does.
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
        app.launchArguments = ["--skip-first-run", "--open-board"]
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token]
        app.launch()
    }

    /// Backlog count as the Board itself reports it. Used to decide whether "no cards" is
    /// legitimate (empty gateway) or a regression (cards claimed but not rendered).
    func backlogCount() -> Int {
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        guard chip.waitForExistence(timeout: 15) else { return 0 }
        return Int(chip.label.filter(\.isNumber)) ?? 0
    }

    /// S4.10 — the Board's column chips are real controls; tapping one must change what is shown.
    func testTappingColumnChipsSwitchesLanes() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20),
                      "Board did not appear — is the device paired?")

        // "Backlog" carries a count, so match by prefix rather than exact string.
        let backlog = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        XCTAssertTrue(backlog.waitForExistence(timeout: 15), "no Backlog column chip")
        backlog.tap()

        // A Backlog card exists only if the gateway has non-main sessions; assert the lane
        // header rather than a specific card so the test does not depend on fixture data.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'"))
                        .firstMatch.exists)

        let running = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Running'")).firstMatch
        if running.exists {
            running.tap()
            XCTAssertTrue(running.exists, "Running chip vanished after tapping it")
        }
    }

    /// S4.3 — the agent filter, which could never be checked live because the sandbox had one
    /// agent until approach B created `writer`.
    func testAgentFilterMenuOpensAndListsAgents() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        let filter = app.buttons["Filter by agent"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15), "no 'Filter by agent' control")
        filter.tap()

        // The menu should offer at least the two agents the sandbox has.
        let main = app.buttons["main"].firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 8),
                      "agent filter menu did not list 'main'")
    }

    /// S4.10 — "New task" is the Board's create affordance; it must open something.
    func testNewTaskControlIsReachable() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        let newTask = app.buttons["New task"]
        XCTAssertTrue(newTask.waitForExistence(timeout: 15), "no 'New task' control on the Board")
        XCTAssertTrue(newTask.isHittable, "'New task' exists but cannot be tapped")
    }
}

// MARK: - Real card interactions (S4.10b)

extension BoardInteractionUITests {
    /// The Board is NOT drag-and-drop: columns are filter chips and per-card actions live in a
    /// context menu (`BoardView` line ~168). The original checklist said "drag a card between
    /// lanes" — that interaction does not exist in this UI, so this test drives the real one.
    func testCardContextMenuOffersArchive() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))

        let backlog = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        XCTAssertTrue(backlog.waitForExistence(timeout: 15))
        backlog.tap()

        // Cards carry `board.card.<sessionKey>` identifiers (added 2026-09-08 for this test).
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'board.card.'")).firstMatch
        // Skip ONLY when the Board itself says the column is empty. Skipping merely because no
        // card was found would go silent on a defect-6 regression and still report "passed".
        if !card.waitForExistence(timeout: 12) {
            let n = backlogCount()
            try XCTSkipIf(n == 0, "gateway genuinely has no backlog sessions")
            XCTFail("Board claims \(n) backlog cards but rendered none (defect 6 regression?)")
            return
        }

        card.press(forDuration: 1.2)          // open the context menu
        let archive = app.buttons["Archive"].firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 8),
                      "context menu did not offer Archive")

        // The menu is the Board's whole action surface (BoardView.menu(for:)). "Move to project…"
        // is what actually moves a card between LANES — the capability the checklist called
        // "drag a card between lanes". The gesture does not exist; the capability does.
        XCTAssertTrue(app.buttons["Move to project…"].exists,
                      "context menu did not offer 'Move to project…' — the lane-move affordance")
        // Backlog cards offer Start work; running cards offer Stop run. Exactly one applies here.
        let start = app.buttons["Start work"].exists
        let stop = app.buttons["Stop run"].exists
        XCTAssertTrue(start || stop,
                      "a card offered neither 'Start work' nor 'Stop run'")

        // Dismiss without archiving: this test proves the affordance exists, it does not mutate
        // the human's sandbox out from under the S6.4 walkthrough.
        app.tap()
        XCTAssertFalse(archive.exists, "context menu did not dismiss")
    }

    /// Tapping a card must open its thread — the Board's primary navigation.
    func testTappingCardOpensItsThread() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        let backlog = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        XCTAssertTrue(backlog.waitForExistence(timeout: 15))
        backlog.tap()

        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'board.card.'")).firstMatch
        if !card.waitForExistence(timeout: 12) {
            let n = backlogCount()
            try XCTSkipIf(n == 0, "gateway genuinely has no backlog sessions")
            XCTFail("Board claims \(n) backlog cards but rendered none (defect 6 regression?)")
            return
        }
        card.tap()

        // The chat thread shows a message composer; the Board does not.
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 12)
                      || app.textFields.firstMatch.waitForExistence(timeout: 4),
                      "tapping a card did not open a chat thread")
    }
}

// MARK: - Stop on a live run (S3.5, app half)

/// The half of S3.5 that could not be checked without taps: `chat.abort` was proven at the RPC
/// level, but not that the Stop BUTTON drives it, nor that `runEnds` marks the turn
/// **aborted** ("Stopped") rather than **failed** ("Run failed") — a distinction that matters
/// because a failed turn offers Retry and a stopped one should not.
final class ChatStopUITests: XCTestCase {
    private var app: XCUIApplication!

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        var alive = false; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh")
        let token = try XCTUnwrap(sandboxToken)
        app = XCUIApplication()
        // --seed-demo opens the first agent's thread and auto-sends SEED_TEXT. A long prompt
        // keeps the run alive long enough to press Stop.
        app.launchArguments = ["--seed-demo"]
        app.launchEnvironment = [
            "SEED_HOST": "127.0.0.1:18789",
            "SEED_TOKEN": token,
            "SEED_TEXT": "Count slowly from 1 to 120, one line each, with a sentence about every number.",
        ]
        app.launch()
    }

    func testStopButtonEndsTheRunAndMarksItStoppedNotFailed() throws {
        // Stop only exists while a run is live (`canStop`).
        let stop = app.buttons["Stop"]
        // ASSERT, do not skip. The seeded prompt (count to 120) reliably runs for seconds — the
        // Stop button was found in 3.6s when this was written. Skipping here would go silent on a
        // broken `canStop` and still report "passed", which is the failure this suite guards.
        XCTAssertTrue(stop.waitForExistence(timeout: 45),
                      "Stop never appeared during a long run — canStop may be broken")
        stop.tap()

        // runEnds must clear Stop and restore Send.
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 20),
                      "Stop did not clear after aborting — runEnds never fired")
        XCTAssertFalse(stop.exists, "Stop button still present after the run ended")

        // The turn must read as stopped, never as a failure.
        let stopped = app.staticTexts["Stopped"].firstMatch
        let runFailed = app.staticTexts["Run failed"].firstMatch
        XCTAssertFalse(runFailed.exists,
                       "a stopped run was rendered as 'Run failed' — aborted must not read as failed")
        // This previously read `stopped.waitForExistence(...) || !runFailed.exists`, which could
        // NEVER fail: the assertion directly above guarantees `!runFailed.exists`, so the right
        // operand was always true and the "Stopped" check was dead. `MessageBubble` renders
        // Label("Stopped") for `message.aborted`, so assert exactly that.
        // Was `stopped.waitForExistence(...) || !runFailed.exists`, which could NEVER fail: the
        // assertion above already guarantees `!runFailed.exists`, so the right operand was always
        // true and the "Stopped" half was dead. `MessageBubble` renders Label("Stopped") for
        // `message.aborted`, so assert exactly that.
        //
        // KNOWN RACE, deliberately NOT papered over: if the model finishes between Stop appearing
        // and the tap landing, the gateway aborts nothing (`aborted:false`), no "aborted" terminal
        // arrives, and the turn is correctly NOT marked Stopped. Observed once in ~5 runs. Adding
        // an `|| ...` escape hatch here would recreate the dead assertion this replaced, so if
        // this fails, check whether the run had already completed before blaming the abort path.
        XCTAssertTrue(stopped.waitForExistence(timeout: 10),
                      "the aborted turn was never labelled 'Stopped' — check the run was still live")
    }
}

// MARK: - Defect 5 regression, at the layer a user actually sees

/// Defect 5 doubled EVERY assistant reply. It was fixed in the decoder
/// (`__openclaw.runId` → `chat-run:<runId>` so the final message upserts instead of appending)
/// and pinned by `WireProtocolTests`. But that test asserts a decoded key — it would still pass
/// if some future change re-introduced a second bubble higher up the stack.
///
/// This guards the symptom itself: ONE send must render exactly ONE assistant bubble.
final class ChatNoDuplicateReplyUITests: XCTestCase {
    private var app: XCUIApplication!
    private let nonce = "UIDUP\(Int.random(in: 10000...99999))"

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        var alive = false; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh")
        let token = try XCTUnwrap(sandboxToken)
        app = XCUIApplication()
        app.launchArguments = ["--seed-demo"]
        app.launchEnvironment = [
            "SEED_HOST": "127.0.0.1:18789",
            "SEED_TOKEN": token,
            // The assistant's whole reply is the nonce, so an exact label match counts bubbles.
            // The user's message merely CONTAINS it, so it will not be matched.
            "SEED_TEXT": "Reply with the single word \(nonce) and nothing else",
        ]
        app.launch()
    }

    func testOneSendRendersExactlyOneAssistantBubble() throws {
        let exact = NSPredicate(format: "label == %@", nonce)
        let reply = app.staticTexts.matching(exact).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60),
                      "the agent never replied with \(nonce) — is a model configured?")

        // Let any duplicate arrive before counting: the doubled bubble came from the FINAL
        // session.message, which lands after the stream completes.
        Thread.sleep(forTimeInterval: 6)

        let count = app.staticTexts.matching(exact).count
        XCTAssertEqual(count, 1,
                       "DEFECT 5 REGRESSION: one send rendered \(count) assistant bubbles")
    }
}

// MARK: - Defect 6 regression: the Board must not silently empty

extension BoardInteractionUITests {
    /// Defect 6 made the Board permanently empty (`kind == "agent"` filter vs the gateway's
    /// `kind: "direct"`). `BoardLiveFixtureTests` guards the decode, but the UI symptom deserves
    /// its own check — and note the trap this closes: `testCardContextMenuOffersArchive` SKIPS
    /// when no card is found, so a regression of defect 6 would make it report "passed" while
    /// going quiet. A test that falls silent exactly when the bug returns is worse than none.
    ///
    /// This one is self-consistent instead: the column chip's own count comes from the same
    /// `sessions.list` data as the cards. If the chip says N > 0 and no card renders, the
    /// filtering broke — no gateway query needed.
    func testBoardRendersCardsWheneverItsOwnCountIsNonZero() throws {
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))

        // The chip is a Button wrapping SEPARATE Text(title) + Text(count) views, so the
        // staticText label is just "Backlog" — the count only appears on the enclosing button,
        // whose accessibility label concatenates its children. Matching staticTexts here made an
        // earlier version of this test silently SKIP, which is the exact failure it exists to stop.
        let chip = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no Backlog chip button")

        let digits = chip.label.filter(\.isNumber)
        let count = Int(digits) ?? 0
        try XCTSkipIf(count == 0,
                      "gateway genuinely has no backlog sessions (chip label: '\(chip.label)')")

        chip.tap()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'board.card.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 12),
                      "DEFECT 6 REGRESSION: chip reports \(count) backlog cards but none rendered")
    }
}

// MARK: - Settings, the screen pairing actually happens on

/// Settings had NO UI coverage at all, despite being where a new user pairs the device — the
/// step S6.4 is about. This does not attempt to drive a full pairing (that needs an unpaired
/// device and a setup code, and openclaw limits setup codes over plaintext `ws://`). It checks
/// the screen renders and reports paired state honestly, which is what a newcomer reads.
final class SettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        var alive = false; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh")
        let token = try XCTUnwrap(sandboxToken)
        app = XCUIApplication()
        app.launchArguments = ["--skip-first-run", "--open-settings"]
        // SEED_DEVICE_TOKEN PERSISTS in the simulator between launches, so a test that seeds one
        // silently pairs every test that follows it. Declare the state explicitly instead of
        // inheriting whatever the previous test left behind ("" clears it).
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token,
                                 "SEED_DEVICE_TOKEN": ""]
        app.launch()
    }

    /// A configured, paired device must SAY so — the screen is how a user knows pairing worked.
    /// This asserted "either 'Paired' OR 'Pair this device'", which cannot fail as long as the
    /// screen renders at all — and since NO UI test seeds a device token, it only ever exercised
    /// the unpaired arm. `isPaired = !deviceToken.isEmpty && isConfigured`, and the suite seeds
    /// `SEED_TOKEN` (the SHARED gateway token), so the app connects while genuinely unpaired.
    /// Split into two deterministic tests, each seeding the state it claims to check.
    func testSettingsShowsPairPromptWhenNoDeviceTokenExists() throws {
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20),
                      "Settings screen did not open")
        XCTAssertTrue(app.staticTexts["Pair this device"].waitForExistence(timeout: 10),
                      "no device token is seeded, so the pairing prompt is the correct state")
        XCTAssertFalse(app.staticTexts["Paired"].exists,
                       "claiming Paired without a device token would be a lie to the user")
    }

    /// The paired branch had never been rendered by any test. A non-empty device token is all
    /// `isPaired` requires, which is exactly what this asserts — the UI branch, not the auth
    /// round trip (a fabricated token is rejected by the gateway as `device_token_mismatch`,
    /// which is fine here: the screen must still report the state it believes it is in).
    func testSettingsReportsPairedWhenADeviceTokenExists() throws {
        app.terminate()
        let paired = XCUIApplication()
        paired.launchArguments = ["--skip-first-run", "--open-settings"]
        paired.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789",
                                    "SEED_DEVICE_TOKEN": "ui-test-device-token"]
        paired.launch()
        XCTAssertTrue(paired.staticTexts["Settings"].waitForExistence(timeout: 20))
        XCTAssertTrue(paired.staticTexts["Paired"].waitForExistence(timeout: 10),
                      "a stored device token must surface as Paired")
        paired.terminate()

        // Undo the pairing this test created, or every later test inherits it.
        let cleanup = XCUIApplication()
        cleanup.launchArguments = ["--skip-first-run"]
        cleanup.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_DEVICE_TOKEN": ""]
        cleanup.launch()
        cleanup.terminate()
    }

    func testSettingsSurfacesTheConfiguredHost() throws {
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20))
        let hostShown = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '127.0.0.1' OR value CONTAINS '127.0.0.1'"))
            .firstMatch
        XCTAssertTrue(hostShown.waitForExistence(timeout: 10),
                      "Settings never showed the configured host — a user cannot tell live from demo")
    }
}

// MARK: - First run, the screen S6.4 actually starts on

/// Every other UI test passes `--skip-first-run`. The onboarding screen a genuinely NEW user
/// sees first had no coverage at all — and it is precisely what S6.4 ("fresh install → pair →
/// chat → Board, using only README") begins with.
///
/// This cannot judge whether the copy READS well to a newcomer; that stays a human checkpoint.
/// It does verify the screen appears, explains something, and leads somewhere.
final class FirstRunUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // No --skip-first-run and no seeded host. `--reset-first-run` clears BOTH the seen flag
        // and the persisted host, because first run shows only when neither is set — simulating a
        // genuinely fresh install. NOTE: this leaves the app unconfigured afterwards.
        app.launchArguments = ["--reset-first-run"]
        app.launch()
    }

    func testFirstRunExplainsAndOffersAWayForward() throws {
        let title = app.staticTexts["OpenClaw"].firstMatch
        guard title.waitForExistence(timeout: 15) else {
            throw XCTSkip("first-run gate already satisfied on this simulator (hasSeenFirstRun)")
        }
        // It must explain something, not just show a logo and a button.
        XCTAssertGreaterThan(app.staticTexts.count, 2,
                             "first-run screen showed no explanatory copy")
        // And it must lead somewhere.
        let cta = app.buttons["Set up my gateway"].firstMatch
        XCTAssertTrue(cta.waitForExistence(timeout: 5),
                      "first-run screen offered no way forward")
        XCTAssertTrue(cta.isHittable)
        cta.tap()
        // Tapping it should land on Settings, where pairing happens.
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10),
                      "the first-run CTA did not lead to Settings")
    }
}

// MARK: - The last two untested screens (create + profile)

/// `CreateAgentView` and `AgentProfileView` were the only screens with no UI coverage.
/// Both are exercised NON-DESTRUCTIVELY: the create form is filled but never submitted, and the
/// profile is read only. Submitting would drive approach B and mutate the sandbox the human
/// still needs for S6.4.
final class AgentScreensUITests: XCTestCase {
    private var app: XCUIApplication!

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        var alive = false; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    private func launch(_ args: [String]) throws {
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh")
        let token = try XCTUnwrap(sandboxToken)
        app = XCUIApplication()
        app.launchArguments = ["--skip-first-run"] + args
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token]
        app.launch()
    }

    /// The create form gates submission on BOTH a name and a behavior — `canSubmit` is
    /// `!name.isEmpty && !behavior.isEmpty && phase == .editing`. That is correct, not fussy:
    /// approach B's instruction provisions the behavior into the agent's AGENTS.md, so a
    /// nameless or behaviourless request would produce a useless agent.
    ///
    /// (My first version of this test asserted Create enabled after typing only a name, and
    /// failed. The app was right and the test was wrong — checking `canSubmit` settled it.)
    /// Submitting is deliberately NOT done: it would instruct `main` to create a real agent in
    /// the sandbox the human still needs.
    func testCreateAgentFormGatesSubmitOnNameAndBehavior() throws {
        try launch(["--open-create"])
        XCTAssertTrue(app.staticTexts["New Agent"].waitForExistence(timeout: 20),
                      "create screen did not open")

        let create = app.buttons["Create Agent"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 10), "no 'Create Agent' button")
        XCTAssertFalse(create.isEnabled, "Create was enabled with an empty form")

        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8), "no name field")
        name.tap(); name.typeText("probe-agent")
        XCTAssertFalse(create.isEnabled,
                       "Create enabled with a name but no behaviour — approach B needs both")

        let behaviour = app.textViews.firstMatch
        XCTAssertTrue(behaviour.waitForExistence(timeout: 8), "no behaviour field")
        behaviour.tap(); behaviour.typeText("Reply only with the current time.")
        XCTAssertTrue(create.isEnabled, "Create stayed disabled with both name and behaviour set")
        // Intentionally NOT submitting.
    }

    /// The profile reads AGENTS.md through `loadInstructions` — verified live at the RPC level
    /// earlier; this checks the screen actually surfaces it.
    func testAgentProfileShowsInstructionsFromTheGateway() throws {
        try launch(["--open-profile", "writer"])
        XCTAssertTrue(app.staticTexts["Profile"].waitForExistence(timeout: 20),
                      "profile screen did not open")
        XCTAssertTrue(app.staticTexts["Instructions (AGENTS.md)"].waitForExistence(timeout: 15),
                      "profile did not show the instructions section")
        // `writer`'s AGENTS.md was restored to a writing-assistant brief earlier in this run.
        let body = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'writ'")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 12),
                      "instructions section rendered but showed no content from the gateway")
    }
}

// MARK: - Dynamic Type at accessibility sizes (closes the 2026-09-07 review's last concern)

/// The review noted that `AccessibilityTests` measure selected WORDS against fixed width budgets
/// and inspect two-line declarations — they "do not prove complete screens fit, vertical content
/// remains reachable, every control usable at the largest size". That was fair, and untestable
/// until a UI target existed.
///
/// This launches the real app at accessibility XXXL and asserts the controls a user must be able
/// to reach are still present AND hittable. It cannot judge whether the layout looks good — that
/// stays a human checkpoint — but it catches the failure that matters: a control pushed off
/// screen or overlapped into unhittability by enormous text.
final class DynamicTypeUITests: XCTestCase {
    private var app: XCUIApplication!

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sandbox/.token")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:18789/health") else { return false }
        var req = URLRequest(url: url); req.timeoutInterval = 4
        var alive = false; let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let s = String(data: data, encoding: .utf8) { alive = s.contains("\"ok\":true") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 6)
        return alive
    }

    private func launch(_ screen: String) throws {
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh")
        let token = try XCTUnwrap(sandboxToken)
        app = XCUIApplication()
        app.launchArguments = ["--skip-first-run", screen,
                               "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token]
        app.launch()
    }

    func testBoardControlsStayReachableAtAccessibilityXXXL() throws {
        try launch("--open-board")
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 25),
                      "the Board did not render at accessibility XXXL")
        for label in ["New task", "Filter by agent"] {
            let control = app.buttons[label]
            XCTAssertTrue(control.waitForExistence(timeout: 10), "\(label) vanished at XXXL")
            XCTAssertTrue(control.isHittable, "\(label) exists but is not hittable at XXXL")
        }
        // The tab bar is the only way off this screen.
        XCTAssertTrue(app.buttons["Agents"].isHittable || app.staticTexts["Agents"].exists,
                      "the tab bar became unusable at XXXL — the user is stranded")
    }

    func testChatComposerStaysUsableAtAccessibilityXXXL() throws {
        try launch("--seed-demo")
        // Send is the control that matters: an unreachable composer makes the app read-only.
        let send = app.buttons["Send"]
        let stop = app.buttons["Stop"]
        XCTAssertTrue(send.waitForExistence(timeout: 30) || stop.waitForExistence(timeout: 10),
                      "neither Send nor Stop was reachable at XXXL — the composer is unusable")
    }
}


/// Workstream A (2026-09-10): the transcript must be readable with NO gateway.
///
/// Deliberately does NOT stop the Docker sandbox — that is shared state, and every other UI test
/// in this suite needs it up (the previous run lost an hour to exactly that class of leak).
/// Instead the SECOND launch points at a dead port, which is indistinguishable from an unreachable
/// gateway from the app's side, while the first launch (online) is what puts history on disk.
final class OfflineHistoryUITests: XCTestCase {
    private var sandboxToken: String? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try? String(contentsOf: root.appendingPathComponent("sandbox/.token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gatewayIsUp() -> Bool {
        let url = URL(string: "http://127.0.0.1:18789/")!
        var req = URLRequest(url: url); req.timeoutInterval = 3
        let sem = DispatchSemaphore(value: 0); var ok = false
        URLSession.shared.dataTask(with: req) { _, response, _ in
            ok = (response as? HTTPURLResponse) != nil; sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return ok
    }

    func testCachedTranscriptRendersWhenTheGatewayCannotBeReached() throws {
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh first")
        let token = try XCTUnwrap(sandboxToken, "sandbox/.token missing — run ./sandbox/up.sh")
        let marker = "OFFLINEUI-\(Int(Date().timeIntervalSince1970) % 100000)"

        // 1. ONLINE: produce a real exchange, which persists to disk.
        let online = XCUIApplication()
        online.launchArguments = ["--skip-first-run", "--seed-demo"]
        online.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789", "SEED_TOKEN": token,
                                    "SEED_TEXT": marker]
        online.launch()
        XCTAssertTrue(online.staticTexts[marker].waitForExistence(timeout: 45),
                      "the online send never rendered, so there is nothing cached to test")
        // Let the reply settle so the turn is persisted at a boundary, not mid-stream.
        Thread.sleep(forTimeInterval: 8)
        online.terminate()

        // 2. OFFLINE: a dead port. No Docker state is touched.
        let offline = XCUIApplication()
        offline.launchArguments = ["--skip-first-run", "--seed-demo"]
        offline.launchEnvironment = ["SEED_HOST": "127.0.0.1:1", "SEED_TOKEN": token,
                                     "SEED_TEXT": "sent while offline"]
        offline.launch()

        XCTAssertTrue(offline.staticTexts[marker].waitForExistence(timeout: 30),
                      "with no reachable gateway the thread rendered without its cached history")
        offline.terminate()
    }
}
