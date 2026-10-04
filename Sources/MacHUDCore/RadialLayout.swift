import AppKit

/// The loadout wheel's words, all upright, and the rings' radii they need. Pure: it measures
/// with CoreText and draws nothing. Coordinates are the wheel's: its centre at the origin, y up.
///
/// - Buttons. Each ring's word sits in the middle of its region (the ring's middle radius, on
///   the wedge's centre line), so the word under the pointer is the one that lights. Along a
///   horizontal spoke a wedge's words sit side by side, so each ring is as deep as its widest
///   label grown (`RadialWheelView.grow`) plus `buttonGap`: a grown word never touches the next.
///   With many wedges every ring moves out (the dead zone stays) until no grown word touches a
///   word of another wedge and every word, grown by at least `minimumGrow`, lies inside its own
///   region. Each word then grows under the pointer as far as its region allows, up to
///   `RadialWheelView.grow` (`Word.grow`), so the word under the pointer is the one that lights
///   wherever on it the pointer is.
/// - Names. Each wedge's name is anchored at `RadialGeometry.nameRadius`, past the last ring,
///   and grows away from the centre: on the right half it starts at its anchor, on the left half
///   it ends there, at the top and the bottom it is centred on it, blending between; above the
///   centre it stands on its anchor, below it hangs from it. A name is fitted to `nameWidth`
///   (wrap to two lines, then shrink, then cut after a whole word); a name that would still
///   touch another word gets a narrower width. A wheel of up to `iconLimit` wedges shows up to
///   `maxIcons` of a wedge's icons in a row under its name.
/// - Digits 1 to 9, small, just inside the dead zone's edge; "Esc" / "Cancel" in the centre.
/// - The hint: under every other word, up to two lines no wider than `hintWidth`.
///
/// `scale` draws the whole wheel smaller (radii, words and gaps alike), for a screen it would
/// not otherwise fit (`fitting(_:in:)`).
struct RadialLayout: Equatable {
    struct Word: Equatable {
        enum Role: Hashable {
            case name(Int)
            case button(Int, RadialGeometry.Ring)
            case digit(Int)
            case centre

            var isName: Bool { if case .name = self { return true } else { return false } }
        }

        var role: Role
        var fit: TextFit
        var style: TextFit.Style
        /// The word's box, icons included.
        var frame: CGRect
        /// Where each line sits across the frame: 0 at its left edge, 1 at its right.
        var align: CGFloat
        /// Icons in a row under a name's lines.
        var icons: Int
        /// How many times its size a button grows under the pointer, inside its region; 1 for
        /// every other word.
        var grow: CGFloat = 1

        var font: NSFont { style.font(fit.size) }
        var lineHeight: CGFloat { PreparedText.lineHeight(font) }
        var textHeight: CGFloat { CGFloat(fit.lines.count) * lineHeight }
    }

    // Full-size metrics, in points.
    static let deadZone: CGFloat = 44
    static let buttonGap: CGFloat = 6
    static let minRingDepth: CGFloat = 36
    static let nameGap: CGFloat = 10
    static let nameWidth: CGFloat = 136
    static let narrowestName: CGFloat = 40
    static let iconSize: CGFloat = 15
    static let iconSpacing: CGFloat = 4
    static let iconGap: CGFloat = 3
    static let hintWidth: CGFloat = 380
    static let hintGap: CGFloat = 12
    static let digitInset: CGFloat = 10
    /// The least room between two words.
    static let wordGap: CGFloat = 4
    static let iconLimit = 8
    /// The least a button grows under the pointer: the rings move out until every button can
    /// grow this much inside its region.
    static let minimumGrow: CGFloat = 1.15
    static let maxIcons = 5

    let geometry: RadialGeometry
    let scale: CGFloat
    let words: [Word]
    let hintStyle: TextFit.Style
    /// Where the hint's lines go: centred under the wheel, top line at its top.
    let hintZone: CGRect
    /// Every word and the hint's zone.
    let bounds: CGRect

    func word(_ role: Word.Role) -> Word? { words.first { $0.role == role } }

    /// The icons drawn by wedge `index`'s name.
    func icons(of index: Int) -> Int { word(.name(index))?.icons ?? 0 }

