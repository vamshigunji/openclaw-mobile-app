import CryptoKit
import Foundation
import Network
@testable import OpenClawMobile

/// In-process protocol-v4 gateway for E2E tests (T4, eng review 2026-07-21 4B).
/// Speaks the LIVE-verified wire protocol from the 2026-07-21 captures:
/// challenge → signed connect (v3 Ed25519 signature VERIFIED server-side) →
/// PAIRING_REQUIRED ladder → hello-ok + deviceToken → sessions.subscribe →
/// chat.send ack → session.message echo → chat deltas → chat final.
final class MockGateway: @unchecked Sendable {
    // Config
    /// How many signed connects get PAIRING_REQUIRED before approval.
    var pendingApprovalsBeforeOK: Int
    /// Reject bootstrap connects as expired.
    var expiredCode: Bool
    /// Reply text streamed as chat deltas.
    var replyText: String

    // Observability
    private(set) var verifiedSignatures = 0
    private(set) var receivedMethods: [String] = []

    private var listener: NWListener!
    private var connections: [NWConnection] = []
    /// Connections that called sessions.subscribe — broadcasts go here (like the
    /// real gateway's fan-out), NOT back on the sender's socket.
    private var subscribers: [NWConnection] = []
    private let queue = DispatchQueue(label: "mock-gateway")
    private var nonces: [ObjectIdentifier: String] = [:]
    private(set) var port: UInt16 = 0

    var wsHost: String { "ws://127.0.0.1:\(port)" }

    init(pendingApprovalsBeforeOK: Int = 0, expiredCode: Bool = false,
         replyText: String = "Hello from the mock gateway.") {
        self.pendingApprovalsBeforeOK = pendingApprovalsBeforeOK
        self.expiredCode = expiredCode
        self.replyText = replyText
    }

