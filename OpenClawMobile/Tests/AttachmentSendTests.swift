import XCTest
@testable import OpenClawMobile

/// Attachments over native `chat.send` (design §4.2), end-to-end against the mock gateway:
/// one optimistic bubble carrying the local attachments, one frame with the wire shape,
/// and no duplicate after the gateway echoes our idempotency key.
final class AttachmentSendTests: XCTestCase {
    var gateway: MockGateway!

    override func tearDown() {
        gateway?.stop()
        gateway = nil
        super.tearDown()
    }

    @MainActor
    private func makeViewModel() throws -> (ChatViewModel, SettingsStore) {
        let sync = GatewayWSSyncSource(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                                       identity: DeviceIdentity())
        let settings = SettingsStore()
        settings.host = gateway.wsHost
        let vm = ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: sync, settings: settings)
        vm.start()
        return (vm, settings)
    }

    @MainActor
    func testTwoAttachmentsMakeOneBubbleAndOneFrame() async throws {
        gateway = MockGateway(replyText: "got them")
        try gateway.start()
        let (vm, settings) = try makeViewModel()
        defer { settings.host = "" }
        try await Task.sleep(for: .milliseconds(500)) // let subscribe attach (CI headroom)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature; the mock never decodes
        vm.pendingAttachments = [
            Attachment(kind: .image, fileName: "a.png", mimeType: "image/png", data: png, width: 1, height: 1),
            Attachment(kind: .image, fileName: "b.png", mimeType: "image/png", data: png, width: 1, height: 1),
        ]
        vm.draft = "two pics"
        XCTAssertTrue(vm.canSend)
        vm.send()

        let replied = await waitUntil {
            vm.messages.contains { $0.role == .assistant && !$0.isStreaming && $0.text == "got them" }
        }
        XCTAssertTrue(replied, "the mock reply (after the echo) should arrive")

        let userBubbles = vm.messages.filter { $0.role == .user }
        XCTAssertEqual(userBubbles.count, 1, "optimistic bubble + gateway echo must not double-render")
        XCTAssertEqual(userBubbles.first?.text, "two pics")
        XCTAssertEqual(userBubbles.first?.attachments.map(\.fileName), ["a.png", "b.png"])
        XCTAssertTrue(vm.pendingAttachments.isEmpty, "tray clears on send")

        let frame = try XCTUnwrap(gateway.receivedFrames.last { ($0["method"] as? String) == "chat.send" })
        let params = try XCTUnwrap(frame["params"] as? [String: Any])
        XCTAssertEqual(params["message"] as? String, "two pics")
        let attachments = try XCTUnwrap(params["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments.map { $0["fileName"] as? String }, ["a.png", "b.png"])
        for a in attachments {
            XCTAssertEqual(a["type"] as? String, "image")
            XCTAssertEqual(a["mimeType"] as? String, "image/png")
            XCTAssertEqual(a["content"] as? String, png.base64EncodedString())
            XCTAssertEqual(a["sizeBytes"] as? Int, png.count)
            XCTAssertEqual(a["width"] as? Int, 1)
        }
    }

    @MainActor
    func testAttachmentOnlySendIsAllowed() async throws {
        gateway = MockGateway()
        try gateway.start()
        let (vm, settings) = try makeViewModel()
        defer { settings.host = "" }
        vm.pendingAttachments = [Attachment(kind: .file, fileName: "notes.pdf", mimeType: "application/pdf",
                                            data: Data(repeating: 1, count: 1024))]
        XCTAssertTrue(vm.canSend, "an attachment with no text is still a message")
        vm.send()
        let sent = await waitUntil { self.gateway.receivedMethods.contains("chat.send") }
        XCTAssertTrue(sent)
        XCTAssertEqual(vm.messages.last(where: { $0.role == .user })?.attachments.count, 1)
    }

    @MainActor
    func testFrameOverPayloadLimitFailsLocallyWithoutSending() async throws {
        gateway = MockGateway()
        try gateway.start()
        let (vm, settings) = try makeViewModel()
        defer { settings.host = "" }
        vm.pendingAttachments = [Attachment(kind: .file, fileName: "big.bin", mimeType: "application/octet-stream",
                                            data: Data(count: 20 * 1024 * 1024))]
        vm.draft = "too big"
        vm.send()
        let failed = await waitUntil { vm.messages.last(where: { $0.role == .user })?.failed == true }
        XCTAssertTrue(failed, "oversized frames are rejected before send")
        XCTAssertFalse(gateway.receivedMethods.contains("chat.send"), "nothing should reach the gateway")
    }
}
