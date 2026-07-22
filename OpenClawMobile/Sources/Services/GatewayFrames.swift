import Foundation

/// Outbound protocol-v4 WS RPC frames (.docs/protocol.md §4, LIVE-verified fields).
enum GatewayFrames {
    /// Reference-client precedence: `auth.token` wins; `bootstrapToken` only when no token.
    enum Auth {
        case token(String)
        case bootstrap(String)
        case none

        var dict: [String: String] {
            switch self {
            case .token(let t): ["token": t]
            case .bootstrap(let b): ["bootstrapToken": b]
            case .none: [:]
            }
        }

        /// The *signatureToken* bound into the v3 payload: `auth.token ?? auth.bootstrapToken ?? ""`.
        var signatureToken: String? {
            switch self {
            case .token(let t): t
            case .bootstrap(let b): b
            case .none: nil
            }
        }
    }

    static let scopes = ["operator.read", "operator.write"] // pre-normalized (sorted, implied included)

    static func connect(auth: Auth, device: [String: Any]?) -> [String: Any] {
        var params: [String: Any] = [
            "minProtocol": 4, "maxProtocol": 4,
            // client.id AND client.mode are CLOSED enums (LIVE 2026-07-21):
            // client.id must be "openclaw-ios" (or "cli"); mode "node".
            // "operator" is a ROLE, not a mode.
            "client": ["id": "openclaw-ios", "version": "0.1.0", "platform": "ios", "mode": "node"],
            "role": "operator",
            "scopes": scopes,
            "auth": auth.dict,
        ]
        if let device { params["device"] = device }
        return ["type": "req", "id": "p0-connect", "method": "connect", "params": params]
    }

    /// LIVE 2026-07-21: `sessions.subscribe {}` streams ALL session events to this
    /// connection — `chat` deltas, `session.message`, `sessions.changed`. The
    /// keyed `sessions.messages.subscribe {key}` variant exists but is unnecessary
    /// for a single-agent client.
    static func subscribe() -> [String: Any] {
        ["type": "req", "id": "p0-subscribe", "method": "sessions.subscribe",
         "params": [String: Any]()]
    }

    /// LIVE: history is `chat.history {sessionKey, limit}` (scope operator.read).
    static func history(sessionKey: String) -> [String: Any] {
        ["type": "req", "id": "p0-history", "method": "chat.history",
         "params": ["sessionKey": sessionKey, "limit": 200]]
    }

    /// LIVE: sends are `chat.send` (scope operator.write) — NOT `session.message`,
    /// which requires operator.admin. `message` is a plain string; the gateway
    /// adopts `idempotencyKey` as the run id and echoes the user message with
    /// idempotencyKey `<runId>:user` (P3/P5, verified live).
    static func message(sessionKey: String, text: String, idempotencyKey: String) -> [String: Any] {
        ["type": "req", "id": "p0-send", "method": "chat.send",
         "params": [
            "sessionKey": sessionKey,
            "message": text,
            "idempotencyKey": idempotencyKey,
         ]]
    }

    static func agentsList() -> [String: Any] {
        ["type": "req", "id": "p0-agents", "method": "agents.list", "params": [String: Any]()]
    }
}
