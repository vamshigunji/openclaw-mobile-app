import Foundation

/// Splits message text into prose and fenced-code segments for rendering (design §4.4).
/// Line-based: a line starting with ``` opens a fence (optional language after it); a line
/// that is exactly ``` closes it. Fence lines own their line terminators, so prose bodies
/// come out clean. An unclosed fence (streaming) is still code. `raw` slices reassemble
/// the input exactly; bodies are CRLF-normalized (Windows-authored files paste in fine).
enum MessageSegmenter {
    struct Segment: Equatable {
        enum Kind: Equatable {
            case prose
            case code(lang: String?)
        }
        let kind: Kind
        /// Prose without surrounding newlines, or the code between the fence lines.
        let body: String
        /// Exact source slice, fences included.
        let raw: String
    }

    static func segments(_ text: String) -> [Segment] {
        guard !text.isEmpty else { return [] }
        var result: [Segment] = []
        var prose = ""
        var codeRaw = "", codeBody = ""
        var lang: String?
        var inCode = false

        func flushProse() {
            guard !prose.isEmpty else { return }
            result.append(Segment(kind: .prose, body: normalized(prose).trimmingCharacters(in: .newlines), raw: prose))
            prose = ""
        }
        func flushCode() {
            var body = normalized(codeBody)
            if body.hasSuffix("\n") { body.removeLast() }
            result.append(Segment(kind: .code(lang: lang), body: body, raw: codeRaw))
            codeRaw = ""; codeBody = ""; lang = nil; inCode = false
        }

        // Walk lines by hand: Swift treats "\r\n" as ONE Character, so splitting on "\n"
        // would never split CRLF text. Each line keeps its own terminator so raw stays exact.
        for (piece, terminator) in lines(of: text) {
            let line = String(piece) + String(terminator)
            let content = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if inCode {
                codeRaw += line
                if content == "```" { flushCode() } else { codeBody += line }
            } else if content.hasPrefix("```") {
                flushProse()
                inCode = true
                let l = content.dropFirst(3).trimmingCharacters(in: .whitespaces)
                lang = l.isEmpty ? nil : l
                codeRaw = line
            } else {
                prose += line
            }
        }
        if inCode { flushCode() } else { flushProse() }
        return result
    }

    /// (body, terminator) pairs; the last pair's terminator is empty.
    private static func lines(of text: String) -> [(Substring, Substring)] {
        var result: [(Substring, Substring)] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\n" || ch == "\r\n" || ch == "\r" {
                let next = text.index(after: i)
                result.append((text[start..<i], text[i..<next]))
                start = next
                i = next
            } else {
                i = text.index(after: i)
            }
        }
        result.append((text[start..<text.endIndex], text[text.endIndex..<text.endIndex]))
        return result
    }

    /// CRLF/CR → LF. (No `contains("\r")` guard: "\r\n" is one Character and never matches a lone CR.)
    private static func normalized(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
