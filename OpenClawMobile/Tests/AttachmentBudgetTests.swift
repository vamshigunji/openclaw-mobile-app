import XCTest
@testable import OpenClawMobile

/// Attachment budgets (design §4.2): images are re-encoded once (2048 px / 0.8) and rejected
/// only if still over `maxImageBytes`; small text files inline as a fenced block; other files
/// attach up to `maxBytes`; the whole frame must fit `maxPayload`. Limits come from hello-ok
/// `policy.attachments` when captured, else the protocol defaults.
final class AttachmentBudgetTests: XCTestCase {
    private let policy = AttachmentPolicy.default
    private let mib = 1024 * 1024

    func testDefaultsMatchProtocolDoc() {
        XCTAssertEqual(policy.maxBytes, 20 * mib)
        XCTAssertEqual(policy.maxImageBytes, 6 * mib)
        XCTAssertEqual(policy.maxPayload, 25 * mib)
    }

    func testImagesAlwaysGetTheSingleReencodeStep() {
        let plan = AttachmentBudget.plan(fileName: "IMG_0001.HEIC", mimeType: "image/heic",
                                         bytes: 7 * mib, isImage: true, policy: policy)
        XCTAssertEqual(plan, .reencodeImage(maxEdge: 2048, quality: 0.8))
    }

    func testReencodedImageStillOverCapIsRejected() {
        XCTAssertEqual(AttachmentBudget.verifyImage(bytes: 7 * mib, policy: policy), .tooLarge(max: 6 * mib))
        XCTAssertEqual(AttachmentBudget.verifyImage(bytes: 1_200_000, policy: policy), .ok)
    }

    func testSmallSourceFileInlinesAsFence() {
        let plan = AttachmentBudget.plan(fileName: "AppModel.swift", mimeType: "public.swift-source",
                                         bytes: 8 * 1024, isImage: false, policy: policy)
        XCTAssertEqual(plan, .inlineFence(lang: "swift"))
        XCTAssertEqual(AttachmentBudget.fence(fileName: "AppModel.swift", lang: "swift", text: "let x = 1"),
                       "`AppModel.swift`:\n```swift\nlet x = 1\n```")
    }

    func testLargeTextFileAttachesInsteadOfInlining() {
        let plan = AttachmentBudget.plan(fileName: "build.log", mimeType: "text/plain",
                                         bytes: 300 * 1024, isImage: false, policy: policy)
        XCTAssertEqual(plan, .attach)
    }

    func testOversizedBinaryIsRejectedWithTheCap() {
        let plan = AttachmentBudget.plan(fileName: "spec.pdf", mimeType: "application/pdf",
                                         bytes: 21 * mib, isImage: false, policy: policy)
        XCTAssertEqual(plan, .tooLarge(max: 20 * mib))
    }

    func testFrameOverMaxPayloadIsRejectedBeforeSend() {
        // 20 MB of attachment bytes inflate to ~26.7 MB as base64 — over the 25 MiB frame limit.
        let over = AttachmentBudget.checkPayload(messageBytes: 100, attachmentBytes: [20 * mib], policy: policy)
        XCTAssertEqual(over, .payloadTooLarge(max: 25 * mib))
        let ok = AttachmentBudget.checkPayload(messageBytes: 100, attachmentBytes: [2 * mib, 3 * mib], policy: policy)
        XCTAssertEqual(ok, .ok)
    }

    /// P3.4 — the gateway's advertised ceilings win over our defaults, end to end.
    @MainActor
    func testPolicyIsReadFromTheGatewayHandshake() async throws {
        let gateway = MockGateway()
        // A gateway configured smaller than our defaults: 2 MB per attachment, 1 MB per image.
        gateway.attachmentPolicy = ["maxBytes": 2 * 1024 * 1024, "maxImageBytes": 1024 * 1024]
        try gateway.start()
        defer { gateway.stop() }

        let sync = GatewayWSSyncSource(host: gateway.wsHost, auth: .token("mock-device-token-1"),
                                       identity: DeviceIdentity())
        _ = try await sync.listAgents()          // forces the handshake
        let policy = await sync.attachmentPolicy()

        XCTAssertEqual(policy.maxBytes, 2 * 1024 * 1024, "the gateway's ceiling, not ours")
        XCTAssertEqual(policy.maxImageBytes, 1024 * 1024)
        // And the budget honors it: a 3 MB PDF is now too large where the default allowed it.
        XCTAssertEqual(AttachmentBudget.plan(fileName: "spec.pdf", mimeType: "application/pdf",
                                             bytes: 3 * 1024 * 1024, isImage: false, policy: policy),
                       .tooLarge(max: 2 * 1024 * 1024))
    }

    /// Once P5 captures a real hello-ok, it must decode through the same envelope the app
    /// uses — not a parallel parser that could drift from production.
    func testCapturedHelloOkDecodesThroughTheAppsOwnEnvelope() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hello-ok.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("no live hello-ok captured yet — loop P5.4 writes it")
        }
        let env = try JSONDecoder().decode(InboundEnvelope.self, from: Data(contentsOf: fixture))
        guard let advertised = env.payload?.policy else { return }   // gateway sent no policy
        if let v = advertised.attachments?.maxBytes { XCTAssertGreaterThan(v, 0) }
        if let v = advertised.attachments?.maxImageBytes { XCTAssertGreaterThan(v, 0) }
    }
}
