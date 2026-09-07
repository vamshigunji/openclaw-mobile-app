import XCTest
@testable import OpenClawMobile

/// Fenced-code segmentation for message rendering (design §4.4). Segments must reassemble
/// the exact input (`raw`); fence lines own their line terminators so prose `body` comes out
/// clean (no surrounding newlines); an unclosed fence during streaming is code.
final class MessageSegmenterTests: XCTestCase {
    private typealias Segment = MessageSegmenter.Segment

    private func kinds(_ segments: [Segment]) -> [Segment.Kind] { segments.map(\.kind) }

    private func assertRoundTrip(_ input: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(MessageSegmenter.segments(input).map(\.raw).joined(), input,
                       "segments must reassemble the input exactly", file: file, line: line)
    }

    func testEmptyInputHasNoSegments() {
        XCTAssertEqual(MessageSegmenter.segments(""), [])
    }

    func testProseOnly() {
        let input = "Just words, no code."
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.prose])
        XCTAssertEqual(segments[0].body, input)
        assertRoundTrip(input)
    }

    func testSingleFenceWithoutLanguage() {
        let input = "Run this:\n```\nswift test\n```\nDone."
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.prose, .code(lang: nil), .prose])
        XCTAssertEqual(segments[0].body, "Run this:")
        XCTAssertEqual(segments[0].raw, "Run this:\n")
        XCTAssertEqual(segments[1].body, "swift test")
        XCTAssertEqual(segments[1].raw, "```\nswift test\n```\n")
        XCTAssertEqual(segments[2].body, "Done.")
        assertRoundTrip(input)
    }

    func testFenceWithLanguage() {
        let input = "```swift\nlet x = 1\nprint(x)\n```"
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.code(lang: "swift")])
        XCTAssertEqual(segments[0].body, "let x = 1\nprint(x)")
        assertRoundTrip(input)
    }

    func testTwoFences() {
        let input = "a\n```sh\nls\n```\nb\n```json\n{}\n```\n"
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.prose, .code(lang: "sh"), .prose, .code(lang: "json")])
        XCTAssertEqual(segments[1].body, "ls")
        XCTAssertEqual(segments[2].body, "b")
        XCTAssertEqual(segments[3].body, "{}")
        assertRoundTrip(input)
    }

    func testUnclosedFenceIsCodeWhileStreaming() {
        let input = "Here:\n```py\nprint(1)\nprint("
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.prose, .code(lang: "py")])
        XCTAssertEqual(segments[1].body, "print(1)\nprint(")
        assertRoundTrip(input)
    }

    func testFenceOpenedButEmptyWhileStreaming() {
        let input = "```swift\n"
        let segments = MessageSegmenter.segments(input)
        XCTAssertEqual(kinds(segments), [.code(lang: "swift")])
        XCTAssertEqual(segments[0].body, "")
        assertRoundTrip(input)
    }
}
