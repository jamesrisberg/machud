import AppKit

/// The path-based wheel's words, all upright, where each sits, and which one the pointer selects.
/// Pure: it measures with CoreText and draws nothing. Coordinates are the wheel's: its centre at
/// the origin, y up.
///
/// - Petals. Every node of the tree (`RadialNode`) is a word anchored on its direction
///   (`RadialNode.angle`) and growing away from the centre: on the right half it starts at its
///   anchor, on the left half it ends there, at the top and the bottom it is centred on it,
///   blending between; above the centre it stands on its anchor, below it hangs from it. The top
///   petals sit at `topRadius`; a branch's children sit together on one circle beyond it, as near
///   as they can be without touching any word that shows while that branch is open (its
///   ancestors, their siblings, the top petals, the centre and the digits). How far out that is
///   depends on the words, never on how many loadouts there are: their directions are fixed.
///   Under the pointer a petal grows from its anchor (away from the centre), as far as
///   `RadialWheelView.grow` without touching a word that shows with it.
/// - A name is fitted to its width (wrap to two lines, then shrink, then cut after a whole word);
///   a top petal or a loadout shows up to `maxIcons` icons in a row under its name.
/// - Digits 1 to 4, small, just inside the dead zone's edge by each top petal; "Esc" / "Cancel"
///   in the centre.
/// - The hint: under every word showing, up to two lines no wider than `hintWidth`. Where it sits
///   depends on which branch is open (`hintZone(open:)`).
///
/// `scale` draws the whole wheel smaller (radii, words and gaps alike), for a screen it would
/// not otherwise fit (`fitting(_:in:)`).
struct RadialLayout: Equatable {
    struct Word: Equatable {
        enum Role: Hashable {
            /// A petal: the node at this path.
            case node([String])
            /// A top petal's digit, by its index among the top petals.
            case digit(Int)
            case centre

            var path: [String]? { if case .node(let p) = self { return p } else { return nil } }
        }

        var role: Role
        var fit: TextFit
        var style: TextFit.Style
        /// The word's box, icons included.
        var frame: CGRect
        /// Where each line sits across the frame: 0 at its left edge, 1 at its right.
        var align: CGFloat
        /// Icons in a row under the lines.
        var icons: Int
        /// The point the word is anchored at, on its direction; it grows from here.
        var anchor: CGPoint
        /// How many times its size it grows under the pointer; 1 for words that do not.
        var grow: CGFloat = 1

        var font: NSFont { style.font(fit.size) }
        var lineHeight: CGFloat { PreparedText.lineHeight(font) }
        var textHeight: CGFloat { CGFloat(fit.lines.count) * lineHeight }
        /// The box as it is under the pointer.
        var grownFrame: CGRect { RadialLayout.grown(frame, by: grow, about: anchor) }
    }

    /// A node as the pointer sees it: its direction, and for a branch where its children start
    /// and the arc they cover.
    struct Petal: Equatable {
        var angle: Double
        var children: [String]
        /// From this radius out, past the branch's word, the pointer picks among its children.
        var start: CGFloat = .infinity
        /// The children's arc, clockwise from `from` to `to` (radians, either may be outside
        /// 0..<2π); nil when it is the whole circle.
        var arc: ClosedRange<Double>? = nil

        var hasChildren: Bool { !children.isEmpty }

        func covers(_ angle: Double) -> Bool {
            guard let arc else { return true }
            let mid = (arc.lowerBound + arc.upperBound) / 2
            return abs(RadialGeometry.difference(angle, mid)) <= (arc.upperBound - arc.lowerBound) / 2
        }
    }

