import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import OpenClawMobile

/// Composer intake (design §4.2): what happens between a pick and the tray. Runs against the
/// demo seam — nothing here needs a gateway.
@MainActor
final class AttachmentIntakeTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(thread: .main(for: AgentSummary(id: "main")), sync: DemoSyncSource(), settings: SettingsStore())
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testSmallSourceFileInlinesAsFenceInDraft() throws {
        let vm = makeViewModel()
        let url = try write("notes.swift", Data("let x = 1".utf8))
        vm.addFiles([url])
        XCTAssertEqual(vm.draft, "`notes.swift`:\n```swift\nlet x = 1\n```")
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertNil(vm.attachmentHint)
    }

    func testMarkdownContainingFencesAttachesInsteadOfInlining() throws {
        let vm = makeViewModel()
        let url = try write("README.md", Data("# Title\n\n```sh\nls\n```\n".utf8))
        vm.addFiles([url])
        XCTAssertEqual(vm.draft, "", "a file with its own fences would break the wrapper")
        XCTAssertEqual(vm.pendingAttachments.map(\.kind), [.file])
        XCTAssertEqual(vm.pendingAttachments.first?.fileName, "README.md")
    }

    func testOversizedFileIsRejectedBySizeBeforeReading() throws {
        let vm = makeViewModel()
        let url = try write("huge.bin", Data(count: 21 * 1024 * 1024))
        vm.addFiles([url])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.attachmentHint, "huge.bin is over 20 MB.")
    }

    func testUnreadableURLSetsHint() {
        let vm = makeViewModel()
        vm.addFiles([tmp.appendingPathComponent("missing.txt")])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.attachmentHint, "Couldn't read missing.txt.")
    }

    func testGarbageImageDataSetsHint() {
        let vm = makeViewModel()
        vm.addImage(data: Data([0x01, 0x02, 0x03]), fileName: "broken.heic")
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.attachmentHint, "Couldn't read that image.")
    }

    func testRealImageIsResizedAndReencodedAsJPEG() throws {
        let vm = makeViewModel()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 300), format: format).pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 300))
        }
        vm.addImage(data: png, fileName: "wide.png")
        let attachment = try XCTUnwrap(vm.pendingAttachments.first)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.fileName, "wide.jpg")
        XCTAssertEqual(attachment.width, 2048)
        XCTAssertEqual(attachment.height, 205)
        XCTAssertLessThan(attachment.data.count, AttachmentPolicy.default.maxImageBytes)
        XCTAssertNil(vm.attachmentHint)
    }

    func testRemoveAttachmentDropsOnlyThatOne() {
        let vm = makeViewModel()
        let a = Attachment(kind: .file, fileName: "a.pdf", mimeType: "application/pdf", data: Data([1]))
        let b = Attachment(kind: .file, fileName: "b.pdf", mimeType: "application/pdf", data: Data([2]))
        vm.pendingAttachments = [a, b]
        vm.removeAttachment(a)
        XCTAssertEqual(vm.pendingAttachments.map(\.fileName), ["b.pdf"])
    }
}
