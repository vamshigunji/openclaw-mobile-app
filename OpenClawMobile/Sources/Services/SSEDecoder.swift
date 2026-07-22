import Foundation

/// Parses OpenAI-style Server-Sent Events emitted by /v1/chat/completions.
///
/// Each event line looks like: `data: {"choices":[{"delta":{"content":"hi"}}]}`
/// Terminated by: `data: [DONE]`
enum SSEDecoder {
    static let done = "\u{0}__DONE__"

    /// Returns the content token for a raw SSE line, `done` sentinel on completion,
    /// or nil for blanks / heartbeats / undecodable lines.
    static func token(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty { return nil }
        if payload == "[DONE]" { return done }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
              let content = chunk.choices.first?.delta.content else {
            return nil
        }
        return content
    }
}
