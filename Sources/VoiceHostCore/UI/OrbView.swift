import AppKit
import HUDKit

/// Draws the orb, the waveform body and everything between, from a scene, the animator's
/// values and the level history. Takes the orb's mouse input: click, right-click menu, hover.
/// It is also the orb's accessibility element (a button whose value is the status).
final class OrbView: NSView {
    var scene = OrbScene(hidden: false, form: .orb, tint: .resting, motion: .none, accessibilityStatus: "Ready") {
        didSet { if scene != oldValue { needsDisplay = true; updateAccessibility() } }
    }
    var animator = OrbAnimator() { didSet { needsDisplay = true } }
    var history = LevelHistory() { didSet { if scene.motion == .bars { needsDisplay = true } } }
    var geometry: HUDNotchGeometry { didSet { needsDisplay = true } }
    var reduceMotion = false { didSet { needsDisplay = true } }

    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Builds the right-click menu.
    var makeMenu: (() -> NSMenu)?

    init(frame: NSRect = .zero, geometry: HUDNotchGeometry) {
        self.geometry = geometry
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Voice assistant")
        setAccessibilityHelp("Click to talk to the agent. Right-click for Mute and Dismiss.")
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The shape's rect in this view: centered horizontally, `topOffset` below the top edge,
    /// scaled about its center by the pulse.
    func shapeRect() -> (rect: CGRect, shape: OrbShape) {
        let shape = OrbLayout.shape(stretch: animator.stretch, geometry: geometry)
        var size = shape.size
        let scale = pulseScale()
        size.width *= scale
        size.height *= scale
        let center = CGPoint(x: bounds.midX, y: shape.topOffset + shape.size.height / 2)
        return (CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height), shape)
    }

    private func pulseScale() -> CGFloat {
        guard scene.motion == .pulse, !reduceMotion else { return 1 }
        return 1 + OrbLayout.pulseMax * animator.level * (1 - animator.stretch)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (rect, shape) = shapeRect()
        let scale = rect.width / max(shape.size.width, 1)
        let path = OrbLayout.path(in: rect, topRadius: shape.topRadius * scale, bottomRadius: shape.bottomRadius * scale)
        let t = animator.stretch
        let palette = OrbPalette.for(scene.tint)

        ctx.saveGState()
        ctx.setAlpha(scene.muted && scene.form == .orb ? 0.55 : 1)

        // Glow behind the orb: the level under Reduce Motion, the breathe, the approval ask.
        let glow = glowAmount()
        if glow > 0, t < 1 {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 10 * glow + 2, color: palette.glow.withAlphaComponent(0.85 * glow * (1 - t)).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(palette.edge.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Body: the orb's radial gradient, fading into the waveform's black as it stretches.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(rect)
        if t < 1 {
            ctx.setAlpha(1 - t)
            let colors = [palette.core.cgColor, palette.edge.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                let c = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY - rect.height * 0.16)
                ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                       endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: max(rect.width, rect.height) * 0.62,
                                       options: [.drawsAfterEndLocation])
            }
            // Soft specular highlight near the top: a plain glass orb, no face. Sized by the
            // height so it stays round while the orb stretches, and gone before the body forms.
            let side = rect.height
            let hi = CGRect(x: rect.midX - side * 0.28, y: rect.minY + side * 0.1, width: side * 0.4, height: side * 0.26)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.22 * max(0, 1 - t * 2.5)).cgColor)
            ctx.fillEllipse(in: hi)
        }
        ctx.restoreGState()

        // Hairline rim on the orb (none on the body, which joins the notch).
        if t < 1 {
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22 * (1 - t)).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
        }

        switch scene.motion {
        case .spin: drawSpin(ctx, rect: rect, color: palette.glow)
        case .bars where t > 0.55: drawBars(ctx, rect: rect, alpha: (t - 0.55) / 0.45)
        case .spinner where t > 0.55: drawSpinner(ctx, rect: rect, alpha: (t - 0.55) / 0.45)
        default: break
        }
        ctx.restoreGState()
    }

    private func glowAmount() -> CGFloat {
        switch scene.motion {
        case .pulse: return reduceMotion ? 0.3 + 0.7 * animator.level : 0.35
        case .breathe: return reduceMotion ? 0.6 : 0.45 + 0.35 * CGFloat(sin(animator.phase * 2.2))
        case .spin: return 0.35
        default: return scene.tint == .failed ? 0.8 : 0
        }
    }

    /// A short bright arc circling the rim: the working motion.
    private func drawSpin(_ ctx: CGContext, rect: CGRect, color: NSColor) {
        let radius = min(rect.width, rect.height) / 2 - 1.25
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = reduceMotion ? -CGFloat.pi / 2 : CGFloat(animator.phase * 4.2)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.75)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(reduceMotion ? 0.45 : 0.85).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .pi * 0.55, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// SpeakFree's recording group: record dot plus level bars, centered in the body.
    private func drawBars(_ ctx: CGContext, rect: CGRect, alpha: CGFloat) {
        let heights = OrbLayout.barHeights(history.values)
        let barsWidth = CGFloat(heights.count) * OrbLayout.barWidth + CGFloat(max(heights.count - 1, 0)) * OrbLayout.barGap
        let groupWidth = OrbLayout.recordDotRadius * 2 + OrbLayout.recordDotGap + barsWidth
        var x = rect.midX - groupWidth / 2
        let midY = rect.midY
        let blink = reduceMotion ? 1 : 0.75 + 0.25 * CGFloat(sin(animator.phase * 9))
        ctx.setFillColor(NSColor(red: 1, green: 0.23, blue: 0.19, alpha: alpha * blink).cgColor)
        let r = OrbLayout.recordDotRadius
        ctx.fillEllipse(in: CGRect(x: x, y: midY - r, width: r * 2, height: r * 2))
        x += r * 2 + OrbLayout.recordDotGap
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85 * alpha).cgColor)
        for h in heights {
            let bar = CGRect(x: x, y: midY - h / 2, width: OrbLayout.barWidth, height: h)
            let radius = min(OrbLayout.barWidth / 2, h / 2)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
            x += OrbLayout.barWidth + OrbLayout.barGap
        }
    }

    /// SpeakFree's eight-spoke transcribing spinner.
    private func drawSpinner(_ ctx: CGContext, rect: CGRect, alpha: CGFloat) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let spokes = 8
        let lead = reduceMotion ? 0 : Int(animator.phase * 10) % spokes
        ctx.setLineWidth(2.25)
        ctx.setLineCap(.round)
        for i in 0..<spokes {
            let angle = CGFloat(i) * (.pi / 4) - .pi / 2
            let behind = (lead - i + spokes) % spokes
            let a = CGFloat(spokes - behind) / CGFloat(spokes)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent((0.12 + 0.78 * a) * alpha).cgColor)
            ctx.move(to: CGPoint(x: center.x + cos(angle) * 5, y: center.y + sin(angle) * 5))
            ctx.addLine(to: CGPoint(x: center.x + cos(angle) * 9, y: center.y + sin(angle) * 9))
            ctx.strokePath()
        }
    }

    // MARK: Input

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return shapeRect().rect.insetBy(dx: -3, dy: -3).contains(local) ? self : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: Accessibility

    private func updateAccessibility() {
        setAccessibilityValue(scene.accessibilityStatus)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.midX, y: bounds.maxY), in: self)
        return true
    }
}

