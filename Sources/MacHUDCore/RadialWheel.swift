import AppKit
import HUDKit
import QuartzCore

// MARK: - The look

/// The wheel's glass: every word that shows sits in its own bubble of HUDKit's glass
/// (`HUDGlassView`: the window server's blur of what is behind the window under the glass's
/// tint, or the system's material with Reduce transparency on), with the wheel's own tint over
/// that so its white words read over a white desktop too, the family's jelly gloss and a
/// hairline border. The petal highlighted is accent-tinted, the path to it less so.
///
/// The window server blurs wherever the wheel's window draws, so many bubbles in one window are
/// each blurred in their own shape, and nothing else in the window may draw: every word, digit
/// and the hint is inside a bubble.
enum RadialGlass {
    /// Room around a word's box (its lines and its icon row) inside its bubble, at full size. The
    /// layout keeps 14 pt or more across between words that show together (two full loadout
    /// places side by side) and more above and below, so bubbles at rest never touch.
    static let padding = CGSize(width: 6, height: 4)
    /// A bubble's corners: half its height (a capsule) up to this, at full size, so a word on two
    /// lines or over its icon row keeps its corners inside.
    static let corner: CGFloat = 14
    /// How far the centre's disc reaches past the digits around it, at full size.
    static let hubMargin: CGFloat = 4
    /// The wheel's tint over the glass's own, under the words: black, so a white word over a
    /// white desktop reads at better than 4.5 to 1 (`RadialWheelTests`).
    static let restTint: CGFloat = 0.5
    /// The glass's own tint in its dark appearance (`HUDGlassView`).
    static let glassTint: CGFloat = 0.2
    static let borderAlpha: CGFloat = 0.28
    static let litBorderAlpha: CGFloat = 0.55
    /// The words' opacity at rest (on the path and highlighted they are at full strength).
    static let restText: Float = 0.9
    /// The words' opacity beside the petal on the path, and once the path has gone on past
    /// them: they step back while their glass stays as it is, so they still read.
    static let recededText: Float = 0.75
    static let beyondText: Float = 0.62

    /// The words' opacity at `emphasis`.
    static func text(_ emphasis: RadialBubble.Emphasis) -> Float {
        switch emphasis {
        case .lit, .path: return 1
        case .rest: return restText
        case .receded: return recededText
        case .beyond: return beyondText
        }
    }

    /// The tint of a bubble at `emphasis`: black at rest, the accent colour darkened on the path
    /// and less darkened on the petal highlighted.
    static func tint(_ emphasis: RadialBubble.Emphasis) -> CGColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        switch emphasis {
        case .lit: return accent.blended(withFraction: 0.25, of: .black)!.withAlphaComponent(0.72).cgColor
        case .path: return accent.blended(withFraction: 0.5, of: .black)!.withAlphaComponent(0.6).cgColor
        case .rest, .receded, .beyond: return NSColor.black.withAlphaComponent(restTint).cgColor
        }
    }

    /// The corner radius of a bubble `height` tall on a wheel drawn at `scale`.
    static func cornerRadius(height: CGFloat, scale: CGFloat) -> CGFloat { min(height / 2, corner * scale) }

    /// A bubble around `box`, a word's box, on a wheel drawn at `scale`.
    static func bubble(around box: CGRect, scale: CGFloat) -> CGRect {
        box.insetBy(dx: -padding.width * scale, dy: -padding.height * scale)
    }

    /// The centre's disc: around "Esc" / "Cancel" and the top petals' digits, inside the dead zone.
    static func hub(in layout: RadialLayout) -> CGRect {
        let s = layout.scale
        let parts = layout.words.filter { $0.role.path == nil }.map(\.frame)
        let reach = parts.map { hypot(max(abs($0.minX), abs($0.maxX)), max(abs($0.minY), abs($0.maxY))) }.max() ?? 0
        let r = (reach + hubMargin * s).rounded(.up)
        return CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
    }
}

// MARK: - Motion

