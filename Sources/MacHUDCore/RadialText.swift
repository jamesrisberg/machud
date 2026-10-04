import AppKit
import CoreText

/// Fits a short text into lines that each have a length budget: a name or a button label on
/// the loadout wheel, or the hint under it. First the point size shrinks, down to the style's
/// floor; then the text wraps at word boundaries, up to the style's line count, starting again
/// from the preferred size; only then is the last line truncated with an ellipsis, after a whole
/// word where one fits. Pure: it measures with CoreText (kerning kept) and draws nothing.
struct TextFit: Equatable {
    struct Style: Equatable {
        var weight: NSFont.Weight
        var preferred: CGFloat
        var floor: CGFloat
        var maxLines: Int

        func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: weight) }

        /// A wedge's name, on the band outside its last ring.
        static let name = Style(weight: .semibold, preferred: 13, floor: 10, maxLines: 2)
        /// A ring's button label.
        static let label = Style(weight: .semibold, preferred: 11, floor: 9, maxLines: 2)
        /// The line under the wheel.
        static let hint = Style(weight: .medium, preferred: 12, floor: 10, maxLines: 2)
    }

    /// Outermost (first) line first.
    var lines: [String]
    var size: CGFloat
    var truncated: Bool

    static let step: CGFloat = 0.5
    static let ellipsis = "…"

    static func width(_ text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// `budget(lineCount, size)`: the length each of `lineCount` lines may take at `size`, first
    /// line first, or nil when that many lines at that size do not fit (a band too shallow).
    static func fit(_ text: String, style: Style, budget: (Int, CGFloat) -> [CGFloat]?) -> TextFit {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return TextFit(lines: [text], size: style.preferred, truncated: false) }
        let sizes = Array(stride(from: style.preferred, through: style.floor, by: -step))
        for lines in 1...max(1, min(style.maxLines, words.count)) {
            for size in sizes {
                guard let budgets = budget(lines, size), budgets.count == lines else { continue }
                if let split = bestSplit(words, into: lines, font: style.font(size), budgets: budgets) {
                    return TextFit(lines: split, size: size, truncated: false)
                }
            }
        }
        return truncate(words, style: style, budget: budget)
    }

    /// The split of `words` into `count` lines that fit their budgets with the most room to spare
    /// on the tightest line; nil when none fits. Handles one and two lines.
    private static func bestSplit(_ words: [String], into count: Int, font: NSFont, budgets: [CGFloat]) -> [String]? {
        if count == 1 {
            let line = words.joined(separator: " ")
            return width(line, font: font) <= budgets[0] ? [line] : nil
        }
        var best: (lines: [String], tightest: CGFloat)?
        for k in 1..<words.count {
            let lines = [words[..<k].joined(separator: " "), words[k...].joined(separator: " ")]
            let ratios = zip(lines, budgets).map { width($0, font: font) / max($1, 1) }
            guard let tightest = ratios.max(), tightest <= 1 else { continue }
            if best == nil || tightest < best!.tightest { best = (lines, tightest) }
        }
        return best?.lines
    }

    /// At the floor, on as many lines as fit: whole words fill the lines in turn, and the last
    /// line ends in an ellipsis after the last word that fits (letters only when no word does).
    private static func truncate(_ words: [String], style: Style, budget: (Int, CGFloat) -> [CGFloat]?) -> TextFit {
        let font = style.font(style.floor)
        var count = max(1, min(style.maxLines, words.count))
        while count > 1, budget(count, style.floor) == nil { count -= 1 }
        let budgets = budget(count, style.floor) ?? [0]
        var rest = words[...]
        var lines: [String] = []
        for (i, room) in budgets.enumerated() where !rest.isEmpty {
            if i == budgets.count - 1 {
                lines.append(ending(Array(rest), font: font, room: room))
                break
            }
            var taken = 0
            while taken < rest.count,
                  width(rest.prefix(taken + 1).joined(separator: " "), font: font) <= room { taken += 1 }
            guard taken > 0 else {
                lines.append(ending(Array(rest), font: font, room: room))
                break
            }
            lines.append(rest.prefix(taken).joined(separator: " "))
            rest = rest.dropFirst(taken)
        }
        return TextFit(lines: lines, size: style.floor, truncated: true)
    }

    /// `words` cut to `room` with an ellipsis: after the most whole words that fit, else after
    /// the most letters of the first word, else nothing.
    private static func ending(_ words: [String], font: NSFont, room: CGFloat) -> String {
        let trailing = CharacterSet.punctuationCharacters.union(.whitespaces)
        for k in stride(from: words.count - 1, through: 1, by: -1) {
            var kept = words.prefix(k).joined(separator: " ")
            while let last = kept.unicodeScalars.last, trailing.contains(last) { kept.removeLast() }
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

/// A text fitted to a band of the wheel and laid along its arc: each line's baseline is a circle
/// around the wheel's centre, the text centred on its wedge's centre angle, every glyph standing
/// on the arc with its top pointing outward. At the bottom of the wheel that is upside-down, on
/// purpose: nothing is flipped to read.
struct ArcText: Equatable {
    var fit: TextFit
    /// Each line's baseline radius, outermost (first) line first.
    var baselines: [CGFloat]

    /// Fits `text` between the `inner` and `outer` radii, its lines centred in the band, each
    /// within `angle` radians at its lowest point (the descenders), less `inset` points at both ends.
    static func fit(_ text: String, style: TextFit.Style, inner: CGFloat, outer: CGFloat,
                    angle: Double, inset: CGFloat) -> ArcText {
        let fit = TextFit.fit(text, style: style) { count, size in
            baselines(count: count, font: style.font(size), inner: inner, outer: outer)?.map {
                CGFloat(angle) * ($0 + style.font(size).descender) - 2 * inset
            }
        }
        let font = style.font(fit.size)
        return ArcText(fit: fit, baselines: baselines(count: fit.lines.count, font: font, inner: inner, outer: outer)
                        ?? stack(count: fit.lines.count, font: font, middle: (inner + outer) / 2))
    }

    /// The baselines of `count` lines centred (on their capitals) between `inner` and `outer`,
    /// outermost first; nil when they do not fit between them.
    static func baselines(count: Int, font: NSFont, inner: CGFloat, outer: CGFloat) -> [CGFloat]? {
        let lines = stack(count: count, font: font, middle: (inner + outer) / 2)
        guard let top = lines.first, let bottom = lines.last,
              top + font.ascender <= outer + 0.001, bottom + font.descender >= inner - 0.001 else { return nil }
        return lines
    }

    private static func stack(count: Int, font: NSFont, middle: CGFloat) -> [CGFloat] {
        let pitch = font.ascender - font.descender
        return (0..<count).map { i in middle + (CGFloat(count - 1) / 2 - CGFloat(i)) * pitch - font.capHeight / 2 }
    }

    /// Where the glyph whose middle is `x` points into a line `lineWidth` long sits on a baseline
    /// of `radius` centred on `centerAngle` (clockwise from straight up), and how much it turns:
    /// its top points away from `center`.
    static func place(x: CGFloat, lineWidth: CGFloat, radius: CGFloat, centerAngle: Double,
                      center c: CGPoint) -> (point: CGPoint, rotation: CGFloat) {
        let a = centerAngle + Double((x - lineWidth / 2) / radius)
        return (CGPoint(x: c.x + radius * CGFloat(sin(a)), y: c.y + radius * CGFloat(cos(a))), -CGFloat(a))
    }

    /// Draws `line` along its baseline circle with `ctx`'s fill colour and shadow.
    static func draw(_ line: String, font: NSFont, radius: CGFloat, centerAngle: Double, center c: CGPoint,
                     in ctx: CGContext) {
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        guard let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] else { return }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let fallback: CTFont = font
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? fallback
            for i in 0..<count {
                let spot = place(x: positions[i].x + advances[i].width / 2, lineWidth: lineWidth, radius: radius,
                                 centerAngle: centerAngle, center: c)
                ctx.saveGState()
                ctx.translateBy(x: spot.point.x, y: spot.point.y)
                ctx.rotate(by: spot.rotation)
                ctx.textMatrix = .identity
                var glyph = glyphs[i]
                var origin = CGPoint(x: -advances[i].width / 2, y: 0)
                CTFontDrawGlyphs(runFont, &glyph, &origin, 1, ctx)
                ctx.restoreGState()
            }
        }
    }
}

extension RadialGeometry {
    /// A wedge's name fitted along the name band.
    func fitName(_ name: String) -> ArcText {
        let band = nameTextBand
        return ArcText.fit(name, style: .name, inner: band.inner, outer: band.outer,
                           angle: textAngle(at: .greatestFiniteMagnitude), inset: Self.textInset)
    }

    /// A ring's button label fitted along its label band.
    func fitLabel(_ label: String, ring: Ring, of index: Int) -> ArcText {
        let band = labelBand(ring, of: index)
        return ArcText.fit(label, style: .label, inner: band.inner, outer: band.outer,
                           angle: textAngle(at: .greatestFiniteMagnitude), inset: Self.textInset)
    }
}