    // Full-size metrics, in points.
    static let deadZone: CGFloat = 44
    static let topRadius: CGFloat = 58
    /// The least room between two words.
    static let wordGap: CGFloat = 6
    /// The least room between a branch's children and the words showing nearer the centre, the
    /// branch's own word grown.
    static let levelGap: CGFloat = 12
    static let topWidth: CGFloat = 130
    static let loadoutWidth: CGFloat = 120
    static let actionWidth: CGFloat = 130
    static let iconSize: CGFloat = 15
    static let iconSpacing: CGFloat = 4
    static let iconGap: CGFloat = 3
    static let hintWidth: CGFloat = 380
    static let hintGap: CGFloat = 12
    static let digitInset: CGFloat = 10
    /// A wheel of up to this many loadouts shows their apps' icons.
    static let iconLimit = 8
    static let maxIcons = 4
    /// How much further out a branch's children move each time they would touch a word.
    static let push: CGFloat = 2

    let scale: CGFloat
    let deadZone: CGFloat
    let words: [Word]
    let petals: [[String]: Petal]
    /// The top petals' ids, in order.
    let top: [String]
    let hintStyle: TextFit.Style
    /// Where the hint's lines go for each open branch: centred under the words showing, top
    /// line at its top.
    let hintZones: [[String]: CGRect]
    /// Every word and every hint zone: what the wheel needs on screen.
    let bounds: CGRect
    private let index: [Word.Role: Int]

    func word(_ role: Word.Role) -> Word? { index[role].map { words[$0] } }
    func word(_ path: [String]) -> Word? { word(.node(path)) }
    func petal(_ path: [String]) -> Petal? { petals[path] }

    /// The icons drawn by the node at `path`.
    func icons(of path: [String]) -> Int { word(path)?.icons ?? 0 }

    func hintLineHeight(_ fit: TextFit) -> CGFloat { PreparedText.lineHeight(hintStyle.font(fit.size)) }

    // MARK: What shows

    /// The deepest branch on `path` whose children show: the path itself when its last node has
    /// children, else its parent ([] for the root).
    func openBranch(_ path: [String]) -> [String] {
        var path = path
        while !path.isEmpty, petals[path]?.hasChildren != true { path.removeLast() }
        return path
    }

    /// The petals showing while `open` is the open branch: the top petals and the children of
    /// every branch along `open`.
    func showing(open: [String]) -> [[String]] {
        var out = top.map { [$0] }
        var prefix: [String] = []
        for id in open {
            prefix.append(id)
            guard let petal = petals[prefix] else { break }
            out += petal.children.map { prefix + [$0] }
        }
        return out
    }

    /// The hint's zone while `open` is the open branch.
    func hintZone(open: [String]) -> CGRect { hintZones[openBranch(open)] ?? hintZones[[]] ?? .zero }

    /// Every branch that opens: the root and each node with children.
    var branches: [[String]] { [[]] + petals.filter(\.value.hasChildren).keys.sorted { $0.lexicographicallyPrecedes($1) } }

    // MARK: The pointer

    /// The path the pointer at `p` selects, the last selection being `open`:
    /// - nothing (the centre) inside the dead zone;
    /// - the highlighted petal while the pointer is on it as it is grown;
    /// - a petal open along `open`, the deepest first, keeps the pointer while it is within its
    ///   children's arc and either past where they start (`hold(_:radius:angle:)`: the petal under
    ///   the pointer among what unfolded beyond it, else its child nearest the pointer's
    ///   direction, and on out) or out at the petal's own circle (the word under the pointer among
    ///   its siblings and what unfolded beyond them, else the petal itself). A top petal's own
    ///   circle starts at the dead zone's edge and it has no siblings there: while it is open, no
    ///   other top petal takes the pointer within its children's arc; going back through the
    ///   centre does. So moving among a branch's children, from Apply Loadout's word to a loadout
    ///   across Capture's, Park's or Widgets' word, or from a loadout toward its outermost action
    ///   across a neighbour's direction, never opens another branch on the way;
    /// - else the petal showing under the pointer;
    /// - else, out from the centre, the top petal nearest its direction, then (past where that
    ///   branch's children start, within their arc) the child nearest it, and so on.
    func selection(at p: CGPoint, open: [String]) -> [String] {
        let r = RadialGeometry.radius(of: p)
        guard r >= deadZone, !top.isEmpty else { return [] }
        if !open.isEmpty, let lit = word(open), lit.grownFrame.contains(p) { return open }
        let a = RadialGeometry.angle(of: p)
        let shown = showing(open: openBranch(open))
        func under(_ scope: [String]) -> [String]? {
            shown.first { $0.count > scope.count && $0.starts(with: scope) && word($0)?.frame.contains(p) == true }
        }
        if let hold = hold(open, radius: r, angle: a) {
            switch hold {
            case .beyond(let held): return under(hold.scope) ?? outward(from: held, radius: r, angle: a)
            case .at(let held): return under(hold.scope) ?? held
            }
        }
        return under([]) ?? outward(from: [], radius: r, angle: a)
    }