/// How bubbles come and go. A bubble appearing pops out: a spring from `bloomFrom` times its
/// size to its size, with a small overshoot, over `bloomDuration`, fading in over `fadeIn`; a
/// branch's children follow it outward by `stagger` a ring. A bubble going away shrinks to
/// `vanishScale` and fades in `vanishDuration`. With Reduce motion on they only fade. Motion is
/// what the screen shows only: the layout, selection and commit never wait for it.
enum RadialMotion {
    static let bloomFrom: CGFloat = 0.6
    static let bloomDuration: TimeInterval = 0.25
    static let fadeIn: TimeInterval = 0.16
    static let stagger: TimeInterval = 0.035
    static let vanishScale: CGFloat = 0.8
    static let vanishDuration: TimeInterval = 0.12
    /// A change of highlight: the tint, the words and a petal's grow.
    static let restyle: TimeInterval = 0.14
    /// The spring: a little under-damped, settled within `bloomDuration`.
    static let stiffness = 680.0
    static let damping = 0.6
    /// The spring's samples' interval.
    static let step = 1.0 / 120.0

    /// The spring from `from` to `to`, sampled every `step` over `bloomDuration`; the last
    /// sample is `to`.
    static func spring(from: CGFloat, to: CGFloat) -> [CGFloat] {
        var spring = HUDSpring(Double(from))
        spring.target = Double(to)
        let count = Int((bloomDuration / step).rounded())
        var out = [from]
        for _ in 1..<count {
            _ = spring.step(dt: step, stiffness: stiffness, damping: damping, epsilon: 0.0005)
            out.append(CGFloat(spring.value))
        }
        out.append(to)
        return out
    }
}

// MARK: - A bubble

/// One word's glass bubble: the glass (`HUDGlassView`), the wheel's tint, the family's gloss and
/// the word's picture, drawn once. It grows and shrinks about `pivot` (the word's anchor, so a
/// petal grows away from the centre) by its layer's sublayer transform, which AppKit leaves
/// alone, and fades by its opacity. It never takes the mouse.
@MainActor
final class RadialBubble: NSView {
    enum Role: Hashable {
        /// A petal's word, or the centre (`RadialLayout.Word.Role.centre`) with the digits.
        case word(RadialLayout.Word.Role)
        /// The line under the wheel.
        case hint
    }

    enum Emphasis: Equatable {
        case rest
        /// On the path to the petal highlighted.
        case path
        /// The petal highlighted.
        case lit
        /// Beside the petal on the path.
        case receded
        /// Beside the petal on the path, which has gone on past it.
        case beyond
    }

    let role: Role
    let glass: HUDGlassView
    private let tintView = RadialLayerView()
    private let tint = CALayer()
    private let gloss: HUDGlossView
    /// The pictures: the word's, or the centre's "Esc", "Cancel" and digits.
    let face = RadialLayerView()
    /// Where it grows from, in its own coordinates.
    var pivot: CGPoint = .zero

    /// It shows, or is appearing (as opposed to gone or going).
    private(set) var isShowing = false
    private(set) var emphasis: Emphasis = .rest
    /// The size it shows at (a petal highlighted grows), times its rest size.
    private(set) var scale: CGFloat = 1
    /// Counts appearances and disappearances: a fade-out that finishes after the bubble came
    /// back does not hide it.
    private var generation = 0