    func fitHint(_ text: String) -> TextFit { TextFit.fit(text, style: hintStyle, width: hintZone.width) }

    func hintLineHeight(_ fit: TextFit) -> CGFloat { PreparedText.lineHeight(hintStyle.font(fit.size)) }

    init(wedges: [RadialMenu.Wedge], scale: CGFloat = 1) {
        let s = max(0.25, min(1, scale))
        self.scale = s
        let count = wedges.count
        let ringCounts = wedges.map { RadialMenu.ringCount(for: $0.kind) }
        let labelStyle = TextFit.Style.label.scaled(s)
        let labelFont = labelStyle.font(labelStyle.preferred)
        let gap = Self.buttonGap * s
        let grow = RadialWheelView.grow

        // Each ring as deep as its widest label grown, along a horizontal spoke; a wedge's last
        // ring runs on through the rings after it, which between them hold its label.
        var depth = [CGFloat](repeating: Self.minRingDepth * s, count: RadialGeometry.Ring.allCases.count)
        var through: [(from: Int, width: CGFloat)] = []
        for (i, wedge) in wedges.enumerated() {
            for ring in RadialGeometry.Ring.allCases.prefix(ringCounts[i]) {
                let w = TextFit.width(RadialMenu.ringLabel(ring, for: wedge.kind), font: labelFont) * grow + gap
                if ring.position == ringCounts[i] - 1 && ring.position < depth.count - 1 {
                    through.append((ring.position, w))
                } else {
                    depth[ring.position] = max(depth[ring.position], w)
                }
            }
        }
        for last in through {
            let have = depth[last.from...].reduce(0, +)
            if have < last.width { depth[depth.count - 1] += last.width - have }
        }

        // Out until no grown button touches another and each fits its region grown at least
        // `minimumGrow`.
        let dead = Self.deadZone * s
        func rings(_ extra: CGFloat) -> RadialGeometry {
            let inner = dead + depth[0] + extra
            return RadialGeometry(count: count, ringCounts: ringCounts, deadZone: dead, innerEdge: inner,
                                  middleEdge: inner + depth[1], outerEdge: inner + depth[1] + depth[2],
                                  nameRadius: inner + depth[1] + depth[2] + Self.nameGap * s)
        }
        // Each label fitted once: moving the rings out only gives it more room.
        let labels = Self.fitLabels(wedges, geometry: rings(0), style: labelStyle, room: { ($0 - gap) / grow + 0.01 })
        var geometry = rings(0)
        var buttons: [Word] = []
        var extra: CGFloat = 0
        for _ in 0..<400 {
            geometry = rings(extra)
            buttons = Self.buttons(labels, geometry: geometry, style: labelStyle)
            let inside = buttons.allSatisfy {
                Self.inside(Self.grown($0.frame, by: Self.minimumGrow), region: $0.role, geometry: geometry, margin: s)
            }
            if inside && !Self.anyOverlap(buttons, grown: grow, gap: Self.wordGap * s) { break }
            extra += 2 * s
        }
        for k in buttons.indices { buttons[k].grow = Self.largestGrowth(buttons[k], upTo: grow, geometry: geometry, margin: s) }

        let small = (0..<min(count, 9)).map { Self.digit($0, geometry: geometry, scale: s) } + [Self.centre(scale: s)]

        // Names, narrowed where they would touch another word.
        let nameStyle = TextFit.Style.name.scaled(s)
        let icons = count <= Self.iconLimit
        var widths = [CGFloat](repeating: Self.nameWidth * s, count: count)
        var names: [Word] = []
        for _ in 0..<40 {
            names = wedges.indices.map { i in
                Self.name(wedges[i], index: i, width: widths[i], icons: icons, geometry: geometry, style: nameStyle, scale: s)
            }
            let others = buttons.map { Self.grown($0.frame, by: $0.grow) } + small.map(\.frame)
            var crowded = Set<Int>()
            for (a, name) in names.enumerated() {
                if others.contains(where: { $0.insetBy(dx: -Self.wordGap * s, dy: -Self.wordGap * s).intersects(name.frame) }) {
                    crowded.insert(a)
                }
                for b in names.indices where b > a && Self.touch(name, names[b], gap: Self.wordGap * s) {
                    crowded.formUnion([a, b])
                }
            }
            let narrowing = crowded.filter { widths[$0] > Self.narrowestName * s }
            if narrowing.isEmpty { break }
            for i in narrowing { widths[i] = max(Self.narrowestName * s, widths[i] - 8 * s) }
        }

        let words = buttons + names + small
        hintStyle = TextFit.Style.hint.scaled(s)
        let hintHeight = 2 * PreparedText.lineHeight(hintStyle.font(hintStyle.preferred))
        let lowest = words.map(\.frame.minY).min() ?? 0
        let hintWidth = Self.hintWidth * s
        hintZone = CGRect(x: -hintWidth / 2, y: lowest - Self.hintGap * s - hintHeight, width: hintWidth, height: hintHeight)
        self.geometry = geometry
        self.words = words
        bounds = words.reduce(hintZone) { $0.union($1.frame) }
    }

