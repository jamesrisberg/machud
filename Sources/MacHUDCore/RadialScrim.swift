import AppKit
import HUDKit

/// A dark veil over the whole screen the wheel opens on, so its bubbles stand out from a busy
/// desktop while the desktop stays recognisable. It never takes the mouse, focus or a key, shows
/// on every Space with the wheel, fades in as the wheel opens and out fast as it goes.
///
/// It dims the windows, not the HUD: the tool dock (`.floating` + 1), the raised desktop widgets
/// and the siblings' panels (`.floating`, in their own apps) read clearly over it while the
/// wheel's bubbles (`.screenSaver`) stay above them all. The windows are dimmed by `window`, at
/// `veilLevel`, over the screen's visible frame; the menu bar and the system Dock, which sit
/// above `.floating`, by `band`, over the rest of the screen at the wheel's level, just under the
/// wheel. Separate levels rather than ordering within one keep it so whichever app orders its
/// window in last. Neither is the wheel's window: the window server blurs that one wherever it
/// draws (`HUDWindowBlur`), so a veil there would blur the whole screen.
@MainActor
final class RadialScrim {
    /// Black at this opacity over the screen. The bubbles' blur is of what lies under the wheel's
    /// window, the veil included, so it darkens their glass on a bright desktop too.
    static let darkness: CGFloat = 0.4
    static let fadeIn: TimeInterval = 0.2
    static let fadeOut: TimeInterval = 0.12
    /// Just under `.floating`: above every app's ordinary windows, under the HUD.
    static let veilLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    /// Over the visible frame, at `veilLevel`.
    private(set) var window: NSWindow?
    /// Over the menu bar and the system Dock (the screen less its visible frame), just under the wheel.
    private(set) var band: NSWindow?
    /// Between `show` and `hide`: it is there or fading in (a hidden veil may still be fading out).
    private(set) var isShowing = false

    /// The veil's windows, made once.
    @discardableResult
    func makeWindows() -> (veil: NSWindow, band: NSWindow) {
        if let window, let band { return (window, band) }
        let veil = Self.makeWindow(id: "machud.wheel.scrim", level: Self.veilLevel)
        let fill = NSView(frame: .zero)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.darkness).cgColor
        veil.contentView = fill
        let edge = Self.makeWindow(id: "machud.wheel.scrim.band", level: .screenSaver)
        edge.contentView = RadialScrimBand(frame: .zero)
        window = veil
        band = edge
        return (veil, edge)
    }

    private static func makeWindow(id: String, level: NSWindow.Level) -> NSWindow {
        let w = RadialScrimPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = level
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.alphaValue = 0
        return w
    }

    /// Over `frame` (a screen, in screen coordinates) whose visible frame is `visible`, the band
    /// just under `wheel`, fading in.
    func show(on frame: CGRect, visible: CGRect, below wheel: NSWindow) {
        let (veil, edge) = makeWindows()
        isShowing = true
        let inner = visible.intersection(frame).isNull ? frame : visible.intersection(frame)
        for (w, rect) in [(veil, inner), (edge, frame)] {
            if !w.isVisible { w.alphaValue = 0 }
            if w.frame != rect { w.setFrame(rect, display: false) }
        }
        (edge.contentView as? RadialScrimBand)?.hole = inner.offsetBy(dx: -frame.minX, dy: -frame.minY)
        veil.orderFrontRegardless()
        edge.order(.below, relativeTo: wheel.windowNumber)
        HUDAnimation.fadeIn(veil, duration: Self.fadeIn)
        HUDAnimation.fadeIn(edge, duration: Self.fadeIn)
    }

    /// Fades out fast and goes; a `show` before it has gone brings it back.
    func hide() {
        guard isShowing else { return }
        isShowing = false
        for w in [window, band].compactMap({ $0 }) { HUDAnimation.fadeOut(w, duration: Self.fadeOut) }
    }
}

/// The band's veil: the screen less `hole` (the visible frame, which the other window veils).
final class RadialScrimBand: NSView {
    var hole: CGRect = .zero { didSet { needsLayout = true } }
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = NSColor.black.withAlphaComponent(RadialScrim.darkness).cgColor
        shape.fillRule = .evenOdd
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = Self.path(bounds: bounds, hole: hole)
        CATransaction.commit()
    }

    /// `bounds` less `hole`.
    static func path(bounds: CGRect, hole: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        if !hole.isEmpty { path.addRect(hole.intersection(bounds)) }
        return path
    }
}

/// The veil's windows: never key or main.
private final class RadialScrimPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