    init(role: Role, frame: CGRect, scale s: CGFloat) {
        self.role = role
        glass = HUDGlassView(frame: CGRect(origin: .zero, size: frame.size),
                             style: Self.style(height: frame.height, scale: s, circle: role == .word(.centre)))
        gloss = HUDGlossView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        for view in [tintView, gloss, face] as [NSView] {
            view.frame = glass.bounds
            view.autoresizingMask = [.width, .height]
            glass.addSubview(view)
        }
        tint.frame = tintView.bounds
        tint.backgroundColor = RadialGlass.tint(.rest)
        tintView.layer?.addSublayer(tint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func style(height: CGFloat, scale s: CGFloat, circle: Bool) -> HUDGlassView.Style {
        HUDGlassView.Style(cornerRadius: circle ? height / 2 : RadialGlass.cornerRadius(height: height, scale: s),
                           borderWidth: 1, borderAlpha: RadialGlass.borderAlpha, gloss: false)
    }

    /// Moves to `frame` (the hint, whose words change), keeping its corners right for its height.
    func place(_ frame: CGRect, scale s: CGFloat) {
        guard frame != self.frame else { return }
        self.frame = frame
        glass.style = Self.style(height: frame.height, scale: s, circle: role == .word(.centre))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = tintView.bounds
        CATransaction.commit()
        if emphasis == .lit { glass.layer?.borderColor = NSColor.white.withAlphaComponent(RadialGlass.litBorderAlpha).cgColor }
        sublayer(scale: scale)
    }

    // MARK: Showing

    /// `factor` times its size about `pivot`, as a sublayer transform.
    func transform(_ factor: CGFloat) -> CATransform3D {
        // The sublayer transform applies about the layer's anchor point.
        let anchor = layer.map { CGPoint(x: $0.anchorPoint.x * bounds.width, y: $0.anchorPoint.y * bounds.height) } ?? .zero
        let p = CGPoint(x: pivot.x - anchor.x, y: pivot.y - anchor.y)
        var t = CATransform3DMakeTranslation(p.x, p.y, 0)
        t = CATransform3DScale(t, factor, factor, 1)
        return CATransform3DTranslate(t, -p.x, -p.y, 0)
    }

    private func sublayer(scale factor: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = transform(factor)
        CATransaction.commit()
    }

    /// The size it is drawn at now, mid-animation included, times its rest size.
    private var presentedScale: CGFloat {
        let t = (layer?.presentation() ?? layer)?.sublayerTransform ?? CATransform3DIdentity
        return t.m11
    }

    private var presentedOpacity: Float { (layer?.presentation() ?? layer)?.opacity ?? 0 }

    private func now() -> CFTimeInterval { layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime() }

    /// Comes in at `emphasis`, `scale` times its size: popping out after `delay` (fading in only
    /// without `motion`), or at once with no delay.
    func appear(emphasis: Emphasis, scale target: CGFloat, delay: TimeInterval?, motion: Bool) {
        generation += 1
        let fromOpacity = isHidden ? 0 : presentedOpacity
        let fromScale = isHidden ? RadialMotion.bloomFrom : max(RadialMotion.bloomFrom, presentedScale)
        isShowing = true
        isHidden = false
        style(emphasis, scale: target, animated: false)
        layer?.removeAllAnimations()
        guard let delay, let layer else { return }
        let begin = now() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = Float(1)
        fade.duration = RadialMotion.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = begin
        fade.fillMode = .backwards
        layer.add(fade, forKey: "opacity")
        guard motion else { return }
        layer.add(bloom(from: fromScale, to: target, begin: begin), forKey: "scale")
    }

    /// Goes away: shrinking and fading fast (fading only without `motion`), or at once.
    func vanish(animated: Bool, motion: Bool) {
        generation += 1
        isShowing = false
        guard animated, let layer, !isHidden else {
            layer?.removeAllAnimations()
            alphaValue = 0
            isHidden = true
            return
        }
        let generation = self.generation
        let fromOpacity = presentedOpacity, fromScale = presentedScale
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.isHidden = true
            }
        }
        layer.removeAllAnimations()
        alphaValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = Float(0)
        fade.duration = RadialMotion.vanishDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "opacity")
        if motion {
            sublayer(scale: fromScale * RadialMotion.vanishScale)
            let shrink = CABasicAnimation(keyPath: "sublayerTransform")
            shrink.fromValue = NSValue(caTransform3D: transform(fromScale))
            shrink.toValue = NSValue(caTransform3D: transform(fromScale * RadialMotion.vanishScale))
            shrink.duration = RadialMotion.vanishDuration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.add(shrink, forKey: "scale")
        }
        CATransaction.commit()
    }

    /// Takes on `emphasis` at `scale` times its size: the tint, the words and the border cross
    /// over in `RadialMotion.restyle` when `animated`, the size springs (or, without `motion`,
    /// changes at once).
    func style(_ emphasis: Emphasis, scale target: CGFloat, animated: Bool, motion: Bool = true) {
        let changed = target != scale
        let fromScale = presentedScale
        self.emphasis = emphasis
        scale = target
        CATransaction.begin()
        CATransaction.setAnimationDuration(RadialMotion.restyle)
        CATransaction.setDisableActions(!animated)
        tint.backgroundColor = RadialGlass.tint(emphasis)
        for picture in face.layer?.sublayers ?? [] where picture.name == nil {
            picture.opacity = RadialGlass.text(emphasis)
        }
        CATransaction.commit()
        glass.layer?.borderColor = NSColor.white.withAlphaComponent(emphasis == .lit ? RadialGlass.litBorderAlpha : RadialGlass.borderAlpha).cgColor
        layer?.zPosition = emphasis == .lit ? 1 : 0
        if isShowing { alphaValue = 1 }
        sublayer(scale: target)
        guard animated, changed, motion, let layer, fromScale != target else { return }
        layer.add(bloom(from: fromScale, to: target, begin: 0), forKey: "scale")
    }

    /// The spring from `from` to `to` times its size, starting at `begin` (0: now).
    private func bloom(from: CGFloat, to: CGFloat, begin: CFTimeInterval) -> CAKeyframeAnimation {
        let samples = RadialMotion.spring(from: from, to: to)
        let bloom = CAKeyframeAnimation(keyPath: "sublayerTransform")
        bloom.values = samples.map { NSValue(caTransform3D: transform($0)) }
        bloom.duration = RadialMotion.step * Double(samples.count - 1)
        bloom.calculationMode = .linear
        if begin > 0 {
            bloom.beginTime = begin
            bloom.fillMode = .backwards
        }
        return bloom
    }

    // MARK: Pictures

    /// Shows `image` (drawn at `pixels` per point) over `rect` of the bubble; `name` marks a
    /// picture whose opacity the wheel sets itself (the centre's).
    @discardableResult
    func show(_ image: CGImage, in rect: CGRect, pixels: CGFloat, name: String? = nil) -> CALayer {
        let picture = face.layer?.sublayers?.first { $0.name == name && name != nil } ?? CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.name = name
        picture.contents = image
        picture.contentsScale = pixels
        picture.frame = rect
        if name == nil { picture.opacity = RadialGlass.text(emphasis) }
        if picture.superlayer == nil { face.layer?.addSublayer(picture) }
        CATransaction.commit()
        return picture
    }

    /// Removes the word's pictures (they are drawn again at another scale).
    func clearPictures() {
        face.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    /// The picture named `name` (the centre's).
    func picture(_ name: String) -> CALayer? { face.layer?.sublayers?.first { $0.name == name } }

    /// The opacity of the word's picture (tests).
    var wordOpacity: Float? { face.layer?.sublayers?.first { $0.name == nil }?.opacity }

    /// Its tint now (tests).
    var tintColor: CGColor? { tint.backgroundColor }
}

