import Foundation

// MARK: - Request (OpenAI-compatible /v1/chat/completions)

struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

// MARK: - Streaming response chunks (SSE `data:` lines)

struct ChatStreamChunk: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let delta: Delta
        struct Delta: Decodable {
            let content: String?
        }
    }
}

// MARK: - Non-streaming fallback response

struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable {
            let content: String
        }
    }
}

// MARK: - Errors

enum GatewayError: LocalizedError {
    case notConfigured
    case unauthorized
    case unreachable(String)
    case badStatus(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Gateway configured. Add your host & token in Settings."
        case .unauthorized:  return "Token rejected (401). Check your token in Settings."
        case .unreachable(let m): return "Can't reach Gateway: \(m)"
        case .badStatus(let c):   return "Gateway returned HTTP \(c)."
        case .decoding(let m):    return "Unexpected response format: \(m)"
        }
    }
}