/// Colors per tint: `core` at the orb's highlight, `edge` at its rim, `glow` around it.
struct OrbPalette: Equatable {
    var core: NSColor
    var edge: NSColor
    var glow: NSColor

    static func `for`(_ tint: OrbTint) -> OrbPalette {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch tint {
        case .resting: return OrbPalette(core: rgb(0.36, 0.37, 0.41), edge: rgb(0.07, 0.07, 0.09), glow: rgb(0.6, 0.6, 0.65))
        case .muted: return OrbPalette(core: rgb(0.22, 0.22, 0.23), edge: rgb(0.06, 0.06, 0.06), glow: rgb(0.4, 0.4, 0.4))
        case .dictation: return OrbPalette(core: rgb(0.2, 0.2, 0.2), edge: rgb(0, 0, 0), glow: rgb(1, 0.3, 0.25))
        case .agent: return OrbPalette(core: rgb(0.45, 0.93, 1.0), edge: rgb(0.02, 0.36, 0.5), glow: rgb(0.3, 0.85, 1.0))
        case .working: return OrbPalette(core: rgb(0.72, 0.6, 1.0), edge: rgb(0.2, 0.1, 0.45), glow: rgb(0.62, 0.48, 1.0))
        case .approval: return OrbPalette(core: rgb(1.0, 0.82, 0.4), edge: rgb(0.55, 0.3, 0.02), glow: rgb(1.0, 0.72, 0.2))
        case .speaking: return OrbPalette(core: rgb(0.6, 1.0, 0.85), edge: rgb(0.03, 0.4, 0.34), glow: rgb(0.35, 0.95, 0.75))
        case .failed: return OrbPalette(core: rgb(1.0, 0.45, 0.42), edge: rgb(0.5, 0.05, 0.07), glow: rgb(1.0, 0.25, 0.22))
        }
    }
}
