import XCTest
@testable import OpenClawMobile

/// Frames + inbound decoding pinned against the LIVE round-trip of 2026-07-21
/// (tools/phase0-roundtrip.mjs): chat.send / sessions.subscribe / chat.history,
/// and real event payloads captured off the wire.
final class WireProtocolTests: XCTestCase {
    func params(_ f: [String: Any]) -> [String: Any] { f["params"] as! [String: Any] }

    // MARK: - Outbound frames (live-verified method names + shapes)

    func testSendUsesChatSend() {
        let f = GatewayFrames.message(sessionKey: "main", text: "hi", idempotencyKey: "k1")
        XCTAssertEqual(f["method"] as? String, "chat.send")
        let p = params(f)
        XCTAssertEqual(p["sessionKey"] as? String, "main")
        XCTAssertEqual(p["message"] as? String, "hi")
        XCTAssertEqual(p["idempotencyKey"] as? String, "k1")
    }

    func testSubscribeIsGlobalSessionsSubscribe() {
        let f = GatewayFrames.subscribe()
        XCTAssertEqual(f["method"] as? String, "sessions.subscribe")
        XCTAssertEqual((f["params"] as? [String: Any])?.isEmpty, true)
    }

    func testHistoryUsesChatHistory() {
        let f = GatewayFrames.history(sessionKey: "main")
        XCTAssertEqual(f["method"] as? String, "chat.history")
        let p = params(f)
        XCTAssertEqual(p["sessionKey"] as? String, "main")
        XCTAssertNotNil(p["limit"] as? Int)
    }

    // MARK: - WS URL derivation

    /// A Cloudflare-Tunnel https host has NO explicit port and must stay on 443 —
    /// appending :18789 breaks it (live failure 2026-07-21). The 18789 default
    /// only applies to plain http/ws hosts (direct LAN connects).
    func testHttpsTunnelHostKeepsImplicitPort443() {
        let url = GatewayWSSyncSource.wsURL(host: "https://foo.trycloudflare.com")
        XCTAssertEqual(url?.absoluteString, "wss://foo.trycloudflare.com")
    }

    func testPlainHttpHostGetsGatewayDefaultPort() {
        XCTAssertEqual(GatewayWSSyncSource.wsURL(host: "http://192.168.1.10")?.absoluteString,
                       "ws://192.168.1.10:18789")
        // explicit port always wins
        XCTAssertEqual(GatewayWSSyncSource.wsURL(host: "http://192.168.1.10:9999")?.absoluteString,
                       "ws://192.168.1.10:9999")
    }

    // MARK: - Inbound decoding (golden JSON captured live)

    func decode(_ json: String) -> InboundEnvelope? {
        try? JSONDecoder().decode(InboundEnvelope.self, from: Data(json.utf8))
    }

    func testDecodesUserEchoWithStringContent() throws {
        let env = try XCTUnwrap(decode(#"""
        {"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:main","agentId":"main","message":{"role":"user","content":"Hello!","timestamp":1784686995240,"idempotencyKey":"18f7017c-cb62-4254-9d47-6fd8545fe146:user"},"messageId":"cb91e11e"}}
        """#))
        let msg = try XCTUnwrap(env.broadcastMessage)
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hello!")
        // echo key must match the client's idempotencyKey (":user" suffix stripped)
        XCTAssertEqual(msg.clientMessageId, "18f7017c-cb62-4254-9d47-6fd8545fe146")
    }

    func testDecodesAssistantMessageWithArrayContent() throws {
        let env = try XCTUnwrap(decode(#"""
        {"type":"event","event":"session.message","payload":{"sessionKey":"agent:main:main","message":{"role":"assistant","content":[{"type":"text","text":"Hello from Sam."}],"timestamp":1784687000222,"idempotencyKey":"cli-assistant:18f7017c"}}}
        """#))
        let msg = try XCTUnwrap(env.broadcastMessage)
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.text, "Hello from Sam.")
        // `cli-assistant:<runId>` normalizes to the same key as the chat stream's
        // `chat-run:<runId>` so the final transcript message replaces the
        // streaming bubble instead of double-rendering.
        XCTAssertEqual(msg.clientMessageId, "chat-run:18f7017c")
    }

    func testDecodesChatDeltaAsStreamingUpdate() throws {
        let env = try XCTUnwrap(decode(#"""
        {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main","agentId":"main","seq":2,"state":"delta","deltaText":"H","message":{"role":"assistant","content":[{"type":"text","text":"H"}],"timestamp":1784686999522}}}
        """#))
        let msg = try XCTUnwrap(env.broadcastMessage)
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.text, "H")           // message.content is text-so-far
        XCTAssertEqual(msg.clientMessageId, "chat-run:r1") // stable id for in-place updates
        XCTAssertTrue(msg.isStreaming)
    }

    func testDecodesChatFinalAsCompleteMessage() throws {
        let env = try XCTUnwrap(decode(#"""
        {"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"agent:main:main","seq":5,"state":"final","message":{"role":"assistant","content":[{"type":"text","text":"Hello from Sam — done."}],"timestamp":1784687000268}}}
        """#))
        let msg = try XCTUnwrap(env.broadcastMessage)
        XCTAssertEqual(msg.text, "Hello from Sam — done.")
        XCTAssertEqual(msg.clientMessageId, "chat-run:r1")
        XCTAssertFalse(msg.isStreaming)
    }

    func testIgnoresHeartbeatEvents() throws {
        for json in [
            #"{"type":"event","event":"tick","payload":{"ts":1}}"#,
            #"{"type":"event","event":"health","payload":{"ok":true}}"#,
        ] {
            let env = try XCTUnwrap(decode(json))
            XCTAssertNil(env.broadcastMessage)
        }
    }
}
