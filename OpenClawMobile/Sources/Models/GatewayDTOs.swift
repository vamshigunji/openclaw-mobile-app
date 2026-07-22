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

// MARK: - Errors

enum GatewayError: LocalizedError {
    case unauthorized
    case unreachable(String)
    case badStatus(Int)
    /// Signed bootstrap connect accepted but the device awaits operator approval
    /// (`PAIRING_REQUIRED / wait_then_retry`, .docs/protocol.md §3) — retryable.
    /// Carries the gateway's requestId so the UI can show the exact approve command.
    case pairingPending(requestId: String?)
    /// `AUTH_BOOTSTRAP_TOKEN_INVALID` — setup code expired/consumed; user needs
    /// a fresh one (`openclaw qr`). Terminal, not retryable.
    case bootstrapExpired

    var errorDescription: String? {
        switch self {
        case .unauthorized:  return "Token rejected (401). Check your token in Settings."
        case .unreachable(let m): return "Can't reach Gateway: \(m)"
        case .badStatus(let c):   return "Gateway returned HTTP \(c)."
        case .pairingPending: return "Device pairing pending — approve this device on the gateway."
        case .bootstrapExpired: return "Setup code expired. Generate a fresh one with `openclaw qr`."
        }
    }
}