/// A layer-backed view with no subviews whose layer holds plain sublayers. It never takes the mouse.
final class RadialLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - The wheel

/// The wheel's words, each in its glass bubble (`RadialBubble`), on a canvas centred where the
/// wheel's centre is. Only what shows has a bubble on screen: the top petals, the centre's disc
/// (Esc or Cancel, with the digits), the line under the wheel and the children of each branch
/// along the path. A bubble is made the first time its word shows, with the word's picture
/// drawn once per layout and backing scale, and kept for the layout. While the wheel is open a
/// branch unfolding pops its children out (`RadialMotion`); `settle` puts everything at rest.
final class RadialWheelView: NSView {
    /// The most a petal grows under the pointer, from its anchor; each grows as far as the
    /// words showing with it allow (`RadialLayout.Word.grow`).
    nonisolated static let grow: CGFloat = 1.25
    /// Room around the layout's bounds on the canvas: a bubble's padding, grown, and its spring.
    static let margin: CGFloat = 16

    /// The canvas for `layout`: every bubble that can show, at its largest.
    static func canvas(for layout: RadialLayout) -> RadialMenu.Canvas {
        let all = layout.bounds.union(RadialGlass.hub(in: layout)).insetBy(dx: -margin * layout.scale, dy: -margin * layout.scale).integral
        return RadialMenu.Canvas(size: all.size, center: CGPoint(x: -all.minX, y: -all.minY))
    }

    /// Whether Reduce motion is on, read as the wheel opens. Tests substitute their own.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private var layout = RadialLayout(tree: [])
    private var tree: [RadialNode] = []
    private var origin: CGPoint = .zero
    private var bubbles: [RadialBubble.Role: RadialBubble] = [:]
    /// The pixels per point the pictures are drawn at (0: none yet).
    private var pixels: CGFloat = 0
    /// How many pictures of the petals' words and the centre's have been drawn (tests). The
    /// hint's is drawn again whenever its words change.
    private(set) var wordRenders = 0
    /// The hint showing, and the zone it is fitted to.
    private var hint: (text: String, zone: CGRect)?
    /// Between `open` and `close`: changes animate.
    private(set) var isOpen = false
    private var motion = true