    /// The layout of `wedges` at full size, or smaller where that would not fit in `room`.
    static func fitting(_ wedges: [RadialMenu.Wedge], in room: CGSize) -> RadialLayout {
        var layout = RadialLayout(wedges: wedges)
        var scale: CGFloat = 1
        for _ in 0..<12 {
            let fits = layout.bounds.width <= room.width && layout.bounds.height <= room.height
            if fits || scale <= 0.25 { break }
            scale = min(scale * 0.97, scale * min(room.width / layout.bounds.width, room.height / layout.bounds.height))
            layout = RadialLayout(wedges: wedges, scale: scale)
        }
        return layout
    }

    // MARK: Words

    private static func box(_ fit: TextFit, style: TextFit.Style, centredAt p: CGPoint) -> CGRect {
        let font = style.font(fit.size)
        let width = fit.lines.map { TextFit.width($0, font: font) }.max() ?? 0
        let height = CGFloat(fit.lines.count) * PreparedText.lineHeight(font)
        return CGRect(x: p.x - width / 2, y: p.y - height / 2, width: width, height: height)
    }

    private static func point(_ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
    }

    /// Each wedge's buttons; `room` is the width a label may take in a band of the given depth.
    /// Each wedge's ring labels fitted to `room` for their band's depth in `g`, with the size
    /// of their box.
    private static func fitLabels(_ wedges: [RadialMenu.Wedge], geometry g: RadialGeometry, style: TextFit.Style,
                                  room: (CGFloat) -> CGFloat) -> [(role: Word.Role, fit: TextFit, size: CGSize)] {
        wedges.indices.flatMap { i in
            g.rings(of: i).map { ring -> (role: Word.Role, fit: TextFit, size: CGSize) in
                let band = g.band(ring, of: i)
                let fit = TextFit.fit(RadialMenu.ringLabel(ring, for: wedges[i].kind), style: style, width: room(band.r1 - band.r0))
                return (.button(i, ring), fit, box(fit, style: style, centredAt: .zero).size)
            }
        }
    }

    /// The fitted labels as buttons, each in the middle of its region in `g`.
    private static func buttons(_ labels: [(role: Word.Role, fit: TextFit, size: CGSize)], geometry g: RadialGeometry,
                                style: TextFit.Style) -> [Word] {
        labels.compactMap { label -> Word? in
            guard case .button(let i, let ring) = label.role else { return nil }
            let band = g.band(ring, of: i)
            let p = point((band.r0 + band.r1) / 2, g.centerAngle(of: i))
            let frame = CGRect(x: p.x - label.size.width / 2, y: p.y - label.size.height / 2, width: label.size.width, height: label.size.height)
            return Word(role: label.role, fit: label.fit, style: style, frame: frame, align: 0.5, icons: 0)
        }
    }

    private static func digit(_ index: Int, geometry g: RadialGeometry, scale s: CGFloat) -> Word {
        let style = TextFit.Style.digit.scaled(s)
        let fit = TextFit(lines: ["\(index + 1)"], size: style.preferred, truncated: false)
        return Word(role: .digit(index), fit: fit, style: style,
                    frame: box(fit, style: style, centredAt: point(g.deadZone - digitInset * s, g.centerAngle(of: index))),
                    align: 0.5, icons: 0)
    }

