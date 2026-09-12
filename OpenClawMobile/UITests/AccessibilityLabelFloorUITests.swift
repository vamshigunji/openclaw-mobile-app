import XCTest

/// AC3 — a machine-checkable FLOOR under accessibility labels, so the class of defect found by
/// reading every view on 2026-09-11 cannot come back silently.
///
/// This is a floor, not a substitute for the human VoiceOver pass. It proves a control HAS a
/// label and that the label is not the SF Symbol name SwiftUI falls back to. It cannot tell you
/// whether the label is any GOOD — "OK" and "Tap" sail through (QA, dev-team review 2026-09-12).
/// That judgement is AC4's, on a device, with the screen reader actually running.
///
/// REQUIRES the sandbox up and this device paired:
///     ./sandbox/up.sh
///
/// Run with:
///     xcodebuild test -project OpenClawMobile/OpenClawMobile.xcodeproj \
///       -scheme OpenClawMobileUI -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
final class AccessibilityLabelFloorUITests: XCTestCase {
    private var app: XCUIApplication!

    /// Every SF Symbol this app actually renders. A label EQUAL to one of these means no
    /// `accessibilityLabel` was set and VoiceOver is reading the symbol's name out loud.
    /// The bare ones matter most: a "lowercase, dot-separated" regex alone would miss `plus`,
    /// `tray`, `checkmark` and `gearshape` — exactly the false-negative class this floor exists
    /// to close. Add to this list when a new symbol is introduced.
    private static let symbolNames: Set<String> = [
        "plus", "checkmark", "gearshape", "tray",
        "chevron.right", "pin.fill", "xmark.circle.fill", "bolt.fill",
        "hand.raised.fill", "checkmark.circle.fill", "lock.fill", "moon.zzz.fill",
        "xmark.octagon.fill", "line.3.horizontal.decrease.circle",
    ]