    var selection: [String] = [] {
        didSet { if selection != oldValue { retarget(animated: isOpen) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `layout`'s words for `tree` on `canvas`, with `selection` highlighted when given.
    func configure(layout: RadialLayout, canvas: RadialMenu.Canvas, tree: [RadialNode], selection: [String]? = nil) {
        if layout != self.layout || canvas.center != origin {
            // The bubbles depend on the layout alone; a new one makes them anew.
            bubbles.values.forEach { $0.removeFromSuperview() }
            bubbles = [:]
            hint = nil
        }
        self.layout = layout
        self.tree = tree
        origin = canvas.center
        if let selection, selection != self.selection {
            // Set without its own retarget: the one below shows it.
            isOpen = false
            self.selection = selection
        } else {
            retarget(animated: false)
        }
    }

    /// The same wheel with nodes whose kinds changed but whose words did not (the park petal's
    /// targets): only the hint changes.
    func update(tree: [RadialNode]) {
        self.tree = tree
        refreshHint()
    }

    /// The wheel shows: the centre, the top petals and the hint pop out, in that order.
    func open() {
        motion = !reducesMotion()
        for bubble in bubbles.values { bubble.vanish(animated: false, motion: false) }
        isOpen = true
        retarget(animated: true)
    }

    /// The wheel is hidden: every bubble goes at once, to pop out again as it next opens.
    func close() {
        isOpen = false
        for bubble in bubbles.values { bubble.vanish(animated: false, motion: false) }
    }

    /// At rest with `selection` highlighted and nothing moving (snapshots).
    func settle(selection: [String]) {
        isOpen = false
        self.selection = selection
        retarget(animated: false)
    }

    /// The bubble for `role`, if it has been made.
    func bubble(_ role: RadialBubble.Role) -> RadialBubble? { bubbles[role] }

    /// The bubbles showing.
    var showingBubbles: [RadialBubble] { bubbles.values.filter(\.isShowing) }

    /// A rect in the wheel's coordinates (its centre at the origin) in the view's.
    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: origin.x, dy: origin.y) }

    /// A view's frame in the wheel's coordinates.
    func wheelFrame(of view: NSView) -> CGRect { view.frame.offsetBy(dx: -origin.x, dy: -origin.y) }

    // MARK: What shows

    /// How each petal showing looks with `selection` highlighted, and the size it shows at.
    private func emphasis(of path: [String]) -> (RadialBubble.Emphasis, CGFloat) {
        if path == selection { return (.lit, layout.word(path)?.grow ?? 1) }
        if !selection.isEmpty, selection.starts(with: path) { return (.path, 1) }
        // Beside the petal on the path: it steps back, the more so once the path goes on past it.
        let parent = Array(path.dropLast())
        if selection.count > parent.count, selection.starts(with: parent) {
            return (selection.count > path.count ? .beyond : .receded, 1)
        }
        return (.rest, 1)
    }

    private func retarget(animated: Bool) {
        guard !layout.top.isEmpty else { return }
        let showingPaths = layout.showing(open: layout.openBranch(selection))
        let showing = Set(showingPaths)
        let animate = animated && isOpen
        // What pops out now staggers outward from the innermost of it: ring 0 is the centre.
        let appearing = showingPaths.filter { bubbles[.word(.node($0))]?.isShowing != true }
        let base = appearing.map(\.count).min() ?? 1
        func ring(_ path: [String]) -> Int {
            var row = 0
            if let node = RadialMenu.node(at: path, in: tree), case .loadout = node.kind { row = node.row }
            return 1 + path.count - base + row
        }
        var outermost = 0
        for word in layout.words {
            guard let path = word.role.path else { continue }
            let role = RadialBubble.Role.word(word.role)
            if showing.contains(path) {
                let bubble = bubbles[role] ?? make(word)
                let (emphasis, scale) = emphasis(of: path)
                if bubble.isShowing {
                    bubble.style(emphasis, scale: scale, animated: animate, motion: motion)
                } else {
                    let r = ring(path)
                    outermost = max(outermost, r)
                    bubble.appear(emphasis: emphasis, scale: scale, delay: animate ? Double(r) * RadialMotion.stagger : nil,
                                  motion: motion)
                }
            } else if let bubble = bubbles[role], bubble.isShowing {
                bubble.vanish(animated: animate, motion: motion)
            }
        }
        styleHub(animated: animate)
        refreshHint(delay: animate ? Double(outermost + 1) * RadialMotion.stagger : nil)
    }

    // MARK: Bubbles

    private var backingPixels: CGFloat { window?.backingScaleFactor ?? 2 }

    /// A petal's bubble, its picture drawn.
    private func make(_ word: RadialLayout.Word) -> RadialBubble {
        let s = layout.scale
        let frame = RadialGlass.bubble(around: word.frame, scale: s)
        let bubble = RadialBubble(role: .word(word.role), frame: local(frame), scale: s)
        bubble.pivot = CGPoint(x: word.anchor.x - frame.minX, y: word.anchor.y - frame.minY)
        addSubview(bubble)
        bubbles[bubble.role] = bubble
        if pixels == 0 { pixels = backingPixels }
        draw(word, in: bubble)
        return bubble
    }

    private func draw(_ word: RadialLayout.Word, in bubble: RadialBubble) {
        let frame = wheelFrame(of: bubble)
        let box = word.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let icons = word.role.path.flatMap { RadialMenu.node(at: $0, in: tree) }.map { Array($0.icons.prefix(word.icons)) } ?? []
        let image = Self.picture(size: frame.size, pixels: pixels, scale: layout.scale) { ctx in
            Self.words(PreparedText(word.fit, style: word.style), icons: icons, in: box, scale: self.layout.scale, ctx: ctx)
        }
        bubble.show(image, in: CGRect(origin: .zero, size: frame.size), pixels: pixels)
        wordRenders += 1
    }

    /// The centre's disc: "Esc" at rest, "Cancel" while nothing is highlighted, and each top
    /// petal's digit by the dead zone's edge, brighter while its petal is on the path.
    private func styleHub(animated: Bool) {
        let bubble = bubbles[.word(.centre)] ?? makeHub()
        let cancels = selection.isEmpty
        if !bubble.isShowing {
            bubble.appear(emphasis: .rest, scale: 1, delay: animated ? 0 : nil, motion: motion)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(RadialMotion.restyle)
        CATransaction.setDisableActions(!animated)
        bubble.picture("esc")?.opacity = cancels ? 0 : 0.7
        bubble.picture("cancel")?.opacity = cancels ? 1 : 0
        let lit = layout.top.map { !selection.isEmpty && selection.first == $0 }
        for (i, on) in lit.enumerated() {
            let other = lit.contains(true) && !on
            bubble.picture("digit \(i)")?.opacity = on ? 0.95 : other ? 0.35 : 0.55
        }
        CATransaction.commit()
    }

    private func makeHub() -> RadialBubble {
        let s = layout.scale
        let disc = RadialGlass.hub(in: layout)
        let bubble = RadialBubble(role: .word(.centre), frame: local(disc), scale: s)
        bubble.pivot = CGPoint(x: disc.width / 2, y: disc.height / 2)
        addSubview(bubble)
        bubbles[bubble.role] = bubble
        if pixels == 0 { pixels = backingPixels }
        drawHub(bubble)
        return bubble
    }

    private func drawHub(_ bubble: RadialBubble) {
        let s = layout.scale
        let disc = wheelFrame(of: bubble)
        for word in layout.words {
            switch word.role {
            case .centre:
                let escape = TextFit(lines: ["Esc"], size: word.style.preferred - 1.5 * s, truncated: false)
                for (name, fit) in [("esc", escape), ("cancel", word.fit)] {
                    let text = PreparedText(fit, style: word.style)
                    let box = CGRect(x: -text.width / 2, y: -text.height / 2, width: text.width, height: text.height)
                    picture(of: text, box: box, name: name, in: bubble, disc: disc)
                }
            case .digit(let i):
                picture(of: PreparedText(word.fit, style: word.style), box: word.frame, name: "digit \(i)", in: bubble, disc: disc)
            case .node:
                continue
            }
        }
    }

    /// `text` centred in `box` (wheel coordinates) as one of the centre's pictures.
    private func picture(of text: PreparedText, box: CGRect, name: String, in bubble: RadialBubble, disc: CGRect) {
        let s = layout.scale
        let rect = box.insetBy(dx: -3 * s, dy: -3 * s).integral
        let image = Self.picture(size: rect.size, pixels: pixels, scale: s) { ctx in
            Self.words(text, icons: [], in: box.offsetBy(dx: -rect.minX, dy: -rect.minY), scale: s, ctx: ctx)
        }
        bubble.show(image, in: rect.offsetBy(dx: -disc.minX, dy: -disc.minY), pixels: pixels, name: name)
        wordRenders += 1
    }

    /// The line under the wheel: what releasing does, fitted to the hint's zone, in its own
    /// bubble just around its words. It comes in after `delay` (nil: at once) when it is not
    /// showing; a new line while it shows replaces the old at once.
    private func refreshHint(delay: TimeInterval? = nil) {
        guard !layout.top.isEmpty else { return }
        let text = RadialMenu.hint(for: selection, in: tree)
        let zone = layout.hintZone(open: selection)
        let s = layout.scale
        if hint?.text != text || hint?.zone != zone || bubbles[.hint] == nil {
            hint = (text, zone)
            let fit = TextFit.fit(text, style: layout.hintStyle, width: zone.width)
            let prepared = PreparedText(fit, style: layout.hintStyle)
            let box = CGRect(x: zone.midX - prepared.width / 2, y: zone.maxY - prepared.height, width: prepared.width, height: prepared.height)
            let frame = RadialGlass.bubble(around: box, scale: s).integral
            let bubble = bubbles[.hint] ?? {
                let made = RadialBubble(role: .hint, frame: local(frame), scale: s)
                addSubview(made)
                bubbles[.hint] = made
                return made
            }()
            bubble.pivot = CGPoint(x: frame.width / 2, y: frame.height)
            bubble.place(local(frame), scale: s)
            if pixels == 0 { pixels = backingPixels }
            let image = Self.picture(size: frame.size, pixels: pixels, scale: s) { ctx in
                Self.words(prepared, icons: [], in: box.offsetBy(dx: -frame.minX, dy: -frame.minY), scale: s, ctx: ctx)
            }
            bubble.show(image, in: CGRect(origin: .zero, size: frame.size), pixels: pixels, name: "hint")
        }
        guard let bubble = bubbles[.hint], !bubble.isShowing else { return }
        bubble.appear(emphasis: .rest, scale: 1, delay: delay, motion: motion)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard window != nil, backingPixels != pixels, !bubbles.isEmpty else { return }
        pixels = backingPixels
        // Every picture again at the new scale.
        for (role, bubble) in bubbles {
            bubble.clearPictures()
            switch role {
            case .word(.centre): drawHub(bubble)
            case .word(let role): if let word = layout.word(role) { draw(word, in: bubble) }
            case .hint: hint = nil
            }
        }
        refreshHint()
        styleHub(animated: false)
        retarget(animated: false)
    }

    // MARK: Drawing

    /// A picture `size` points big at `pixels` per point, drawn by `body` in points, y up.
    private static func picture(size: CGSize, pixels: CGFloat, scale s: CGFloat, _ body: (CGContext) -> Void) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: max(1, Int((size.width * pixels).rounded(.up))),
                                  height: max(1, Int((size.height * pixels).rounded(.up))), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return empty }
        ctx.scaleBy(x: pixels, y: pixels)
        body(ctx)
        return ctx.makeImage() ?? empty
    }

    private static let empty: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    /// `text` in white, its lines centred across `box` from its top, and `icons` in a row
    /// centred at its foot, with a soft shadow that keeps them crisp over the gloss.
    private static func words(_ text: PreparedText, icons: [NSImage], in box: CGRect, scale s: CGFloat, ctx: CGContext) {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: 2 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        text.draw(in: CGRect(x: box.minX, y: box.maxY - text.height, width: box.width, height: text.height), align: 0.5, in: ctx)
        guard !icons.isEmpty else { return }
        let side = RadialLayout.iconSize * s, spacing = RadialLayout.iconSpacing * s
        let row = CGFloat(icons.count) * side + CGFloat(icons.count - 1) * spacing
        let x = box.midX - row / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (k, icon) in icons.enumerated() {
            (icon.isTemplate ? white(icon) : icon).draw(in: CGRect(x: x + CGFloat(k) * (side + spacing), y: box.minY, width: side, height: side))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A template symbol in white.
    private static func white(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