    /// The centre's word, as wide as the wider of "Esc" and "Cancel".
    private static func centre(scale s: CGFloat) -> Word {
        let style = TextFit.Style.centre.scaled(s)
        let fit = TextFit(lines: ["Cancel"], size: style.preferred, truncated: false)
        return Word(role: .centre, fit: fit, style: style, frame: box(fit, style: style, centredAt: .zero), align: 0.5, icons: 0)
    }

    /// 0 for `x` at or below `-0.5`, 1 at or above `0.5`, smoothly between.
    private static func blend(_ x: Double) -> CGFloat {
        let t = (min(1, max(-1, x / 0.5)) + 1) / 2
        return CGFloat(t * t * (3 - 2 * t))
    }

    private static func name(_ wedge: RadialMenu.Wedge, index i: Int, width: CGFloat, icons showsIcons: Bool,
                             geometry g: RadialGeometry, style: TextFit.Style, scale s: CGFloat) -> Word {
        let fit = TextFit.fit(wedge.name, style: style, width: width)
        let font = style.font(fit.size)
        let icons = showsIcons ? min(wedge.icons.count, maxIcons) : 0
        let row = icons > 0 ? CGFloat(icons) * iconSize * s + CGFloat(icons - 1) * iconSpacing * s : 0
        let w = max(fit.lines.map { TextFit.width($0, font: font) }.max() ?? 0, row)
        let h = CGFloat(fit.lines.count) * PreparedText.lineHeight(font) + (icons > 0 ? (iconGap + iconSize) * s : 0)
        let a = g.centerAngle(of: i)
        let anchor = point(g.nameRadius, a)
        let align = 1 - blend(sin(a))
        let lift = 1 - blend(cos(a))
        return Word(role: .name(i), fit: fit, style: style,
                    frame: CGRect(x: anchor.x - align * w, y: anchor.y - lift * h, width: w, height: h),
                    align: align, icons: icons)
    }

    private static func touch(_ a: Word, _ b: Word, gap: CGFloat) -> Bool {
        a.frame.insetBy(dx: -gap / 2, dy: -gap / 2).intersects(b.frame.insetBy(dx: -gap / 2, dy: -gap / 2))
    }

    static func grown(_ frame: CGRect, by factor: CGFloat) -> CGRect {
        frame.insetBy(dx: -frame.width * (factor - 1) / 2, dy: -frame.height * (factor - 1) / 2)
    }

    /// The most `word` can grow, up to `limit`, and lie inside its region (`minimumGrow` at
    /// least, where the rings made room for that).
    private static func largestGrowth(_ word: Word, upTo limit: CGFloat, geometry g: RadialGeometry, margin: CGFloat) -> CGFloat {
        func fits(_ factor: CGFloat) -> Bool { inside(grown(word.frame, by: factor), region: word.role, geometry: g, margin: margin) }
        if fits(limit) { return limit }
        var (low, high) = (CGFloat(1), limit)
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// Whether `frame` lies inside the region of the button `role` names (its wedge's angle and
    /// its ring's radii; a wedge's last ring has no outer edge), `margin` points clear of its edges.
    static func inside(_ frame: CGRect, region role: Word.Role, geometry g: RadialGeometry, margin: CGFloat = 1) -> Bool {
        guard case .button(let i, let ring) = role else { return true }
        let band = g.band(ring, of: i)
        let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                       CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
        let nearest = hypot(max(frame.minX, 0, -frame.maxX), max(frame.minY, 0, -frame.maxY))
        guard nearest >= band.r0 + margin else { return false }
        if ring != g.lastRing(of: i), corners.contains(where: { RadialGeometry.radius(of: $0) > band.r1 - margin }) { return false }
        // A wedge narrower than a half turn is convex, so its corners decide.
        guard g.count > 1 else { return true }
        let half = g.wedgeAngle / 2
        return corners.allSatisfy { corner in
            var off = RadialGeometry.angle(of: corner) - g.centerAngle(of: i)
            off = off.truncatingRemainder(dividingBy: RadialGeometry.fullTurn)
            if off > .pi { off -= RadialGeometry.fullTurn }
            if off < -.pi { off += RadialGeometry.fullTurn }
            return abs(off) <= half - Double(margin / max(1, RadialGeometry.radius(of: corner)))
        }
    }

    /// Whether any of `words`, grown by `factor`, comes within `gap` of another at rest.
    private static func anyOverlap(_ words: [Word], grown factor: CGFloat, gap: CGFloat) -> Bool {
        for (a, first) in words.enumerated() {
            let big = grown(first.frame, by: factor).insetBy(dx: -gap, dy: -gap)
            for (b, second) in words.enumerated() where a != b && big.intersects(second.frame) { return true }
        }
        return false
    }
}

// MARK: - The field

/// The one soft region the wheel's words sit on, fading to nothing with no edge, as two
/// profiles over the same shape. Pure functions from the layout to an alpha in 0...1:
/// - `blur`: what the backdrop's blur shows through (`blurImage`). It is full wherever a word can
///   be, so no sharp desktop shows through there (an alpha is a cross-fade between the blurred
///   desktop and the sharp one), and fades only outside that.
/// - `tint`: the profile of the tint the wheel draws (`tintImage`): the same, a little weaker
///   toward the rim (`rim`), so the middle is darkest. Its strength is the tint view's darkness.
/// The snapshots show the blurred desktop through `blur` and the tint through `tint`.
///
/// The shape is a disc a little past the names' anchors united with a rounded box around each
/// place a word can be that reaches outside it (a name with its icons, a button grown under the
/// pointer, the hint's two-line zone), joined smoothly, full inside and fading over `fade`
/// outside. With Reduce transparency on it is a plain soft disc around every word.
struct RadialField {
    /// What the field is made from: two layouts with the same shape have the same field.
    struct Shape: Equatable {
        var disc: CGFloat
        var boxes: [CGRect]
        var reach: CGFloat
        var fade: CGFloat
        var pad: CGFloat
        var smoothing: CGFloat
        var reduced: Bool

