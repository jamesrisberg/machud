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

        for (i, r) in regions.enumerated() where i != target { GridDrawing.faintRegion(local(r)) }

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

/// How the layout grid and its regions look, shared by the layout editor, the drag overlay and
/// the widget edit overlay so every grid in MacHUD looks the same.
enum GridDrawing {
    /// The editor's dimmed backdrop: the whole screen, a little darker over the visible frame.
    static func backdrop(_ bounds: CGRect, visible: CGRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.2).setFill()
        visible.fill()
    }

    /// The grid lines over `visible`: faint minor lines, and brighter major ones dividing it
    /// into about 12 across and 6 down.
    static func lines(_ grid: GridSize, in visible: CGRect) {
        let cols = max(1, grid.cols), rows = max(1, grid.rows)
        let minor = NSBezierPath(), major = NSBezierPath()
        let majorEveryC = max(1, cols / 12), majorEveryR = max(1, rows / 6)
        for c in 0...cols {
            let x = (visible.minX + CGFloat(c) / CGFloat(cols) * visible.width).rounded() + 0.5
            let p = (c % majorEveryC == 0) ? major : minor
            p.move(to: CGPoint(x: x, y: visible.minY)); p.line(to: CGPoint(x: x, y: visible.maxY))
        }
        for r in 0...rows {
            let y = (visible.minY + CGFloat(r) / CGFloat(rows) * visible.height).rounded() + 0.5
            let p = (r % majorEveryR == 0) ? major : minor
            p.move(to: CGPoint(x: visible.minX, y: y)); p.line(to: CGPoint(x: visible.maxX, y: y))
        }
        NSColor.white.withAlphaComponent(0.06).setStroke(); minor.lineWidth = 1; minor.stroke()
        NSColor.white.withAlphaComponent(0.16).setStroke(); major.lineWidth = 1; major.stroke()
    }

    /// A region that is not the one being worked on: a faint outline.
    static func faintRegion(_ r: CGRect) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.06).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}