    private var sandboxToken: String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
        try XCTSkipUnless(gatewayIsUp(), "sandbox gateway not reachable — run ./sandbox/up.sh first")
        _ = try XCTUnwrap(sandboxToken, "sandbox/.token missing — run ./sandbox/up.sh")
    }

    /// Relaunch on a given screen. Each test gets a fresh app so one screen's state cannot leak
    /// into another's sweep.
    private func launch(_ extraArgs: [String]) throws {
        app = XCUIApplication()
        app.launchArguments = ["--skip-first-run"] + extraArgs
        app.launchEnvironment = ["SEED_HOST": "127.0.0.1:18789",
                                 "SEED_TOKEN": try XCTUnwrap(sandboxToken)]
        app.launch()
    }

    /// A label that fails the floor: absent, or the SF Symbol name read aloud verbatim.
    private func failsFloor(_ label: String) -> Bool {
        let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if Self.symbolNames.contains(t) { return true }
        // Any other symbol-shaped token: lowercase, dot-separated, no spaces.
        return t.range(of: "^[a-z0-9]+(\\.[a-z0-9]+)+$", options: .regularExpression) != nil
    }

    /// Every control on screen with no usable label.
    ///
    /// IMAGES ARE SWEPT, NOT JUST BUTTONS. Measured 2026-09-12: this app's buttons all carry real
    /// labels, and every symbol defect lives on an `image` the button-only sweep the PRD described
    /// could never reach. iOS auto-labels most SF Symbols from their semantic name, so an
    /// unlabelled symbol usually does NOT read as "hand dot raised dot fill" — it reads as
    /// "Block". Confidently wrong, and invisible to an empty/symbol-shaped string check. Only the
    /// symbols iOS has no word for leak raw (`person.2.fill`, `gearshape.fill`); those this floor
    /// catches. The wrong-word class is AC4's to judge, on a device, by ear.
    private func labelViolations(screen: String) -> [String] {
        func scan(_ query: XCUIElementQuery, _ kind: String) -> [String] {
            query.allElementsBoundByIndex.enumerated().compactMap { index, element in
                guard element.exists, element.isHittable else { return nil }
                guard !Self.systemComposed.contains(element.identifier) else { return nil }
                guard failsFloor(element.label) else { return nil }
                let id = element.identifier.isEmpty ? "<no identifier>" : element.identifier
                return "\(screen): \(kind)[\(index)] id=\(id) label=\"\(element.label)\""
            }
        }
        return scan(app.buttons, "button") + scan(app.images, "image")
    }

    /// Chrome this app does not author, excluded so the gate stays signal. A gate that cries wolf
    /// gets muted, and a muted gate protects nothing.
    ///
    /// The first three are UIKit's own (a disclosure chevron, a NavigationLink accessory, a sheet
    /// dimming overlay). The last three are the TAB BAR ICONS: `Label(_:systemImage:)` inside
    /// `.tabItem` is composed by UIKit into a UITabBarItem, and the tab BUTTON already announces
    /// "Agents" / "Board" / "Settings" correctly. XCUITest can query the icon views and sees raw
    /// symbol names on them, but that is NOT proof VoiceOver focuses or speaks them — querying and
    /// focusing are different things, and this floor cannot tell them apart.
    /// **Carried to the AC4 device checklist to confirm by ear.** If VoiceOver does read them,
    /// delete the three symbol entries here and fix the tab items.
    private static let systemComposed: Set<String> = [
        "expanded", "chevron.forward", "AdditionalDimmingOverlay",
        "person.2.fill", "square.stack.3d.up.fill", "gearshape.fill",
    ]

    private func assertFloor(screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let bad = labelViolations(screen: screen)
        XCTAssertTrue(bad.isEmpty,
                      "\(bad.count) control(s) have no usable accessibility label:\n" +
                      bad.joined(separator: "\n"),
                      file: file, line: line)
    }

    // MARK: - The floor, screen by screen

    func testBoardHasNoUnlabelledControls() throws {
        try launch(["--open-board"])
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20),
                      "Board did not appear — is this device paired?")
        assertFloor(screen: "Board")
    }

    func testAgentRosterHasNoUnlabelledControls() throws {
        try launch([])
        XCTAssertTrue(app.buttons.firstMatch.waitForExistence(timeout: 20), "roster never rendered")
        assertFloor(screen: "Agents")
    }

    func testSettingsHasNoUnlabelledControls() throws {
        try launch(["--open-settings"])
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 20), "Settings did not appear")
        assertFloor(screen: "Settings")
    }

    // MARK: - Targeted: one named defect each (PRD section 5)

    /// Defect class A, `AgentsListView:149` — `.accessibilityLabel("Agent \(name)")` REPLACES the
    /// combined label, so the model/workspace subtitle a sighted user reads is gone for VoiceOver.
    /// The row must say more than the agent's name.
    func testRosterRowAnnouncesMoreThanTheAgentName() throws {
        try launch([])
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Agent '")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no agent row found on the roster")
        let label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Agent main" and nothing else is the defect: the subtitle has been swallowed.
        XCTAssertFalse(label.split(separator: " ").count <= 2,
                       "roster row announces only \"\(label)\" — the model/workspace subtitle is missing")
    }

    /// Defect class C, `BoardView:99-117` — the selected column chip is distinguished by a colour
    /// border only, so VoiceOver cannot tell which lane is showing.
    func testSelectedColumnChipIsAnnouncedAsSelected() throws {
        try launch(["--open-board"])
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Backlog'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "no Backlog column chip")
        chip.tap()
        XCTAssertTrue(chip.isSelected,
                      "the selected column chip does not carry the isSelected trait — selection is colour-only")
    }

    /// Defect class A, `Theme.swift:184` — `.accessibilityLabel` on an HStack that is NOT an
    /// accessibility element propagates to BOTH children, so VoiceOver says the activity twice.
    /// Exactly one element should carry the utterance.
    func testActivityLineIsASingleAccessibilityElement() throws {
        try launch(["--open-board"])
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        for utterance in ["Idle", "Working…"] {
            let matches = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", utterance))
                .allElementsBoundByIndex.filter(\.exists)
            XCTAssertLessThanOrEqual(matches.count, 1,
                                     "\"\(utterance)\" is carried by \(matches.count) elements — VoiceOver reads it twice")
        }
    }
}

// MARK: - Diagnostic (temporary): what the floor can actually SEE

extension AccessibilityLabelFloorUITests {
    /// Not an assertion — a census. Prints every button and every image on the Board so the
    /// floor's blind spots are measured rather than assumed.
    func testDiagnosticDumpBoardElements() throws {
        try launch(["--open-board"])
        XCTAssertTrue(app.staticTexts["Board"].waitForExistence(timeout: 20))
        for (name, query) in [("BUTTON", app.buttons), ("IMAGE", app.images)] {
            for e in query.allElementsBoundByIndex where e.exists {
                print("DIAG \(name) id=\"\(e.identifier)\" label=\"\(e.label)\" hittable=\(e.isHittable)")
            }
        }
    }
}
