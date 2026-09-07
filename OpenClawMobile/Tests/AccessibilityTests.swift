import SwiftUI
import XCTest
@testable import OpenClawMobile

/// Accessibility floors (loop P4.3 and P4.5). Both are real measurements, not eyeballing:
/// WCAG contrast computed from the tokens, and text measured at the largest Dynamic Type size.
final class AccessibilityTests: XCTestCase {
    // MARK: - Contrast (P4.5)

    /// WCAG 2.1 relative luminance.
    private func luminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    private func ratio(_ fg: Color, on bg: Color) -> Double {
        let a = luminance(fg), b = luminance(bg)
        let (light, dark) = a > b ? (a, b) : (b, a)
        return (light + 0.05) / (dark + 0.05)
    }

    func testBodyAndCaptionTextMeetWCAGOnEverySurface() {
        let surfaces: [(String, Color)] = [("bg", Theme.bg), ("card", Theme.card), ("elevated", Theme.elevated)]
        let texts: [(String, Color)] = [("text", Theme.text), ("textBody", Theme.textBody), ("textMuted", Theme.textMuted)]
        for (surfaceName, surface) in surfaces {
            for (textName, text) in texts {
                let r = ratio(text, on: surface)
                XCTAssertGreaterThanOrEqual(r, 4.5, String(format: "%@ on %@ is %.2f:1", textName, surfaceName, r))
            }
        }
    }

    func testStatusColorsAreReadableOnTheirSurfaces() {
        // Status is never colour alone (each has a symbol), but the text still has to be legible.
        for (name, color) in [("teal", Theme.teal), ("warn", Theme.warn), ("danger", Theme.danger),
                              ("accent", Theme.accent), ("ok", Theme.ok)] {
            let r = ratio(color, on: Theme.card)
            XCTAssertGreaterThanOrEqual(r, 3.0, String(format: "%@ on card is %.2f:1", name, r))
        }
    }

    // MARK: - Dynamic Type (P4.3)

    /// Width of `text` rendered at the given content size, in points.
    private func width(_ text: String, style: UIFont.TextStyle, size: UIContentSizeCategory) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: size)
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The real clipping risk at accessibility sizes is a single word too wide to wrap.
    /// Multi-word labels wrap (PrimaryButton and StatusBadge allow two lines), so measuring
    /// the whole string would test a constraint the UI does not actually have.
    private func longestWord(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            .max(by: { $0.count < $1.count }) ?? text
    }

    func testNoLabelHasAnUnbreakableWordThatClipsAtXXXL() {
        let phoneWidth: CGFloat = 402
        let chipBudget = phoneWidth / 2

        for column in BoardColumn.allCases {
            let word = longestWord(column.title)
            let w = width(word, style: .caption1, size: .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(w, chipBudget, "Board chip word '\(word)' is \(Int(w))pt at XXXL")
        }
        for status in AgentStatus.allCases {
            let word = longestWord(status.label)
            let w = width(word, style: .caption1, size: .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(w, chipBudget, "Status word '\(word)' is \(Int(w))pt at XXXL")
        }
        for tab in ["Agents", "Board", "Settings"] {
            // iOS truncates tab titles itself; assert only that one word is not absurd.
            let w = width(tab, style: .caption2, size: .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(w, phoneWidth / 2, "Tab '\(tab)' is \(Int(w))pt at XXXL")
        }
    }

    func testPrimaryButtonTitlesWrapWithoutClipping() {
        let usable: CGFloat = 402 - 48   // screen minus the 24pt padding each side
        for title in [FirstRunGate.continueTitle, "Scan Setup Code", "Pair Device", "Create", "Start"] {
            let word = longestWord(title)
            let w = width(word, style: .body, size: .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(w, usable, "Button word '\(word)' is \(Int(w))pt at XXXL and cannot wrap")
        }
    }

    /// The components above only survive long titles because they are allowed to wrap.
    func testWrappingComponentsDeclareTwoLines() throws {
        let theme = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DesignSystem/Theme.swift"), encoding: .utf8)
        XCTAssertEqual(theme.components(separatedBy: "lineLimit(2)").count - 1, 2,
                       "PrimaryButton and StatusBadge must each allow a second line")
    }

    func testPairingRecoveryTextWrapsRatherThanOverflowing() {
        // Recovery copy is long by design; assert it is multi-line prose, not a single
        // unbreakable run that would clip.
        for reason in [PairingFlow.FailureReason.expiredCode, .badHost, .unreachable, .timeout, .cameraDenied] {
            let longestWord = reason.recovery.split(separator: " ").map(String.init)
                .max(by: { $0.count < $1.count }) ?? ""
            let w = width(longestWord, style: .body, size: .accessibilityExtraExtraExtraLarge)
            XCTAssertLessThan(w, 402 - 48, "'\(longestWord)' cannot wrap and will clip at XXXL")
        }
    }
}
