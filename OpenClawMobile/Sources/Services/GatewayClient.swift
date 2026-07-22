import Foundation

/// All communication with the OpenClaw Gateway.
///
/// v1 talks to the OpenAI-compatible `POST /v1/chat/completions` endpoint (PRD §3.3).
/// When no host is configured, it falls back to a local demo stream so the app is
/// usable/screenshottable standalone.
struct GatewayClient {
    let host: String
    let token: String
    let model: String

    private var isDemo: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Streams the assistant reply token-by-token.
    func streamReply(history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        if isDemo { return demoStream(history: history) }
        return liveStream(history: history)
    }

    // MARK: - Live Gateway

    private func liveStream(history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: host.trimmingCharacters(in: .whitespaces))?
                        .appendingPathComponent("v1/chat/completions") else {
                        throw GatewayError.unreachable("bad host URL")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !token.isEmpty {
                        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    let body = ChatRequest(
                        model: model,
                        messages: history.map { .init(role: $0.role.rawValue, content: $0.text) },
                        stream: true
                    )
                    req.httpBody = try JSONEncoder().encode(body)
                    req.timeoutInterval = 30

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200...299: break
                        case 401, 403: throw GatewayError.unauthorized
                        default: throw GatewayError.badStatus(http.statusCode)
                        }
                    }

                    for try await line in bytes.lines {
                        guard let token = SSEDecoder.token(from: line) else { continue }
                        if token == SSEDecoder.done { break }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch let e as GatewayError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: GatewayError.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Demo fallback

    private func demoStream(history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let last = history.last(where: { $0.role == .user })?.text ?? ""
        let reply = Self.cannedReply(for: last)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    continuation.yield(String(word) + " ")
                    try? await Task.sleep(nanoseconds: 55_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func cannedReply(for prompt: String) -> String {
        let p = prompt.lowercased()
        if p.contains("status") {
            return "Status: WORKING. Currently running the test suite on branch `feat/auth`.\n\n```\n$ swift test\nTest Suite 'All tests' started\n  ✓ AuthTests (12 passed)\n  ⧗ NetworkTests (running…)\n```\nI'll ping you when it finishes."
        }
        if p.contains("test") {
            return "Re-running tests now:\n```\n$ swift test --parallel\n```\nStarted 4 workers. This usually takes ~40s — I'll report back with results."
        }
        return "Got it. (Demo mode — no Gateway configured yet.) Add your OpenClaw VPS host & token in Settings and I'll relay this to the real agent over /v1/chat/completions."
    }
}