    /// How a petal open along a path keeps the pointer (`selection(at:open:)`).
    enum Hold: Equatable {
        /// Past where its children start, within their arc.
        case beyond([String])
        /// Out at its own circle (a top petal: past the dead zone), within its children's arc.
        case at([String])

        /// Where the words keep the pointer: the held petal's descendants past where its
        /// children start, and out at its own circle its siblings' too, below the top petals.
        var scope: [String] {
            switch self {
            case .beyond(let held): return held
            case .at(let held): return held.count == 1 ? held : Array(held.dropLast())
            }
        }
    }

    /// The petal along `open` that keeps a pointer at radius `r` and angle `a`, the deepest first.
    func hold(_ open: [String], radius r: CGFloat, angle a: Double) -> Hold? {
        let branch = openBranch(open)
        for depth in stride(from: branch.count, through: 1, by: -1) {
            let held = Array(branch.prefix(depth))
            guard let petal = petals[held], petal.hasChildren, petal.covers(a) else { continue }
            if r >= petal.start { return .beyond(held) }
            let circle = depth == 1 ? deadZone : word(held).map { RadialGeometry.radius(of: $0.anchor) } ?? .infinity
            if r >= circle { return .at(held) }
        }
        return nil
    }

    /// From the branch at `path` out: its child nearest `a`, then, while `r` is past where that
    /// one's children start and within their arc, its child nearest `a`, and so on.
    private func outward(from path: [String], radius r: CGFloat, angle a: Double) -> [String] {
        var path = path
        var ids = path.isEmpty ? top : petals[path]?.children ?? []
        while !ids.isEmpty {
            let parent = path
            func distance(_ id: String) -> Double { abs(RadialGeometry.difference(a, petals[parent + [id]]?.angle ?? 0)) }
            path.append(ids.min { distance($0) < distance($1) }!)
            guard let petal = petals[path], petal.hasChildren, r >= petal.start, petal.covers(a) else { break }
            ids = petal.children
        }
        return path
    }

    // MARK: Building

