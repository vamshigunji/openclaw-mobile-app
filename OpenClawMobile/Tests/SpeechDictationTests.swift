import XCTest
@testable import OpenClawMobile

/// Dictation reducer (design §4.3): idle → requesting → listening → finishing → idle, with
/// denied/failed side exits. Typed text is preserved; partial results replace only the
/// dictated span; a denied permission never touches the draft.
final class SpeechDictationTests: XCTestCase {
    func testHappyPathReplacesOnlyTheDictatedSpan() {
        var state = DictationState()
        var draft = "Fix the"

        draft = state.apply(.tapMic, draft: draft)
        XCTAssertEqual(state.phase, .requesting)
        XCTAssertEqual(draft, "Fix the")

        draft = state.apply(.permission(granted: true), draft: draft)
        XCTAssertEqual(state.phase, .listening)

        draft = state.apply(.partial("login"), draft: draft)
        XCTAssertEqual(draft, "Fix the login", "a space separates typed text from dictation")

        draft = state.apply(.partial("login bug"), draft: draft)
        XCTAssertEqual(draft, "Fix the login bug", "the partial replaces the previous partial, not the prefix")

        draft = state.apply(.tapMic, draft: draft)
        XCTAssertEqual(state.phase, .finishing)

        draft = state.apply(.final("login bug now"), draft: draft)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(draft, "Fix the login bug now")
    }

    func testDeniedPermissionLeavesDraftUntouched() {
        var state = DictationState()
        var draft = "typed by hand"
        draft = state.apply(.tapMic, draft: draft)
        draft = state.apply(.permission(granted: false), draft: draft)
        XCTAssertEqual(state.phase, .denied)
        XCTAssertEqual(draft, "typed by hand")
    }

    func testEmptyPrefixNeedsNoSeparator() {
        var state = DictationState()
        var draft = ""
        draft = state.apply(.tapMic, draft: draft)
        draft = state.apply(.permission(granted: true), draft: draft)
        draft = state.apply(.partial("hello"), draft: draft)
        XCTAssertEqual(draft, "hello")
    }

    func testPrefixEndingInWhitespaceGetsNoExtraSpace() {
        var state = DictationState()
        var draft = "Run "
        draft = state.apply(.tapMic, draft: draft)
        draft = state.apply(.permission(granted: true), draft: draft)
        draft = state.apply(.partial("tests"), draft: draft)
        XCTAssertEqual(draft, "Run tests")
    }

    func testErrorWhileListeningKeepsDictatedTextAndFails() {
        var state = DictationState()
        var draft = ""
        draft = state.apply(.tapMic, draft: draft)
        draft = state.apply(.permission(granted: true), draft: draft)
        draft = state.apply(.partial("hello"), draft: draft)
        draft = state.apply(.error("audio engine"), draft: draft)
        XCTAssertEqual(state.phase, .failed("audio engine"))
        XCTAssertEqual(draft, "hello", "what was already dictated stays")
    }

    func testResetReturnsToIdleFromDeniedOrFailed() {
        var state = DictationState()
        _ = state.apply(.tapMic, draft: "")
        _ = state.apply(.permission(granted: false), draft: "")
        _ = state.apply(.reset, draft: "")
        XCTAssertEqual(state.phase, .idle)
        _ = state.apply(.error("x"), draft: "")
        _ = state.apply(.reset, draft: "")
        XCTAssertEqual(state.phase, .idle)
    }

    func testTapMicWhileRequestingIsIgnored() {
        var state = DictationState()
        _ = state.apply(.tapMic, draft: "")
        _ = state.apply(.tapMic, draft: "")
        XCTAssertEqual(state.phase, .requesting)
    }
}
