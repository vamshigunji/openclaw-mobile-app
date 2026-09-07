import Foundation

/// T6 (eng review 2026-07-21, issue 1A): ONE socket, ONE signed handshake,
/// unique request ids, event fan-out, reconnect with exponential backoff and
/// auto-resubscribe. Closes the "silent subscribe death" critical gap — when
/// the tunnel drops, every consumer heals through this single place.
///
///                  ┌────────────────────────────────────────┐
///                  │        GatewayConnection (actor)        │
///  request() ─────▶│ unique req ids → continuation map       │──▶ events()
///  (send/history/  │ backoff 1s→2s→…→30s · resubscribe       │    AsyncStream
///   subscribe)     │ deviceToken refresh on every hello-ok   │    (survives
///                  └────────────────────────────────────────┘     reconnects)
actor GatewayConnection {
    private let host: String
    private var auth: GatewayFrames.Auth // upgraded when hello-ok mints a token
    private let identity: DeviceIdentity
    private let onDeviceToken: (@Sendable (String) -> Void)?
    private let reconnectBaseDelay: Duration
    private static let reconnectCap: Duration = .seconds(30) // protocol.md §3

    private var ws: URLSessionWebSocketTask?
    private var readTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Single in-flight connect shared by concurrent callers (actor reentrancy:
    /// two request()s can both observe ws == nil across an await).
    private var connectTask: Task<Void, Error>?
    private var nextId = 0
    private var pending: [String: CheckedContinuation<InboundEnvelope, Error>] = [:]
    private var eventSubs: [UUID: AsyncStream<InboundEnvelope>.Continuation] = [:]
    /// Observers of "is the socket up right now" — the UI must never imply liveness it lacks.
    private var stateSubs: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// Attachment ceilings from the latest hello-ok; nil until a handshake completes.
    private var policy: AttachmentPolicy?
    private var wantsSessionSubscription = false
    private var isShutdown = false

    init(host: String, auth: GatewayFrames.Auth, identity: DeviceIdentity,
         reconnectBaseDelay: Duration = .seconds(1),
         onDeviceToken: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.auth = auth
        self.identity = identity
        self.reconnectBaseDelay = reconnectBaseDelay
        self.onDeviceToken = onDeviceToken
    }

    // MARK: - Public API

    /// Send a request and await its response envelope. Connects (and
    /// handshakes) on first use; concurrent callers share the socket.
    func request(method: String, params: [String: Any],
                 timeout: Duration = .seconds(15)) async throws -> InboundEnvelope {
        try await ensureConnected(timeout: timeout)
        if method == "sessions.subscribe" { wantsSessionSubscription = true }
        nextId += 1
        let id = "r\(nextId)"
        let frame: [String: Any] = ["type": "req", "id": id, "method": method, "params": params]
        guard let ws else { throw GatewayError.unreachable("not connected") }
        let data = try JSONSerialization.data(withJSONObject: frame)
        let text = String(decoding: data, as: UTF8.self)
        WireLog.out(Self.logSafe(frame) ?? text)
        try await ws.send(.string(text))

        // Watchdog: never let a caller hang on a dead socket.
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timeoutPending(id: id)
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    /// The frame for the DEBUG wire log with attachment bodies replaced by their size —
    /// photos never land in a log file. nil when there is nothing to redact.
    private static func logSafe(_ frame: [String: Any]) -> String? {
        guard var params = frame["params"] as? [String: Any],
              let attachments = params["attachments"] as? [[String: Any]] else { return nil }
        params["attachments"] = attachments.map { a -> [String: Any] in
            var copy = a
            if let content = a["content"] as? String { copy["content"] = "<\(content.count) base64 chars>" }
            return copy
        }
        var redacted = frame
        redacted["params"] = params
        guard let data = try? JSONSerialization.data(withJSONObject: redacted) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Live event stream (chat deltas, session.message, sessions.changed…).
    /// The stream stays open across reconnects — that is the whole point.
    func events() -> AsyncStream<InboundEnvelope> {
        let key = UUID()
        return AsyncStream { cont in
            eventSubs[key] = cont
            cont.onTermination = { _ in
                Task { [weak self] in await self?.removeEventSub(key) }
            }
        }
    }

    /// What the gateway said its attachment ceilings are, if it said anything.
    func attachmentPolicy() -> AttachmentPolicy? { policy }

    /// Live socket state: `false` the moment a read fails, `true` again after a successful
    /// handshake. Yields the current value immediately on subscribe.
    func connectionState() -> AsyncStream<Bool> {
        let key = UUID()
        return AsyncStream { cont in
            stateSubs[key] = cont
            cont.yield(ws != nil)
            cont.onTermination = { _ in
                Task { [weak self] in await self?.removeStateSub(key) }
            }
        }
    }

    private func removeStateSub(_ key: UUID) { stateSubs.removeValue(forKey: key) }

    private func publishState(_ up: Bool) {
        for cont in stateSubs.values { cont.yield(up) }
    }

    func shutdown() {
        isShutdown = true
        reconnectTask?.cancel()
        readTask?.cancel()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        failAllPending(GatewayError.unreachable("connection shut down"))
        eventSubs.values.forEach { $0.finish() }
        eventSubs.removeAll()
        publishState(false)
        stateSubs.values.forEach { $0.finish() }
        stateSubs.removeAll()
    }

    // MARK: - Connect / handshake

    private func ensureConnected(timeout: Duration) async throws {
        guard ws == nil, !isShutdown else { return }
        if let inFlight = connectTask {
            try await inFlight.value
            return
        }
        let task = Task {
            // Transient transport failures (sim network churn, tunnel blips)
            // resolve on immediate retry — seen live 2026-07-22. One retry,
            // URLError only; protocol errors (pairing, auth) surface untouched.
            do {
                try await connect(timeout: timeout)
            } catch let e as URLError {
                WireLog.note("connect transport error (\(e.code.rawValue)), retrying once")
                try await Task.sleep(for: .milliseconds(300))
                try await connect(timeout: timeout)
            }
        }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    private func connect(timeout: Duration) async throws {
        guard let url = GatewayWSSyncSource.wsURL(host: host) else {
            throw GatewayError.unreachable("bad host URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if case .token(let t) = auth {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        let task = URLSession.shared.webSocketTask(with: req)
        task.resume()

        // challenge → signed connect → hello-ok (deadline-bounded)
        let deadline = ContinuousClock.now + timeout
        for _ in 0..<16 {
            guard ContinuousClock.now < deadline else { break }
            guard let env = try await Self.receiveEnvelope(task) else { continue }
            if env.event == "connect.challenge" || env.type == "connect.challenge" {
                let device = try DeviceAuth.deviceParams(
                    identity: identity, nonce: env.challengeNonce ?? "",
                    role: "operator", scopes: GatewayFrames.scopes,
                    signatureToken: auth.signatureToken,
                    signedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
                let frame = GatewayFrames.connect(auth: auth, device: device)
                let data = try JSONSerialization.data(withJSONObject: frame)
                let text = String(decoding: data, as: UTF8.self)
                WireLog.out(text)
                try await task.send(.string(text))
            } else if env.id == "p0-connect" {
                if env.ok == false || env.error != nil {
                    task.cancel(with: .goingAway, reason: nil)
                    if env.isPairingRequired {
                        throw GatewayError.pairingPending(requestId: env.pairingRequestId)
                    }
                    if env.isBootstrapInvalid { throw GatewayError.bootstrapExpired }
                    throw GatewayError.unauthorized
                }
                if let minted = env.payload?.auth?.deviceToken, !minted.isEmpty {
                    auth = .token(minted) // reconnects use the freshest token
                    onDeviceToken?(minted)
                }
                if let advertised = env.payload?.policy {
                    var p = AttachmentPolicy.default
                    if let v = advertised.maxPayload { p.maxPayload = v }
                    if let v = advertised.attachments?.maxBytes { p.maxBytes = v }
                    if let v = advertised.attachments?.maxImageBytes { p.maxImageBytes = v }
                    policy = p
                }
                ws = task
                startReadLoop(task)
                publishState(true)
                return
            }
        }
        task.cancel(with: .goingAway, reason: nil)
        throw GatewayError.unreachable("no hello-ok from gateway")
    }

    private func startReadLoop(_ task: URLSessionWebSocketTask) {
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let env = try await Self.receiveEnvelope(task) else { continue }
                    await self?.dispatch(env)
                } catch {
                    await self?.handleDisconnect(error)
                    return
                }
            }
        }
    }

    private static func receiveEnvelope(_ task: URLSessionWebSocketTask) async throws -> InboundEnvelope? {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return nil
        }
        WireLog.inbound(String(decoding: data, as: UTF8.self))
        return try? JSONDecoder().decode(InboundEnvelope.self, from: data)
    }

    // MARK: - Dispatch

    private func dispatch(_ env: InboundEnvelope) {
        if let id = env.id, let cont = pending.removeValue(forKey: id) {
            cont.resume(returning: env)
            return
        }
        for cont in eventSubs.values { cont.yield(env) }
    }

    private func timeoutPending(id: String) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: GatewayError.unreachable("request timed out"))
        }
    }

    private func failAllPending(_ error: Error) {
        let conts = pending.values
        pending.removeAll()
        conts.forEach { $0.resume(throwing: error) }
    }

    private func removeEventSub(_ key: UUID) {
        eventSubs.removeValue(forKey: key)
    }

    // MARK: - Reconnect (backoff 1s→2s→…→30s, then steady 30s; protocol.md §3)

    private func handleDisconnect(_ error: Error) {
        guard ws != nil || !pending.isEmpty else { return }
        WireLog.note("disconnected: \(error.localizedDescription)")
        publishState(false)
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        readTask = nil
        failAllPending(GatewayError.unreachable("connection lost"))
        guard !isShutdown, reconnectTask == nil,
              wantsSessionSubscription || !eventSubs.isEmpty else { return }
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    private func reconnectLoop() async {
        defer { reconnectTask = nil }
        var attempt = 0
        while !isShutdown, !Task.isCancelled {
            let factor = 1 << min(attempt, 5) // 1,2,4,8,16,32× (capped below)
            let delay = min(reconnectBaseDelay * factor, Self.reconnectCap)
            try? await Task.sleep(for: delay)
            do {
                try await connect(timeout: .seconds(15))
                if wantsSessionSubscription {
                    nextId += 1
                    let frame: [String: Any] = ["type": "req", "id": "r\(nextId)",
                                                "method": "sessions.subscribe", "params": [String: Any]()]
                    let data = try JSONSerialization.data(withJSONObject: frame)
                    try await ws?.send(.string(String(decoding: data, as: UTF8.self)))
                }
                WireLog.note("reconnected after \(attempt + 1) attempt(s)")
                return
            } catch {
                attempt += 1
                WireLog.note("reconnect attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
    }
}