    init(tree: [RadialNode], scale: CGFloat = 1) {
        let s = max(0.25, min(1, scale))
        self.scale = s
        let dead = Self.deadZone * s
        deadZone = dead
        let gap = Self.wordGap * s
        let clearance = Self.levelGap * s
        let maxGrow = RadialWheelView.grow
        let nameStyle = TextFit.Style.name.scaled(s)
        let labelStyle = TextFit.Style.label.scaled(s)
        top = tree.map(\.id)

        var words: [Word] = []
        var petals: [[String]: Petal] = [:]

        // The centre and the top petals' digits.
        let centre = Self.centre(scale: s)
        words.append(centre)
        for (i, node) in tree.prefix(9).enumerated() {
            words.append(Self.digit(i, angle: node.angle, deadZone: dead, scale: s))
        }
        let fixed = words.map(\.frame)

        let loadoutIcons = (tree.first { $0.kind == .loadouts }?.children.count ?? 0) <= Self.iconLimit

        func style(_ node: RadialNode) -> (TextFit.Style, CGFloat, Int) {
            switch node.kind {
            case .action: return (labelStyle, Self.actionWidth * s, 0)
            case .loadout: return (nameStyle, Self.loadoutWidth * s, loadoutIcons ? min(node.icons.count, Self.maxIcons) : 0)
            case .loadouts, .capture, .park, .widgets: return (nameStyle, Self.topWidth * s, min(node.icons.count, Self.maxIcons))
            }
        }

        /// Places `nodes` (the children of the branch at `parent`) on one circle from `from` out,
        /// clear of `context`, and works out how far each grows clear of `context` and its siblings.
        func place(_ nodes: [RadialNode], parent: [String], from: CGFloat, context: [CGRect]) -> [Word] {
            let fits = nodes.map { node -> (TextFit, TextFit.Style, Int) in
                let (style, width, icons) = style(node)
                return (TextFit.fit(node.name, style: style, width: width), style, icons)
            }
            var radius = from
            var placed: [Word] = []
            for _ in 0..<600 {
                placed = nodes.indices.map { i in
                    Self.petal(nodes[i].name, path: parent + [nodes[i].id], fit: fits[i].0, style: fits[i].1, icons: fits[i].2,
                               angle: nodes[i].angle, radius: radius, scale: s)
                }
                let clear = placed.allSatisfy { word in
                    let padded = word.frame.insetBy(dx: -clearance, dy: -clearance)
                    return Self.distance(to: word.frame) >= dead + gap && !context.contains { $0.intersects(padded) }
                }
                let apart = !placed.indices.contains { a in
                    placed.indices.contains { b in b > a && placed[a].frame.insetBy(dx: -gap, dy: -gap).intersects(placed[b].frame) }
                }
                if clear && apart { break }
                radius += Self.push * s
            }
            for k in placed.indices {
                let others = context + placed.indices.filter { $0 != k }.map { placed[$0].frame }
                placed[k].grow = Self.largestGrowth(placed[k], upTo: maxGrow, avoiding: others, gap: gap)
            }
            return placed
        }

        /// Lays out the children of `node` (at `path`) and everything under them; `context` is
        /// what shows beside them, the branch's own word grown.
        func open(_ node: RadialNode, path: [String], word: Word, context: [CGRect]) {
            let anchorRadius = RadialGeometry.radius(of: word.anchor)
            var petal = Petal(angle: node.angle, children: node.children.map(\.id))
            guard !node.children.isEmpty else { petals[path] = petal; return }
            let children = place(node.children, parent: path, from: anchorRadius + gap, context: context + [word.grownFrame])
            words += children
            petal.start = children.map { Self.distance(to: $0.frame) }.min().map { $0 - gap / 2 } ?? .infinity
            petal.arc = Self.arc(of: node.children.map { $0.angle }, around: node.angle)
            petals[path] = petal
            let siblings = children.map(\.frame)
            for (child, childWord) in zip(node.children, children) {
                let rest = siblings.filter { $0 != childWord.frame }
                open(child, path: path + [child.id], word: childWord, context: context + [word.frame] + rest)
            }
        }

        let topWords = place(tree, parent: [], from: Self.topRadius * s, context: fixed)
        words += topWords
        let topFrames = topWords.map(\.frame)
        for (node, word) in zip(tree, topWords) {
            open(node, path: [node.id], word: word, context: fixed + topFrames.filter { $0 != word.frame })
        }
        if !tree.isEmpty { petals[[]] = Petal(angle: 0, children: top) }

        self.words = words
        self.petals = petals
        index = Dictionary(words.enumerated().map { ($1.role, $0) }, uniquingKeysWith: { a, _ in a })

        // The hint, under the words showing for each open branch.
        hintStyle = TextFit.Style.hint.scaled(s)
        let hintHeight = 2 * PreparedText.lineHeight(hintStyle.font(hintStyle.preferred))
        let hintWidth = Self.hintWidth * s
        var zones: [[String]: CGRect] = [:]
        let byRole = Dictionary(words.map { ($0.role, $0) }, uniquingKeysWith: { a, _ in a })
        let branchPaths = [[]] + petals.filter(\.value.hasChildren).map(\.key)
        for branch in branchPaths {
            var shown = Self.showing(top: top, petals: petals, open: branch).compactMap { byRole[.node($0)]?.grownFrame }
            shown += fixed
            let lowest = shown.map(\.minY).min() ?? 0
            zones[branch] = CGRect(x: -hintWidth / 2, y: lowest - Self.hintGap * s - hintHeight, width: hintWidth, height: hintHeight)
        }
        hintZones = zones
        bounds = words.reduce(zones.values.reduce(CGRect.null) { $0.union($1) }) { $0.union($1.grownFrame) }
    }

