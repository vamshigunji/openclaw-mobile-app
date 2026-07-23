import Foundation
import os

/// DEBUG wire tap — watch live with:
/// xcrun simctl spawn booted log stream --predicate 'subsystem == "com.openclaw.mobile"' --style compact
enum WireLog {
    static let log = Logger(subsystem: "com.openclaw.mobile", category: "ws")
    static func out(_ s: String) {
        #if DEBUG
        log.info("→ \(s, privacy: .public)")
        #endif
    }
    static func inbound(_ s: String) {
        #if DEBUG
        log.info("← \(s.prefix(600), privacy: .public)")
        #endif
    }
    static func note(_ s: String) {
        #if DEBUG
        log.info("· \(s, privacy: .public)")
        #endif
    }
}

/// Path-A `SyncSource`: gateway-native multi-device sync over protocol-v4 WS RPC.
///
/// - `loadHistory` → `sessions.messages.list`
/// - `subscribe`   → `sessions.messages.subscribe` fan-in of `session.message` events
/// - `send`        → `session.message` WS write (NOT part of `SyncSource`; the send
///                   path stays on WS with a client idempotency key per PRD-handshake §5)
///
/// Every connect performs signed device-auth (.docs/protocol.md §5): it replies to
/// `connect.challenge` with a `connect` frame carrying the Keychain-held Ed25519
/// `device{}` signature. Steady state uses the paired `deviceToken`; first pairing
/// passes the setup code as `auth.bootstrapToken` and surfaces
/// `PAIRING_REQUIRED` as `GatewayError.pairingPending` until the operator approves.
/// A `hello-ok` that mints a deviceToken reports it via `onDeviceToken`.
///
/// NOTE: the live PASS/FAIL of this path (P1–P7) is a human checkpoint — see
/// `tools/phase0-verify.mjs` and `.docs/sync.md`. This code is
/// Path-A-complete but viability-UNVERIFIED until a live two-device run.
struct GatewayWSSyncSource: SyncSource {
    let host: String
    let auth: GatewayFrames.Auth
    let identity: DeviceIdentity
    /// Called when hello-ok mints a device-bound token (first pairing) so the
    /// caller can persist it (Keychain) and reconnect with `.token`.
    let onDeviceToken: (@Sendable (String) -> Void)?
    /// T6: steady-state chat traffic shares ONE connection (single handshake,
    /// reconnect+resubscribe, request-id correlation). Struct copies share it.
    private let connection: GatewayConnection

    init(host: String, auth: GatewayFrames.Auth, identity: DeviceIdentity,
         onDeviceToken: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.auth = auth
        self.identity = identity
        self.onDeviceToken = onDeviceToken
        self.connection = GatewayConnection(host: host, auth: auth,
                                            identity: identity,
                                            onDeviceToken: onDeviceToken)
    }

    // MARK: - SyncSource (roster + history + subscribe)

    /// LIVE-verified 2026-07-22: texting agent `<id>` needs the FULL canonical
    /// session key `agent:<id>:main` WITH a matching `agentId`. A bare key + a
    /// separate agentId is rejected ("agentId does not match session key").
    static func sessionKey(forAgent id: String) -> String { "agent:\(id):main" }

    func listAgents() async throws -> [AgentSummary] {
        let env = try await connection.request(method: "agents.list", params: [String: Any]())
        if env.ok == false { throw GatewayError.badStatus(0) }
        return env.payload?.agents ?? []
    }

    /// Reads the agent's behavior file (AGENTS.md) directly — operator.read, no main
    /// needed. Returns nil if the agent has no readable instructions file.
    func loadInstructions(agentId: String) async throws -> String? {
        let list = try await connection.request(method: "agents.files.list",
                                                params: ["agentId": agentId])
        let names = (list.payload?.files ?? []).compactMap(\.name)
        guard let fileName = AgentProfile.instructionsFile(from: names) else { return nil }
        let got = try await connection.request(method: "agents.files.get",
                                               params: ["agentId": agentId, "name": fileName])
        return got.payload?.file?.content
    }

    func loadHistory(agentId: String) async throws -> [ChatMessage] {
        let env = try await connection.request(
            method: "chat.history",
            params: ["sessionKey": Self.sessionKey(forAgent: agentId),
                     "agentId": agentId, "limit": 200])
        if env.ok == false { throw GatewayError.badStatus(0) }
        return (env.payload?.messages ?? []).compactMap { $0.asChatMessage }
    }

