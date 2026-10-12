import AppKit
import CoreText

/// Fits a short text into upright lines no wider than a width: a name or a button label on the
/// loadout wheel, or the hint under it. First the text wraps at word boundaries at its preferred
/// size, up to the style's line count; then it shrinks, down to the style's floor; only then is
/// the last line cut with an ellipsis, after a whole word where one fits (letters only when not
/// even the first word does). Every line it returns is at most the width it was given, whatever
/// the text. Pure: it measures with CoreText (kerning kept) and draws nothing.
struct TextFit: Equatable {
    struct Style: Equatable {
        var weight: NSFont.Weight
        var preferred: CGFloat
        var floor: CGFloat
        var maxLines: Int

        func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: weight) }

        /// The same style with every size multiplied by `factor` (a wheel drawn smaller to fit
        /// its screen).
        func scaled(_ factor: CGFloat) -> Style {
            Style(weight: weight, preferred: preferred * factor, floor: floor * factor, maxLines: maxLines)
        }

        /// A petal's name: a top petal or a loadout.
        static let name = Style(weight: .semibold, preferred: 14, floor: 11, maxLines: 2)
        /// An action's label.
        static let label = Style(weight: .semibold, preferred: 12, floor: 10, maxLines: 1)
        /// The line under the wheel.
        static let hint = Style(weight: .medium, preferred: 12.5, floor: 10.5, maxLines: 2)
        /// A top petal's digit, by the dead zone.
        static let digit = Style(weight: .bold, preferred: 9, floor: 9, maxLines: 1)
        /// "Esc" and "Cancel" in the centre.
        static let centre = Style(weight: .semibold, preferred: 12, floor: 12, maxLines: 1)
    }

    /// Top line first.
    var lines: [String]
    var size: CGFloat
    var truncated: Bool

    static let step: CGFloat = 0.5
    static let ellipsis = "…"

    static func width(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func fit(_ text: String, style: Style, width room: CGFloat) -> TextFit {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return TextFit(lines: [""], size: style.preferred, truncated: false) }
        let most = max(1, min(style.maxLines, words.count))
        var sizes = Array(stride(from: style.preferred, to: style.floor, by: -step))
        sizes.append(style.floor)
        // Wrapping comes before shrinking: every line count at the preferred size first.
        for lines in 1...most {
            if let split = bestSplit(words, into: lines, font: style.font(style.preferred), width: room) {
                return TextFit(lines: split, size: style.preferred, truncated: false)
            }
        }
        for size in sizes.dropFirst() {
            for lines in 1...most {
                if let split = bestSplit(words, into: lines, font: style.font(size), width: room) {
                    return TextFit(lines: split, size: size, truncated: false)
                }
            }
        }
        return truncate(words, style: style, width: room)
    }

    /// The split of `words` into `count` lines, each no wider than `room`, whose widest line is
    /// narrowest; nil when none fits.
    private static func bestSplit(_ words: [String], into count: Int, font: NSFont, width room: CGFloat) -> [String]? {
        if count == 1 {
            let line = words.joined(separator: " ")
            return width(line, font: font) <= room ? [line] : nil
        }
        guard words.count >= count else { return nil }
        var best: (lines: [String], widest: CGFloat)?
        for k in 1...(words.count - count + 1) {
            let first = words[..<k].joined(separator: " ")
            let w = width(first, font: font)
            guard w <= room, let rest = bestSplit(Array(words[k...]), into: count - 1, font: font, width: room) else { continue }
            let widest = max(w, rest.map { width($0, font: font) }.max() ?? 0)
            if best == nil || widest < best!.widest { best = ([first] + rest, widest) }
        }
        return best?.lines
    }

    /// At the floor, on as many lines as the style allows: whole words fill the lines in turn,
    /// and the last line ends in an ellipsis after the last word that fits. A word too wide for
    /// a line of its own is cut there, letters first, and ends the text.
    private static func truncate(_ words: [String], style: Style, width room: CGFloat) -> TextFit {
        let font = style.font(style.floor)
        let count = max(1, min(style.maxLines, words.count))
        var rest = words[...]
        var lines: [String] = []
        var cut = false
        while !rest.isEmpty, lines.count < count {
            if lines.count == count - 1 {
                let all = rest.joined(separator: " ")
                cut = width(all, font: font) > room
                lines.append(cut ? ending(Array(rest), font: font, room: room) : all)
                break
            }
            var taken = 0
            while taken < rest.count, width(rest.prefix(taken + 1).joined(separator: " "), font: font) <= room { taken += 1 }
            guard taken > 0 else {
                cut = true
                lines.append(ending(Array(rest), font: font, room: room))
                break
            }
            lines.append(rest.prefix(taken).joined(separator: " "))
            rest = rest.dropFirst(taken)
        }
        return TextFit(lines: lines.isEmpty ? [""] : lines, size: style.floor, truncated: cut)
    }

    /// `words` cut to `room` with an ellipsis: after the most whole words that fit, else after
    /// the most letters of the first word, else the ellipsis alone, else nothing.
    private static func ending(_ words: [String], font: NSFont, room: CGFloat) -> String {
        let trailing = CharacterSet.punctuationCharacters.union(.whitespaces)
        for k in stride(from: words.count - 1, through: 1, by: -1) {
            var kept = words.prefix(k).joined(separator: " ")
            while let last = kept.unicodeScalars.last, trailing.contains(last) { kept.removeLast() }
            guard !kept.isEmpty else { continue }
            let line = kept + ellipsis
            if width(line, font: font) <= room { return line }
        }
        let first = Array(words.first ?? "")
        for n in stride(from: first.count - 1, through: 1, by: -1) {
            let line = String(first.prefix(n)) + ellipsis
            if width(line, font: font) <= room { return line }
        }
        return width(ellipsis, font: font) <= room ? ellipsis : ""
    }
}

/// A fitted text ready to draw upright: one CoreText line per line, drawn whole (so kerning and
/// combining marks keep their places) in the context's fill colour, with its shadow.
struct PreparedText {
    struct Line {
        var line: CTLine
        var width: CGFloat
    }

    let lines: [Line]
    let font: NSFont

    init(_ fit: TextFit, style: TextFit.Style) {
        font = style.font(fit.size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        lines = fit.lines.map { text in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            return Line(line: line, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { font.ascender - font.descender }
    var lineHeight: CGFloat { Self.lineHeight(font) }
    var height: CGFloat { CGFloat(lines.count) * lineHeight }

    /// Draws the lines from the top of `frame` down, each placed across the frame by `align`
    /// (0 at its left edge, 1 at its right), with `ctx`'s fill colour and shadow.
    func draw(in frame: CGRect, align: CGFloat, in ctx: CGContext) {
        ctx.textMatrix = .identity
        for (i, line) in lines.enumerated() {
            let x = frame.minX + (frame.width - line.width) * align
            let baseline = frame.maxY - font.ascender - CGFloat(i) * lineHeight
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line.line, ctx)
        }
    }
}