    private static func showing(top: [String], petals: [[String]: Petal], open: [String]) -> [[String]] {
        var out = top.map { [$0] }
        var prefix: [String] = []
        for id in open {
            prefix.append(id)
            guard let petal = petals[prefix] else { break }
            out += petal.children.map { prefix + [$0] }
        }
        return out
    }

    /// The layout of `tree` at full size, or smaller where that would not fit in `room`.
    static func fitting(_ tree: [RadialNode], in room: CGSize) -> RadialLayout {
        var layout = RadialLayout(tree: tree)
        var scale: CGFloat = 1
        for _ in 0..<12 {
            let fits = layout.bounds.width <= room.width && layout.bounds.height <= room.height
            if fits || scale <= 0.25 { break }
            scale = min(scale * 0.97, scale * min(room.width / layout.bounds.width, room.height / layout.bounds.height))
            layout = RadialLayout(tree: tree, scale: scale)
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

    private static func digit(_ index: Int, angle: Double, deadZone: CGFloat, scale s: CGFloat) -> Word {
        let style = TextFit.Style.digit.scaled(s)
        let fit = TextFit(lines: ["\(index + 1)"], size: style.preferred, truncated: false)
        let p = RadialGeometry.point(deadZone - digitInset * s, angle)
        return Word(role: .digit(index), fit: fit, style: style, frame: box(fit, style: style, centredAt: p),
                    align: 0.5, icons: 0, anchor: p)
    }

    /// The centre's word, as wide as the wider of "Esc" and "Cancel".
    private static func centre(scale s: CGFloat) -> Word {
        let style = TextFit.Style.centre.scaled(s)
        let fit = TextFit(lines: ["Cancel"], size: style.preferred, truncated: false)
        return Word(role: .centre, fit: fit, style: style, frame: box(fit, style: style, centredAt: .zero), align: 0.5,
                    icons: 0, anchor: .zero)
    }

    /// 0 for `x` at or below `-0.5`, 1 at or above `0.5`, smoothly between.
    private static func blend(_ x: Double) -> CGFloat {
        let t = (min(1, max(-1, x / 0.5)) + 1) / 2
        return CGFloat(t * t * (3 - 2 * t))
    }

    /// A petal anchored at `radius` on direction `a`, growing away from the centre.
    private static func petal(_ name: String, path: [String], fit: TextFit, style: TextFit.Style, icons: Int, angle a: Double,
                              radius: CGFloat, scale s: CGFloat) -> Word {
        let font = style.font(fit.size)
        let row = icons > 0 ? CGFloat(icons) * iconSize * s + CGFloat(icons - 1) * iconSpacing * s : 0
        let w = max(fit.lines.map { TextFit.width($0, font: font) }.max() ?? 0, row)
        let h = CGFloat(fit.lines.count) * PreparedText.lineHeight(font) + (icons > 0 ? (iconGap + iconSize) * s : 0)
        let anchor = RadialGeometry.point(radius, a)
        let align = 1 - blend(sin(a))
        let lift = 1 - blend(cos(a))
        return Word(role: .node(path), fit: fit, style: style,
                    frame: CGRect(x: anchor.x - align * w, y: anchor.y - lift * h, width: w, height: h),
                    align: align, icons: icons, anchor: anchor)
    }

    /// The arc covering `angles` around `centre`, half a step past the outermost on each side;
    /// nil when they go all the way round.
    private static func arc(of angles: [Double], around centre: Double) -> ClosedRange<Double>? {
        let offsets = angles.map { RadialGeometry.difference($0, centre) }.sorted()
        guard let low = offsets.first, let high = offsets.last else { return nil }
        let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }.filter { $0 > 1e-6 }
        let half = (steps.min() ?? RadialGeometry.fullTurn / 4) / 2
        guard high - low + 2 * half < RadialGeometry.fullTurn - 1e-6 else { return nil }
        return (centre + low - half)...(centre + high + half)
    }

    /// The distance from the centre to the nearest point of `rect`.
    static func distance(to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX, 0, -rect.maxX), max(rect.minY, 0, -rect.maxY))
    }

    /// `frame` grown `factor` times about `point`.
    static func grown(_ frame: CGRect, by factor: CGFloat, about point: CGPoint) -> CGRect {
        CGRect(x: point.x + (frame.minX - point.x) * factor, y: point.y + (frame.minY - point.y) * factor,
               width: frame.width * factor, height: frame.height * factor)
    }

    /// The most `word` can grow from its anchor, up to `limit`, without coming within `gap` of
    /// any of `others`.
    private static func largestGrowth(_ word: Word, upTo limit: CGFloat, avoiding others: [CGRect], gap: CGFloat) -> CGFloat {
        func fits(_ factor: CGFloat) -> Bool {
            let big = grown(word.frame, by: factor, about: word.anchor).insetBy(dx: -gap / 2, dy: -gap / 2)
            return !others.contains { $0.intersects(big) }
        }
        if fits(limit) { return limit }
        var (low, high) = (CGFloat(1), limit)
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}