        init(layout: RadialLayout, reduced: Bool) {
            let s = layout.scale
            pad = RadialField.pad * s
            fade = RadialField.fade * s
            smoothing = RadialField.smoothing * s
            let frames = RadialField.places(layout)
            let farthest = { (r: CGRect) in hypot(max(abs(r.minX), abs(r.maxX)), max(abs(r.minY), abs(r.maxY))) }
            reach = max(1, frames.map(farthest).max() ?? 1)
            disc = reduced ? reach + pad : layout.geometry.nameRadius + RadialField.discReach * s
            let (disc, pad) = (disc, pad)
            boxes = reduced ? [] : frames.filter { farthest($0) + pad > disc }
            self.reduced = reduced
        }

        /// Full inside the shape, falling smoothly to 0 over `fade` outside it.
        func blur(at p: CGPoint) -> CGFloat { profiles(at: p).blur }

        /// `blur`, weaker by up to `rim` toward the farthest word.
        func tint(at p: CGPoint) -> CGFloat { profiles(at: p).tint }

        /// Both profiles at `p`, the shape measured once.
        func profiles(at p: CGPoint) -> (blur: CGFloat, tint: CGFloat) {
            let r = hypot(p.x, p.y)
            var d = r - disc
            for box in boxes { d = RadialField.smoothMin(d, RadialField.distance(p, to: box) - pad, smoothing) }
            guard d < fade else { return (0, 0) }
            let t = max(0, d / fade)
            let blur = 1 - t * t * t * (t * (t * 6 - 15) + 10)
            let u = min(1, r / reach)
            return (blur, blur * (1 - RadialField.rim * u * u * (3 - 2 * u)))
        }
    }

    /// The darkness of the wheel's tint over the backdrop where its profile is full: black at
    /// this alpha. Where a word sits (the profile at least `readable`) a white word on a white
    /// desktop reads at better than 4.5 to 1.
    static let darkness: CGFloat = 0.7
    /// The least strength of the tint's profile under any word.
    static let readable: CGFloat = 0.84
    /// How much weaker the tint's profile is at the farthest word than in the middle.
    static let rim: CGFloat = 0.14
    /// How far past each word's box the blur stays full: a little past a lit word's glow
    /// (`RadialWheelView.glowReach`).
    nonisolated static let pad: CGFloat = RadialWheelView.glowReach + 12
    static let fade: CGFloat = 72
    static let smoothing: CGFloat = 120
    /// How far past the names' anchors the field's disc reaches.
    static let discReach: CGFloat = 24
    /// Points per pixel of the blur's and the tint's images: the field is smooth enough to be
    /// stretched.
    static let step: CGFloat = 4

