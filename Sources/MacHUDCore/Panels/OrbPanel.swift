import AppKit
import HUDKit

/// The small glass orb that stands in for the windows parked on one screen edge. Hover
/// it to reveal them, click to pin them revealed, drag it to move it. Non-activating, on
/// every Space, and never a placement target itself.
@MainActor
final class OrbPanel {
    static let diameter: CGFloat = 44
    /// Room around the orb for the count badge.
    static let margin: CGFloat = 5
    static var windowSide: CGFloat { diameter + 2 * margin }

    let edge: HUDEdge
    var onClick: (() -> Void)?
    /// Called with the new window origin when a drag ends.
    var onMoved: ((CGPoint) -> Void)?

    private var window: HUDPanelWindow?
    private let view: OrbView

    init(edge: HUDEdge) {
        self.edge = edge
        view = OrbView(frame: CGRect(x: 0, y: 0, width: Self.windowSide, height: Self.windowSide), edge: edge)
        view.onClick = { [weak self] in self?.onClick?() }
        view.onMoved = { [weak self] in
            guard let self, let w = self.window else { return }
            self.onMoved?(w.frame.origin)
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// The orb's circle in screen coordinates (what hovering is measured against).
    var orbFrame: CGRect {
        guard let w = window else { return .null }
        return w.frame.insetBy(dx: Self.margin, dy: Self.margin)
    }

    var count = 0 { didSet { view.count = count } }
    var revealed = false { didSet { view.revealed = revealed } }

    /// `origin` is where the orb's circle goes (the window adds the badge margin).
    func show(at origin: CGPoint) {
        let w = window ?? makeWindow()
        w.setFrameOrigin(CGPoint(x: origin.x - Self.margin, y: origin.y - Self.margin))
        if !w.isVisible { HUDAnimation.fadeIn(w) }
    }

    func hide() {
        guard let w = window, w.isVisible else { return }
        HUDAnimation.fadeOut(w)
    }

    /// Origin of the circle (not the window), for persisting.
    var origin: CGPoint? {
        window.map { CGPoint(x: $0.frame.minX + Self.margin, y: $0.frame.minY + Self.margin) }
    }

    private func makeWindow() -> HUDPanelWindow {
        let w = HUDPanelWindow(contentRect: CGRect(x: 0, y: 0, width: Self.windowSide, height: Self.windowSide),
                               keyable: false, level: .floating)
        w.hasShadow = false
        w.contentView = view
        w.title = "MacHUD Orb"
        window = w
        return w
    }
}

/// Glass circle, edge glyph and count badge; turns mouse input into click or drag.
@MainActor
private final class OrbView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var count = 0 { didSet { syncBadge() } }
    var revealed = false { didSet { glyph.contentTintColor = tint } }

    private let glass: HUDGlassView
    private let glyph = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var dragged = false

    init(frame: CGRect, edge: HUDEdge) {
        let m = OrbPanel.margin, d = OrbPanel.diameter
        glass = HUDGlassView(frame: CGRect(x: m, y: m, width: d, height: d),
                             style: HUDGlassView.Style(cornerRadius: d / 2, borderWidth: 0.5, borderAlpha: 0.3))
        super.init(frame: frame)
        addSubview(glass)

        let symbol: String
        switch edge {
        case .left: symbol = "chevron.compact.right"
        case .right: symbol = "chevron.compact.left"
        case .top: symbol = "chevron.compact.down"
        case .bottom: symbol = "chevron.compact.up"
        }
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Parked windows")?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        glyph.contentTintColor = tint
        glyph.frame = CGRect(x: m, y: m, width: d, height: d)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)

        badge.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 8
        badge.frame = CGRect(x: frame.width - 18, y: frame.height - 17, width: 18, height: 16)
        addSubview(badge)
        syncBadge()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var tint: NSColor { NSColor.white.withAlphaComponent(revealed ? 0.95 : 0.6) }

    private func syncBadge() {
        badge.stringValue = "\(count)"
        badge.isHidden = count == 0
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = (NSEvent.mouseLocation, window?.frame.origin ?? .zero)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
        if !dragged, hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(CGPoint(x: start.origin.x + dx, y: start.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragged = false }
        if dragged { onMoved?() } else { onClick?() }
    }
}