// MARK: - Directions

/// Angles and radii about the wheel's centre. Angles run clockwise from straight up, in radians.
enum RadialGeometry {
    static let fullTurn = 2 * Double.pi

    /// Angle of `offset` measured clockwise from straight up, in `0..<2π`.
    static func angle(of offset: CGPoint) -> Double {
        let a = atan2(Double(offset.x), Double(offset.y))
        return a < 0 ? a + fullTurn : a
    }

    static func radius(of offset: CGPoint) -> CGFloat { hypot(offset.x, offset.y) }

    static func point(_ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
    }

    /// `a` less `b`, in `-π..<π`.
    static func difference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: fullTurn)
        if d >= .pi { d -= fullTurn }
        if d < -.pi { d += fullTurn }
        return d
    }

    /// `a` in `0..<2π`.
    static func normalized(_ a: Double) -> Double {
        let d = a.truncatingRemainder(dividingBy: fullTurn)
        return d < 0 ? d + fullTurn : d
    }
}

// MARK: - The field

/// The one soft region the wheel's words sit on, fading to nothing with no edge, as two
/// profiles over the same shape. Pure functions from the words showing to an alpha in 0...1:
/// - `blur`: what the backdrop's blur shows through (`blurImage`). It is full wherever a word
///   showing can be, so no sharp desktop shows through there (an alpha is a cross-fade between
///   the blurred desktop and the sharp one), and fades only outside that.
/// - `tint`: the profile of the tint the wheel draws (`tintImage`): the same, a little weaker
///   toward the rim (`rim`), so the middle is darkest. Its strength is the tint view's darkness.
/// The snapshots show the blurred desktop through `blur` and the tint through `tint`.
///
/// The shape is a disc a little past the top petals united with a rounded box around each word
/// showing that reaches outside it (grown under the pointer) and the hint's two-line zone, joined
/// smoothly, full inside and fading over `fade` outside. With Reduce transparency on it is a
/// plain soft disc around every word showing. Each open branch has its own field; every field of
/// a layout covers the same rectangle (`support`, the one around every word), so the wheel's views
/// keep their frames as branches open.
struct RadialField {
    /// What the field is made from: two layouts and branches with the same shape have the same field.
    struct Shape: Equatable {
        var disc: CGFloat
        var boxes: [CGRect]
        var reach: CGFloat
        var fade: CGFloat
        var pad: CGFloat
        var smoothing: CGFloat
        var reduced: Bool