    func start() throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "MockGateway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        port = listener.port!.rawValue
    }

    func stop() {
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    /// Simulate a tunnel drop: kill every live connection (listener stays up,
    /// so clients CAN reconnect). Used by reconnect/backoff tests (T6).
    func dropAllConnections() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            subscribers.removeAll()
            nonces.removeAll()
        }
    }

    /// Total connects handled (each new WS = one challenge issued).
    var connectionCount: Int { queue.sync { totalConnections } }
    private var totalConnections = 0

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        totalConnections += 1
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            // Gateway speaks first: connect.challenge (LIVE behavior).
            let nonce = UUID().uuidString
            self.nonces[ObjectIdentifier(conn)] = nonce
            self.send(conn, [
                "type": "event", "event": "connect.challenge",
                "payload": ["nonce": nonce, "ts": 1_784_700_000_000],
            ])
            self.receiveLoop(conn)
        }
        conn.start(queue: queue)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(frame, on: conn)
            }
            self.receiveLoop(conn)
        }
    }

    private func handle(_ frame: [String: Any], on conn: NWConnection) {
        guard let method = frame["method"] as? String,
              let id = frame["id"] as? String else { return }
        receivedMethods.append(method)
        let params = frame["params"] as? [String: Any] ?? [:]

        switch method {
        case "connect":  handleConnect(id: id, params: params, on: conn)
        case "sessions.subscribe":
            subscribers.append(conn)
            respond(conn, id: id, payload: ["subscribed": true])
        case "chat.history":
            respond(conn, id: id, payload: ["messages": [
                ["role": "assistant",
                 "content": [["type": "text", "text": "Prior message from history."]],
                 "idempotencyKey": "cli-assistant:hist-1"],
            ]])
        case "chat.send":  handleChatSend(id: id, params: params, on: conn)
        default:
            respond(conn, id: id, ok: false,
                    error: ["code": "INVALID_REQUEST", "message": "unknown method \(method)"])
        }
    }

    private func handleConnect(id: String, params: [String: Any], on conn: NWConnection) {
        let auth = params["auth"] as? [String: Any] ?? [:]

        if expiredCode, auth["bootstrapToken"] != nil {
            respond(conn, id: id, ok: false, error: [
                "code": "INVALID_REQUEST",
                "message": "unauthorized: bootstrap token invalid or expired (scan a fresh setup code)",
                "details": ["code": "AUTH_BOOTSTRAP_TOKEN_INVALID",
                            "authReason": "bootstrap_token_invalid"],
            ])
            return
        }

        // Verify the v3 device signature EXACTLY like the real gateway.
        guard let device = params["device"] as? [String: Any],
              verifyDeviceSignature(device: device, params: params, on: conn) else {
            respond(conn, id: id, ok: false, error: [
                "code": "DEVICE_AUTH_SIGNATURE_INVALID",
                "message": "device signature invalid",
            ])
            return
        }
        verifiedSignatures += 1

        if pendingApprovalsBeforeOK > 0 {
            pendingApprovalsBeforeOK -= 1
            respond(conn, id: id, ok: false, error: [
                "code": "NOT_PAIRED",
                "message": "pairing required: device is not approved yet",
                "details": ["code": "PAIRING_REQUIRED", "reason": "not-paired",
                            "requestId": "mock-req-0001"],
            ])
            return
        }

        respond(conn, id: id, payload: [
            "auth": ["role": "operator",
                     "scopes": ["operator.read", "operator.write"],
                     "deviceToken": "mock-device-token-1"],
            "snapshot": [:], "stateVersion": 1, "seq": 1,
        ])
    }

    private func verifyDeviceSignature(device: [String: Any], params: [String: Any],
                                       on conn: NWConnection) -> Bool {
        guard let deviceId = device["id"] as? String,
              let pubB64url = device["publicKey"] as? String,
              let sigB64url = device["signature"] as? String,
              let signedAt = device["signedAt"] as? Int64 ?? (device["signedAt"] as? Int).map(Int64.init),
              let nonce = device["nonce"] as? String,
              let expectedNonce = nonces[ObjectIdentifier(conn)],
              nonce == expectedNonce,
              let rawPub = Data(base64urlEncoded: pubB64url),
              let sig = Data(base64urlEncoded: sigB64url),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawPub)
        else { return false }

        // deviceId must be sha256(raw pubkey) hex
        let expectedId = SHA256.hash(data: rawPub).map { String(format: "%02x", $0) }.joined()
        guard deviceId == expectedId else { return false }

        let client = params["client"] as? [String: Any] ?? [:]
        let auth = params["auth"] as? [String: Any] ?? [:]
        let scopes = params["scopes"] as? [String] ?? []
        let token = (auth["token"] as? String) ?? (auth["bootstrapToken"] as? String)
        let payload = DeviceAuth.payloadV3(
            deviceId: deviceId,
            clientId: client["id"] as? String ?? "",
            clientMode: client["mode"] as? String ?? "",
            role: params["role"] as? String ?? "",
            scopes: scopes, signedAtMs: signedAt, token: token, nonce: nonce,
            platform: client["platform"] as? String, deviceFamily: nil)
        return pubKey.isValidSignature(sig, for: Data(payload.utf8))
    }

    private func handleChatSend(id: String, params: [String: Any], on conn: NWConnection) {
        let idem = params["idempotencyKey"] as? String ?? UUID().uuidString
        let text = params["message"] as? String ?? ""
        let key = params["sessionKey"] as? String ?? "main"
        let sessionKey = key.contains(":") ? key : "agent:\(key):\(key)"

        respond(conn, id: id, payload: ["runId": idem, "status": "started"])

        // LIVE-shaped broadcast sequence (golden capture 2026-07-21) — fanned
        // out to subscribed connections, falling back to the sender.
        let targets = subscribers.isEmpty ? [conn] : subscribers
        broadcast(targets, ["type": "event", "event": "session.message", "payload": [
            "sessionKey": sessionKey, "agentId": "main",
            "message": ["role": "user", "content": text,
                        "idempotencyKey": "\(idem):user"],
            "messageId": "mock-msg-1", "messageSeq": 1,
        ]])
        // stream the reply in two deltas + final
        let half = replyText.index(replyText.startIndex,
                                   offsetBy: max(1, replyText.count / 2))
        let part1 = String(replyText[..<half])
        for (seq, sofar) in [(2, part1), (3, replyText)] {
            broadcast(targets, ["type": "event", "event": "chat", "payload": [
                "runId": idem, "sessionKey": sessionKey, "agentId": "main",
                "seq": seq, "state": "delta", "deltaText": sofar,
                "message": ["role": "assistant",
                            "content": [["type": "text", "text": sofar]]],
            ]])
        }
        broadcast(targets, ["type": "event", "event": "chat", "payload": [
            "runId": idem, "sessionKey": sessionKey, "agentId": "main",
            "seq": 4, "state": "final",
            "message": ["role": "assistant",
                        "content": [["type": "text", "text": replyText]]],
        ]])
    }

    private func broadcast(_ targets: [NWConnection], _ frame: [String: Any]) {
        targets.forEach { send($0, frame) }
    }

    // MARK: - Frame IO

    private func respond(_ conn: NWConnection, id: String,
                         ok: Bool = true, payload: [String: Any] = [:],
                         error: [String: Any]? = nil) {
        var frame: [String: Any] = ["type": "res", "id": id, "ok": ok]
        if ok { frame["payload"] = payload }
        if let error { frame["error"] = error }
        send(conn, frame)
    }

    private func send(_ conn: NWConnection, _ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .contentProcessed { _ in })
    }
}
