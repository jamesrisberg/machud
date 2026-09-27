import AppKit

/// Full-screen, click-through window that draws the active layout while dragging.
final class OverlayController {
    private var window: NSWindow?
    private let view = OverlayView()

    func show(on screen: NSScreen) {
        let w = window ?? makeWindow()
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        view.screenOrigin = screen.frame.origin
        w.orderFrontRegardless()
    }

    func update(regions: [CGRect], hits: [CGRect], names: [String], target: Int?, title: String, triggerSymbol: String) {
        view.triggerSymbol = triggerSymbol
        view.regions = regions
        view.hits = hits
        view.names = names
        view.target = target
        view.title = title
        view.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = view
        window = w
        return w
    }
}

final class OverlayView: NSView {
    var screenOrigin: CGPoint = .zero
    var regions: [CGRect] = []   // Cocoa screen coords
    var hits: [CGRect] = []      // Cocoa screen coords
    var names: [String] = []
    var target: Int?
    var title: String = ""
    var triggerSymbol: String = "⇧"

    override var isFlipped: Bool { false }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Non-target regions: faint outline.
        for (i, r) in regions.enumerated() where i != target {
            let path = NSBezierPath(roundedRect: local(r).insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.06).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        // Hit zones that differ from their region: small dashed marker so the
        // user can find them.
        for (i, h) in hits.enumerated() where i < regions.count && h != regions[i] {
            let path = NSBezierPath(roundedRect: local(h).insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.lineWidth = 1
            (i == target ? accent : NSColor.white.withAlphaComponent(0.4)).setStroke()
            path.stroke()
        }

        // Target: filled + bold outline + name.
        if let t = target, regions.indices.contains(t) {
            let r = local(regions[t]).insetBy(dx: 2, dy: 2)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.28).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 3
            path.stroke()
            if names.indices.contains(t) {
                drawPill(names[t], centeredAt: CGPoint(x: r.midX, y: r.midY), size: 18)
            }
        }

        // Layout name + hint at the top.
        var hint = "\(title)   ·   Tab: next layout   ·   Esc: cancel"
        if !triggerSymbol.isEmpty { hint += "   ·   release \(triggerSymbol) to drop normally" }
        drawPill(hint, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 56), size: 13)
    }

    private func drawPill(_ text: String, centeredAt c: CGPoint, size: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let s = str.size()
        let pad = CGSize(width: 14, height: 8)
        let rect = CGRect(x: c.x - s.width / 2 - pad.width, y: c.y - s.height / 2 - pad.height,
                          width: s.width + pad.width * 2, height: s.height + pad.height * 2)
        let bg = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bg.fill()
        str.draw(at: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2))
    }
}