        /// The shape of the words showing while `open` is the open branch; nil: every word.
        init(layout: RadialLayout, open: [String]?, reduced: Bool) {
            let s = layout.scale
            pad = RadialField.pad * s
            fade = RadialField.fade * s
            smoothing = RadialField.smoothing * s
            let frames = RadialField.places(layout, open: open)
            let farthest = { (r: CGRect) in hypot(max(abs(r.minX), abs(r.maxX)), max(abs(r.minY), abs(r.maxY))) }
            reach = max(1, frames.map(farthest).max() ?? 1)
            let topReach = layout.top.compactMap { layout.word([$0])?.grownFrame }.map(farthest).max() ?? layout.deadZone
            disc = reduced ? reach + pad : topReach + RadialField.discReach * s
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
            let u = min(1, r / reach)
            let rim = 1 - RadialField.rim * u * u * (3 - 2 * u)
            var d = r - disc
            // Inside the disc the union only lies deeper: the blur is full there.
            guard d > 0 else { return (1, rim) }
            for box in boxes { d = RadialField.smoothMin(d, RadialField.distance(p, to: box) - pad, smoothing) }
            guard d < fade else { return (0, 0) }
            let t = max(0, d / fade)
            let blur = 1 - t * t * t * (t * (t * 6 - 15) + 10)
            return (blur, blur * rim)
        }

        /// The rectangle the profiles are not 0 inside of.
        var extent: CGRect {
            let disc = CGRect(x: -self.disc, y: -self.disc, width: 2 * self.disc, height: 2 * self.disc)
            let all = boxes.reduce(disc) { $0.union($1.insetBy(dx: -pad, dy: -pad)) }
            // A smooth union reaches past its parts by a fraction of the smoothing.
            let margin = fade + smoothing / 2
            return all.insetBy(dx: -margin, dy: -margin).integral
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
    static let fade: CGFloat = 60
    static let smoothing: CGFloat = 90
    /// How far past the top petals the field's disc reaches.
    static let discReach: CGFloat = 16
    /// Points per pixel of the blur's and the tint's images: the field is smooth enough to be
    /// stretched.
    static let step: CGFloat = 4

    /// Every place a word showing while `open` is the open branch can be (nil: every word): each
    /// petal's box grown under the pointer (a name's with its icons), the digits, the centre and
    /// the hint's two-line zone.
    static func places(_ layout: RadialLayout, open: [String]?) -> [CGRect] {
        let fixed = layout.words.filter { $0.role.path == nil }.map(\.frame)
        guard let open else {
            return layout.words.map(\.grownFrame) + layout.hintZones.values.sorted { $0.minY < $1.minY }.prefix(1)
        }
        let showing = layout.showing(open: layout.openBranch(open)).compactMap { layout.word($0)?.grownFrame }
        return fixed + showing + [layout.hintZone(open: open)]
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

    /// The field of every word of `layout`, over the smallest rectangle that holds it.
    init(layout: RadialLayout, reduced: Bool) {
        self.init(shape: Shape(layout: layout, open: nil, reduced: reduced))
    }

    /// The field of `shape` over `support` (its own extent, cropped to where it is not 0, when nil).
    init(shape: Shape, over support: CGRect? = nil) {
        self.shape = shape
        if let support {
            (self.support, blurImage, tintImage) = Self.images(over: support, crop: false, profiles: shape.profiles)
        } else {
            (self.support, blurImage, tintImage) = Self.images(over: shape.extent, crop: true, profiles: shape.profiles)
        }
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
    /// top row first, and the rectangle they cover: `room`, or with `crop` the part of it where
    /// the blur is not 0 with two empty pixels around it. The tint is nowhere stronger than the blur.
    static func images(over room: CGRect, crop: Bool,
                       profiles: (CGPoint) -> (blur: CGFloat, tint: CGFloat)) -> (CGRect, CGImage, CGImage) {
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
        let (x0, x1, y0, y1) = crop ? (left - margin, right + margin, top - margin, bottom + margin) : (0, width - 1, 0, height - 1)
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
