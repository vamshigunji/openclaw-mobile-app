import Foundation

/// Path-A `SyncSource`: gateway-native multi-device sync over protocol-v4 WS RPC.
///
/// - `loadHistory` → `sessions.messages.list`
/// - `subscribe`   → `sessions.messages.subscribe` fan-in of `session.message` events
/// - `send`        → `session.message` WS write (NOT part of `SyncSource`; the send
///                   path stays on WS with a client idempotency key per PRD-handshake §5)
///
/// It sits ON TOP of an already-paired/handshaken session: the caller supplies the
/// device-bound operator token produced by the pairing flow. Challenge-signing /
/// Secure-Enclave pairing is owned by `.docs/connection-handshake.md` and is NOT
/// re-implemented here — this type only replies to the `connect.challenge` with the
/// token it was handed. If the gateway requires a device signature the token alone
/// lacks, that surfaces as `GatewayError.unauthorized`.
///
/// NOTE: the live PASS/FAIL of this path (P1–P7) is a human checkpoint — see
/// `tools/phase0-verify.mjs` and `.docs/loop-handshake-checklist.md`. This code is
/// Path-A-complete but viability-UNVERIFIED until a live two-device run.
struct GatewayWSSyncSource: SyncSource {
    let host: String
    let token: String

    // MARK: - SyncSource (history + subscribe)

    func loadHistory(sessionId: String) async throws -> [ChatMessage] {
        let ws = try openSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }
        try await handshake(ws)
        try await write(Frames.history(sessionId: sessionId), to: ws)
        for _ in 0..<64 {
            guard let env = try await receive(ws) else { continue }
            if env.id == "p0-history" {
                if env.ok == false { throw GatewayError.badStatus(0) }
                return (env.payload?.messages ?? []).compactMap { $0.asChatMessage }
            }
        }
        throw GatewayError.unreachable("no history response")
    }

    func subscribe(sessionId: String) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let ws = try openSocket()
                    defer { ws.cancel(with: .goingAway, reason: nil) }
                    try await handshake(ws)
                    try await write(Frames.subscribe(sessionId: sessionId), to: ws)
                    while !Task.isCancelled {
                        guard let env = try await receive(ws) else { continue }
                        if let msg = env.broadcastMessage { continuation.yield(msg) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Send (WS write path — always carries a client idempotency key, P5)

    /// Path-A write-of-record. `idempotencyKey` makes a resend-on-reconnect safe and
    /// lets every device (including the sender) reconcile the broadcast echo against
    /// its optimistic bubble.
    func send(sessionId: String, text: String, idempotencyKey: String) async throws {
        let ws = try openSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }
        try await handshake(ws)
        try await write(Frames.message(sessionId: sessionId, text: text, idempotencyKey: idempotencyKey), to: ws)
        // Best-effort: await the ack so a thrown error can fail the bubble.
        for _ in 0..<16 {
            guard let env = try await receive(ws) else { continue }
            if env.id == "p0-send" {
                if env.ok == false { throw GatewayError.badStatus(0) }
                return
            }
        }
    }

    // MARK: - Connection

    private func openSocket() throws -> URLSessionWebSocketTask {
        guard let url = wsURL() else { throw GatewayError.unreachable("bad host URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        return task
    }

    private func wsURL() -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: trimmed) else { return nil }
        switch comps.scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case nil:     comps.scheme = "ws"
        default:      break
        }
        if comps.port == nil { comps.port = 18789 } // gateway default (CLAUDE.md)
        return comps.url
    }

    /// Await `connect.challenge`, reply with a token-only connect, return on hello-ok.
    /// Does NOT sign the nonce with a device key — that is the pairing layer's job.
    private func handshake(_ ws: URLSessionWebSocketTask) async throws {
        for _ in 0..<16 {
            guard let env = try await receive(ws) else { continue }
            if env.event == "connect.challenge" || env.type == "connect.challenge" {
                try await write(Frames.connect(token: token), to: ws)
            } else if env.id == "p0-connect" {
                if env.ok == false { throw GatewayError.unauthorized }
                return
            }
        }
        throw GatewayError.unreachable("no hello-ok from gateway")
    }

    private func write(_ frame: [String: Any], to ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ ws: URLSessionWebSocketTask) async throws -> InboundEnvelope? {
        let message = try await ws.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return nil
        }
        return try? JSONDecoder().decode(InboundEnvelope.self, from: data)
    }

    private static func mapError(_ error: Error) -> Error {
        (error as? GatewayError) ?? GatewayError.unreachable(error.localizedDescription)
    }
}

// MARK: - Outbound frames (protocol-v4 WS RPC)

private enum Frames {
    static func connect(token: String) -> [String: Any] {
        [
            "type": "req", "id": "p0-connect", "method": "connect",
            "params": [
                "minProtocol": 4, "maxProtocol": 4,
                // client.id AND client.mode are CLOSED enums. LIVE 2026-07-21: client.id
                // must be "openclaw-ios" (or "cli"); the old "ios-node" now 400s before
                // auth. mode "node" (cli|ui|node|backend). "operator" is a ROLE, not a
                // mode — sending it as client.mode 400s before auth.
                // NOTE: this is still a TOKEN-ONLY connect — device-auth pairing
                // (auth.bootstrapToken + signed device{}) is UNBUILT. See
                // .docs/live-handshake-findings-2026-07-21.md.
                "client": ["id": "openclaw-ios", "version": "0.1.0", "platform": "ios", "mode": "node"],
                "role": "operator",
                "scopes": ["operator.read", "operator.write"],
                "auth": token.isEmpty ? [String: String]() : ["token": token],
            ],
        ]
    }

    static func subscribe(sessionId: String) -> [String: Any] {
        ["type": "req", "id": "p0-subscribe", "method": "sessions.messages.subscribe",
         "params": ["sessionId": sessionId]]
    }

    static func history(sessionId: String) -> [String: Any] {
        ["type": "req", "id": "p0-history", "method": "sessions.messages.list",
         "params": ["sessionId": sessionId, "limit": 500]]
    }

    static func message(sessionId: String, text: String, idempotencyKey: String) -> [String: Any] {
        ["type": "req", "id": "p0-send", "method": "session.message",
         "params": [
            "sessionId": sessionId,
            "message": ["role": "user", "content": text],
            "idempotencyKey": idempotencyKey,
            "clientMessageId": idempotencyKey,
         ]]
    }
}

// MARK: - Inbound frame (permissive — exact shape is a live unknown, P4)

private struct InboundEnvelope: Decodable {
    var type: String?
    var id: String?
    var event: String?
    var method: String?
    var ok: Bool?
    var payload: Payload?

    struct Payload: Decodable {
        var messages: [WireMessage]?
        var message: WireMessage?
    }

    struct WireMessage: Decodable {
        var id: String?
        var role: String?
        var content: String?
        var idempotencyKey: String?
        var clientMessageId: String?

        var asChatMessage: ChatMessage? {
            guard let content else { return nil }
            let role: ChatMessage.Role = (role == "assistant") ? .assistant : .user
            return ChatMessage(role: role, text: content,
                               clientMessageId: idempotencyKey ?? clientMessageId)
        }
    }

    /// A live fan-in message, if this frame is a `session.message` broadcast.
    var broadcastMessage: ChatMessage? {
        guard event == "session.message" || method == "session.message" else { return nil }
        return payload?.message?.asChatMessage
    }
}
