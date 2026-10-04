import AppKit
import XCTest
@testable import MacHUDCore

/// Every word on the wheel is upright and fitted to a width, never clipped: a text wraps to a
/// second line, then shrinks, and only then is cut after a whole word.
@MainActor
final class RadialTextFitTests: XCTestCase {
    private func width(_ text: String, _ style: TextFit.Style, _ size: CGFloat) -> CGFloat {
        TextFit.width(text, font: style.font(size))
    }

    func testAShortTextKeepsOneLineAtItsFullSize() {
        let fit = TextFit.fit("Code", style: .name, width: 130)
        XCTAssertEqual(fit.lines, ["Code"])
        XCTAssertEqual(fit.size, TextFit.Style.name.preferred)
        XCTAssertFalse(fit.truncated)
    }

    /// Two lines at the full size win over one line at a smaller size.
    func testAFitWrapsBeforeItShrinks() {
        let style = TextFit.Style.name
        let text = "Morning research and writing"
        let room = width(text, style, style.preferred) - 6
        XCTAssertLessThan(width(text, style, style.floor), room, "one line would fit at a smaller size")
        let fit = TextFit.fit(text, style: style, width: room)
        XCTAssertEqual(fit.lines.count, 2)
        XCTAssertEqual(fit.lines.joined(separator: " "), text)
        XCTAssertEqual(fit.size, style.preferred)
        XCTAssertFalse(fit.truncated)
    }

    /// When two lines at the full size do not fit, the text shrinks on two lines.
    func testAFitShrinksWhenTwoLinesDoNotFitAtTheFullSize() {
        let style = TextFit.Style.name
        let text = "Quarterly planning"
        let room = width("Quarterly", style, style.preferred) - 4
        let fit = TextFit.fit(text, style: style, width: room)
        XCTAssertEqual(fit.lines, ["Quarterly", "planning"])
        XCTAssertLessThan(fit.size, style.preferred)
        XCTAssertGreaterThanOrEqual(fit.size, style.floor)
        XCTAssertFalse(fit.truncated)
    }

    /// When two lines at the floor are not enough, the last line ends in an ellipsis after a
    /// whole word.
    func testTruncationFallsOnAWordBoundary() throws {
        let style = TextFit.Style.name
        let text = "Quarterly planning with the whole design and research team"
        let fit = TextFit.fit(text, style: style, width: 80)
        XCTAssertTrue(fit.truncated)
        XCTAssertEqual(fit.size, style.floor)
        XCTAssertEqual(fit.lines.count, 2)
        let last = try XCTUnwrap(fit.lines.last)
        XCTAssertTrue(last.hasSuffix("…"), last)
        let shown = (fit.lines.dropLast() + [String(last.dropLast())]).joined(separator: " ")
        XCTAssertTrue(text.hasPrefix(shown), shown)
        XCTAssertTrue(text.dropFirst(shown.count).hasPrefix(" "), "cut between words: \(shown)")
        for line in fit.lines { XCTAssertLessThanOrEqual(width(line, style, fit.size), 80) }
    }

    func testAWordTooLongForItsLineLosesLettersNotTheEllipsis() {
        let style = TextFit.Style(weight: .semibold, preferred: 11, floor: 9, maxLines: 1)
        let fit = TextFit.fit("Supercalifragilistic", style: style, width: 40)
        XCTAssertTrue(fit.truncated)
        XCTAssertEqual(fit.lines.count, 1)
        XCTAssertTrue(fit.lines[0].hasPrefix("Super"), fit.lines[0])
        XCTAssertTrue(fit.lines[0].hasSuffix("…"))
        XCTAssertLessThanOrEqual(width(fit.lines[0], style, fit.size), 40)
    }

    /// A first word wider than the line is cut to the line, and the words after it are not
    /// lost to a line that cannot hold them.
    func testALongFirstWordIsCutToItsLine() throws {
        let style = TextFit.Style.name
        let fit = TextFit.fit("Supercalifragilisticexpialidocious research", style: style, width: 110)
        XCTAssertTrue(fit.truncated)
        let first = try XCTUnwrap(fit.lines.first)
        XCTAssertTrue(first.hasPrefix("Supercali"), first)
        for line in fit.lines { XCTAssertLessThanOrEqual(width(line, style, fit.size), 110, line) }
    }

    /// Whatever a fit returns lies inside the width it was given, at a size between the style's
    /// floor and its preferred size, on no more lines than the style allows.
    func testWhateverAFitReturnsLiesInsideItsWidth() {
        let url = "https://example.com/" + String(repeating: "a-very-long-path-segment/", count: 6)
        let texts = ["", " ", "A", "Code", "Morning research and writing", "Supercalifragilisticexpialidocious research",
                     url, "dev: \(url)", "Quarterly planning with the whole design and research team",
                     "Park Safari · " + String(repeating: "A rather long page title ", count: 8),
                     "two\nlines", "Z\u{0301}\u{0302}\u{0303}a\u{0300}\u{0300}lgo text", "日本語のとても長いロードアウト名前"]
        let styles: [TextFit.Style] = [.name, .label, .hint, TextFit.Style(weight: .regular, preferred: 12, floor: 9, maxLines: 1)]
        for style in styles {
            for room in [0, 8, 24, 40, 64, 96, 130, 200, 400] as [CGFloat] {
                for text in texts {
                    let fit = TextFit.fit(text, style: style, width: room)
                    let what = "'\(text)' in \(room) at \(style.preferred)"
                    XCTAssertGreaterThanOrEqual(fit.size, style.floor, what)
                    XCTAssertLessThanOrEqual(fit.size, style.preferred, what)
                    XCTAssertFalse(fit.lines.isEmpty, what)
                    XCTAssertLessThanOrEqual(fit.lines.count, style.maxLines, what)
                    for line in fit.lines {
                        XCTAssertLessThanOrEqual(TextFit.width(line, font: style.font(fit.size)), room + 0.01, "\(what): '\(line)'")
                        XCTAssertFalse(line.contains("\n"), what)
                    }
                    if !fit.truncated {
                        XCTAssertEqual(fit.lines.joined(separator: " "),
                                       text.split(whereSeparator: \.isWhitespace).joined(separator: " "), what)
                    }
                }
            }
        }
    }
}
