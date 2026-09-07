import SwiftUI
import XCTest
@testable import OpenClawMobile

/// Design-system pins (designs/2026-09-06-dev-suite-design.md §3.1/§3.3): the official
/// OpenClaw palette as sRGB golden vectors, the 6/10 pt radii, and source-grep gates that
/// keep every color/radius literal inside Theme.swift and shadows out of the app.
final class DesignSystemTests: XCTestCase {
    /// sRGB components rounded to 3 decimals so colors can be compared as arrays.
    private func rgb(_ color: Color) -> [Double] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [r, g, b].map { (Double($0) * 1000).rounded() / 1000 }
    }

    // MARK: - Tokens (P1.1)

    func testTokenValues() {
        let tolerance = 1.0 / 255
        let accent = rgb(Theme.accent)                    // #FF5C5C
        XCTAssertEqual(accent[0], 1.000, accuracy: tolerance)
        XCTAssertEqual(accent[1], 0.361, accuracy: tolerance)
        XCTAssertEqual(accent[2], 0.361, accuracy: tolerance)
        let brand = rgb(Theme.brand)                      // #D84A31
        XCTAssertEqual(brand[0], 0.847, accuracy: tolerance)
        XCTAssertEqual(brand[1], 0.290, accuracy: tolerance)
        XCTAssertEqual(brand[2], 0.192, accuracy: tolerance)
        let bg = rgb(Theme.bg)                            // #0E1015
        XCTAssertEqual(bg[0], 0.055, accuracy: tolerance)
        XCTAssertEqual(bg[1], 0.063, accuracy: tolerance)
        XCTAssertEqual(bg[2], 0.082, accuracy: tolerance)
        XCTAssertEqual(Theme.radius, 6)
        XCTAssertEqual(Theme.radiusCard, 10)
        XCTAssertEqual(Theme.border, 1)
    }

    // MARK: - Status mapping (P1.3)

    func testStatusColorsAndSymbols() {
        for status in AgentStatus.allCases {
            XCTAssertFalse(status.symbol.isEmpty, "\(status) needs an SF Symbol — status is never color alone")
            XCTAssertFalse(status.label.isEmpty)
        }
        XCTAssertEqual(rgb(AgentStatus.working.color), rgb(Theme.teal))
        XCTAssertEqual(rgb(AgentStatus.waiting.color), rgb(Theme.warn))
        XCTAssertEqual(rgb(AgentStatus.blocked.color), rgb(Theme.warn))
        XCTAssertEqual(rgb(AgentStatus.failed.color), rgb(Theme.danger))
        XCTAssertEqual(rgb(AgentStatus.done.color), rgb(Theme.textMuted))
        XCTAssertEqual(rgb(AgentStatus.idle.color), rgb(Theme.textMuted))
        // waiting and blocked share a color, so their icons must differ.
        XCTAssertNotEqual(AgentStatus.waiting.symbol, AgentStatus.blocked.symbol)
    }

    // MARK: - Source-grep gates (P1.2)

    private var sourcesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // OpenClawMobile/Tests
            .deletingLastPathComponent()               // OpenClawMobile
            .appendingPathComponent("Sources")
    }

    /// "relative/path.swift:line: text" for every line matching `pattern` in Sources/,
    /// skipping files whose path contains `excluding`.
    private func offenders(matching pattern: String, excluding: String? = nil) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let root = sourcesURL
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("Sources not found at \(root.path)"); return []
        }
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if let excluding, rel.contains(excluding) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(rel):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return hits
    }

    func testNoShadows() throws {
        XCTAssertEqual(try offenders(matching: #"\.shadow\("#), [], "elevation is 1 px borders, never shadows")
    }

    func testHexOnlyInTheme() throws {
        XCTAssertEqual(try offenders(matching: #"Color\(hex:"#, excluding: "DesignSystem/Theme.swift"), [],
                       "color literals live only in Theme.swift")
    }

    func testCornerRadiusLiteralOnlyInTheme() throws {
        XCTAssertEqual(try offenders(matching: #"cornerRadius[:(] *[0-9]"#, excluding: "DesignSystem/Theme.swift"), [],
                       "radii come from Theme.radius / Theme.radiusCard")
    }
}