    /// Every place a word can be: each word's box (a button's grown under the pointer, a name's
    /// with its icons, the digits and the centre) and the hint's two-line zone.
    static func places(_ layout: RadialLayout) -> [CGRect] {
        layout.words.map { word in
            if case .button = word.role { return RadialLayout.grown(word.frame, by: word.grow) }
            return word.frame
        } + [layout.hintZone]
    }

    let shape: Shape
    var reduced: Bool { shape.reduced }
    /// Both profiles are 0 on and outside this rectangle's edge (whole points).
    let support: CGRect
    let blurImage: CGImage
    let tintImage: CGImage

    var canvas: RadialMenu.Canvas {
        RadialMenu.Canvas(size: support.size, center: CGPoint(x: -support.minX, y: -support.minY))
    }

    init(layout: RadialLayout, reduced: Bool) {
        self.init(shape: Shape(layout: layout, reduced: reduced))
    }

    init(shape: Shape) {
        self.shape = shape
        let extent = shape.boxes.reduce(CGRect(x: -shape.disc, y: -shape.disc, width: 2 * shape.disc, height: 2 * shape.disc)) {
            $0.union($1.insetBy(dx: -shape.pad, dy: -shape.pad))
        }
        let margin = shape.fade + shape.smoothing
        (support, blurImage, tintImage) = Self.images(over: extent.insetBy(dx: -margin, dy: -margin).integral,
                                                      profiles: shape.profiles)
    }

    func blur(at p: CGPoint) -> CGFloat { shape.blur(at: p) }
    func tint(at p: CGPoint) -> CGFloat { shape.tint(at: p) }

    /// Signed distance from `p` to `box`: negative inside.
    static func distance(_ p: CGPoint, to box: CGRect) -> CGFloat {
        let dx = abs(p.x - box.midX) - box.width / 2
        let dy = abs(p.y - box.midY) - box.height / 2
        return hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0)
    }

    static func smoothMin(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat {
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k / 4
    }

    /// The blur's and the tint's images (black, alpha the profile), one pixel per `step` points,
    /// top row first, cropped from `room` to where the blur is not 0 with two empty pixels
    /// around it; and the rectangle they cover. The tint is nowhere stronger than the blur.
    static func images(over room: CGRect, profiles: (CGPoint) -> (blur: CGFloat, tint: CGFloat)) -> (CGRect, CGImage, CGImage) {
        let width = max(1, Int((room.width / step).rounded(.up)))
        let height = max(1, Int((room.height / step).rounded(.up)))
        var values = [(blur: CGFloat, tint: CGFloat)](repeating: (0, 0), count: width * height)
        var (left, right, top, bottom) = (width, -1, height, -1)
        for row in 0..<height {
            let y = room.maxY - (CGFloat(row) + 0.5) * step
            for column in 0..<width {
                let v = profiles(CGPoint(x: room.minX + (CGFloat(column) + 0.5) * step, y: y))
                guard v.blur > 0.5 / 255 else { continue }
                values[row * width + column] = v
                (left, right, top, bottom) = (min(left, column), max(right, column), min(top, row), max(bottom, row))
            }
        }
        if right < left { (left, right, top, bottom) = (width / 2, width / 2, height / 2, height / 2) }
        let margin = 2
        let x0 = left - margin, x1 = right + margin, y0 = top - margin, y1 = bottom + margin
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var blurBytes = [UInt8](repeating: 0, count: w * h * 4)
        var tintBytes = blurBytes
        for row in max(0, y0)...min(height - 1, y1) {
            for column in max(0, x0)...min(width - 1, x1) {
                let v = values[row * width + column]
                guard v.blur > 0 else { continue }
                let i = ((row - y0) * w + (column - x0)) * 4 + 3
                blurBytes[i] = UInt8((v.blur * 255).rounded())
                tintBytes[i] = UInt8((v.tint * 255).rounded())
            }
        }
        let support = CGRect(x: room.minX + CGFloat(x0) * step, y: room.maxY - CGFloat(y1 + 1) * step,
                             width: CGFloat(w) * step, height: CGFloat(h) * step)
        return (support, image(blurBytes, width: w, height: h), image(tintBytes, width: w, height: h))
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