    /// Subscribes once connection-wide, then filters the shared stream to this
    /// agent so each thread only sees its own turns (multi-agent routing).
    func subscribe(agentId: String?) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Register the event stream FIRST, THEN subscribe — otherwise
                    // any event that arrives between the subscribe ack and stream
                    // registration is dropped (real race; surfaced on slow CI).
                    let events = await connection.events()
                    _ = try await connection.request(method: "sessions.subscribe",
                                                     params: [String: Any]())
                    // The actor's event stream survives reconnects (it
                    // resubscribes internally) — no error surfaces on a drop.
                    for await env in events {
                        if Task.isCancelled { break }
                        guard env.matchesAgent(agentId) else { continue }
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
    func send(agentId: String, text: String, idempotencyKey: String) async throws {
        let env = try await connection.request(
            method: "chat.send",
            params: ["sessionKey": Self.sessionKey(forAgent: agentId),
                     "agentId": agentId, "message": text,
                     "idempotencyKey": idempotencyKey])
        if env.ok == false { throw GatewayError.badStatus(0) }
    }

    // MARK: - Activity (live "what is the agent doing")

    /// Maps the shared event stream to this agent's live activity (Thinking /
    /// Searching the web / Running a command …). Reads the same connection events
    /// as `subscribe`; the message subscription already sent `sessions.subscribe`.
    func activityStream(agentId: String) -> AsyncStream<AgentActivity> {
        AsyncStream { continuation in
            let task = Task {
                for await env in await connection.events() {
                    if Task.isCancelled { break }
                    guard env.matchesAgent(agentId) else { continue }
                    if let activity = AgentActivity.from(env) {
                        continuation.yield(activity)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pairing

    /// One signed connect round-trip and close. Used by the Settings pairing flow:
    /// construct with `.bootstrap(setupCode)` and `onDeviceToken`, then call until
    /// it stops throwing `.pairingPending` (operator approval) — hello-ok fires
    /// `onDeviceToken` with the minted device-bound token.
    func connectOnce() async throws {
        do {
            try await connectOnceAttempt()
        } catch let e as URLError {
            // One retry on transport-level failure (seen live 2026-07-22:
            // simulator network churn failed the first pairing tap).
            WireLog.note("pairing connect transport error (\(e.code.rawValue)), retrying once")
            try await Task.sleep(for: .milliseconds(300))
            try await connectOnceAttempt()
        }
    }

    private func connectOnceAttempt() async throws {
        let ws = try openSocket()
        defer { ws.cancel(with: .goingAway, reason: nil) }
        try await handshake(ws)
    }

    // MARK: - Connection

    private func openSocket() throws -> URLSessionWebSocketTask {
        guard let url = Self.wsURL(host: host) else { throw GatewayError.unreachable("bad host URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if case .token(let t) = auth { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()
        return task
    }

    static func wsURL(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard var comps = URLComponents(string: trimmed) else { return nil }
        let isTLS = comps.scheme == "https" || comps.scheme == "wss"
        switch comps.scheme {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case nil:     comps.scheme = "ws"
        default:      break
        }
        // Gateway default port only for plain hosts (direct LAN). TLS hosts are
        // tunnels/proxies on implicit 443 — forcing :18789 breaks them (LIVE bug
        // 2026-07-21).
        if comps.port == nil && !isTLS { comps.port = 18789 }
        return comps.url
    }

    /// Await `connect.challenge`, reply with a signed device connect, return on
    /// hello-ok. The v3 signature covers the challenge nonce + the signatureToken
    /// (.docs/protocol.md §5); `PAIRING_REQUIRED` means the device awaits operator
    /// approval and is retryable.
    private func handshake(_ ws: URLSessionWebSocketTask) async throws {
        for _ in 0..<16 {
            guard let env = try await receive(ws) else { continue }
            if env.event == "connect.challenge" || env.type == "connect.challenge" {
                let nonce = env.challengeNonce ?? ""
                let device = try DeviceAuth.deviceParams(
                    identity: identity, nonce: nonce, role: "operator",
                    scopes: GatewayFrames.scopes,
                    signatureToken: auth.signatureToken,
                    signedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
                try await write(GatewayFrames.connect(auth: auth, device: device), to: ws)
            } else if env.id == "p0-connect" {
                if env.ok == false || env.error != nil {
                    if env.isPairingRequired {
                        throw GatewayError.pairingPending(requestId: env.pairingRequestId)
                    }
                    if env.isBootstrapInvalid { throw GatewayError.bootstrapExpired }
                    throw GatewayError.unauthorized
                }
                if let minted = env.payload?.auth?.deviceToken, !minted.isEmpty {
                    onDeviceToken?(minted)
                }
                return
            }
        }
        throw GatewayError.unreachable("no hello-ok from gateway")
    }

    private func write(_ frame: [String: Any], to ws: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        let text = String(decoding: data, as: UTF8.self)
        WireLog.out(text)
        try await ws.send(.string(text))
    }

    private func receive(_ ws: URLSessionWebSocketTask) async throws -> InboundEnvelope? {
        let message = try await ws.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return nil
        }
        WireLog.inbound(String(decoding: data, as: UTF8.self))
        return try? JSONDecoder().decode(InboundEnvelope.self, from: data)
    }

    private static func mapError(_ error: Error) -> Error {
        (error as? GatewayError) ?? GatewayError.unreachable(error.localizedDescription)
    }
}

// MARK: - Inbound frame (shapes LIVE-verified 2026-07-21, tools/phase0-roundtrip.mjs)

struct InboundEnvelope: Decodable {
    var type: String?
    var id: String?
    var event: String?
    var method: String?
    var ok: Bool?
    var payload: Payload?
    var params: Payload?
    var error: ErrorBody?
    var nonce: String?

    struct ErrorBody: Decodable {
        var code: String?
        var message: String?
        var details: Details?

        struct Details: Decodable {
            var code: String?
            var reason: String?
            var requestId: String?
            var authReason: String?
        }
    }

    struct Payload: Decodable {
        var messages: [WireMessage]?
        var message: WireMessage?
        var nonce: String?
        var auth: AuthBody?
        var error: ErrorBody?
        // chat stream events (state: delta|final|aborted|error)
        var runId: String?
        var state: String?
        var stream: String?          // agent event: lifecycle|thinking|assistant|tool…
        var deltaText: String?
        var sessionKey: String?
        var agentId: String?          // which agent this event belongs to (routing)
        // activity signals (agent / session.tool events)
        var data: EventData?
        // agents.list result
        var agents: [AgentSummary]?
        var defaultId: String?
        // agents.files.list / .get result
        var files: [FileEntry]?
        var file: FileEntry?

        struct FileEntry: Decodable { var name: String?; var content: String? }

        struct AuthBody: Decodable {
            var scopes: [String]?
            var deviceToken: String?
        }

        /// `data` payload of `agent` / `session.tool` events: lifecycle phase and,
        /// for tool events, the tool name (LIVE 2026-07-22).
        struct EventData: Decodable {
            var phase: String?   // start | end | result | error …
            var name: String?    // tool name (WebSearch, Bash, …) for session.tool
        }
    }

    /// Normalized event name (`event` ?? `method`) for activity mapping.
    var eventKind: String? { event ?? method }

    /// The agent an inbound broadcast belongs to, for per-agent routing.
    var broadcastAgentId: String? { payload?.agentId }

    /// True when this event belongs to `agentId` (nil = accept all agents).
    func matchesAgent(_ agentId: String?) -> Bool {
        guard let agentId else { return true }
        return broadcastAgentId == agentId
    }

    /// Challenge nonce: `payload.nonce ?? params.nonce ?? nonce` (probe-verified fallbacks).
    var challengeNonce: String? { payload?.nonce ?? params?.nonce ?? nonce }

    var errorCode: String? { error?.code ?? payload?.error?.code ?? error?.message }

    /// LIVE 2026-07-21: PAIRING_REQUIRED arrives as error.details.code with the
    /// pending requestId alongside — surfaced so the UI can show the exact
    /// `openclaw devices approve <id>` command.
    var isPairingRequired: Bool {
        error?.details?.code == "PAIRING_REQUIRED" || errorCode == "NOT_PAIRED"
    }
    var pairingRequestId: String? { error?.details?.requestId }
    var isBootstrapInvalid: Bool {
        error?.details?.code == "AUTH_BOOTSTRAP_TOKEN_INVALID"
            || error?.details?.authReason?.hasPrefix("bootstrap_token") == true
    }

    struct WireMessage: Decodable {
        var role: String?
        var text: String?          // flattened from string-or-array content
        var idempotencyKey: String?

        enum CodingKeys: String, CodingKey { case role, content, idempotencyKey }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
            // LIVE: user content is a plain string; assistant content is an array
            // of {type:"text", text:"…"} blocks.
            if let s = try? c.decode(String.self, forKey: .content) {
                text = s
            } else if let blocks = try? c.decode([ContentBlock].self, forKey: .content) {
                text = blocks.compactMap(\.text).joined()
            }
        }

        struct ContentBlock: Decodable {
            var type: String?
            var text: String?
        }

        var asChatMessage: ChatMessage? {
            guard let text else { return nil }
            let role: ChatMessage.Role = (role == "assistant") ? .assistant : .user
            // LIVE: the echo of our own send carries `<idempotencyKey>:user` —
            // strip the suffix so it matches the key the client generated. The
            // assistant transcript message carries `cli-assistant:<runId>` —
            // normalize to `chat-run:<runId>` so it replaces the streaming bubble.
            var key = idempotencyKey
            if let k = key, k.hasSuffix(":user") { key = String(k.dropLast(5)) }
            if let k = key, k.hasPrefix("cli-assistant:") {
                key = "chat-run:" + k.dropFirst("cli-assistant:".count)
            }
            return ChatMessage(role: role, text: text, clientMessageId: key)
        }
    }

    /// The live fan-in message, if this frame carries one:
    /// - `session.message` events → complete messages (user echo + assistant final)
    /// - `chat` events → streaming assistant updates; `message.content` holds the
    ///   text-so-far and `chat-run:<runId>` is a stable id for in-place updates.
    var broadcastMessage: ChatMessage? {
        switch event ?? method {
        case "session.message":
            return payload?.message?.asChatMessage
        case "chat":
            guard let p = payload, let runId = p.runId,
                  var msg = p.message?.asChatMessage else { return nil }
            msg.clientMessageId = "chat-run:\(runId)"
            msg.isStreaming = (p.state == "delta")
            return msg
        default:
            return nil
        }
    }
}
