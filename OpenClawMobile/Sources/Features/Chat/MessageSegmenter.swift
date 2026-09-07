import Foundation

/// Splits message text into prose and fenced-code segments for rendering (design §4.4).
/// Line-based: a line starting with ``` opens a fence (optional language after it); a line
/// that is exactly ``` closes it. Fence lines own their line terminators, so prose bodies
/// come out clean. An unclosed fence (streaming) is still code. `raw` slices reassemble
/// the input exactly.
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
            result.append(Segment(kind: .prose, body: prose.trimmingCharacters(in: .newlines), raw: prose))
            prose = ""
        }
        func flushCode() {
            var body = codeBody
            if body.hasSuffix("\n") { body.removeLast() }
            result.append(Segment(kind: .code(lang: lang), body: body, raw: codeRaw))
            codeRaw = ""; codeBody = ""; lang = nil; inCode = false
        }

        // Keep each newline attached to its line so raw slices stay exact.
        let pieces = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, piece) in pieces.enumerated() {
            let line = String(piece) + (i == pieces.count - 1 ? "" : "\n")
            let content = piece.trimmingCharacters(in: .whitespaces)
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
}
