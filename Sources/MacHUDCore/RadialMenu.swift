import AppKit
import HUDKit

/// Where an offset from the wheel's centre points: which wedge, and which ring.
/// Pure maths, no AppKit state, so it can be unit tested.
struct RadialGeometry: Equatable {
    /// The rings, inside out. What each one does depends on the wedge (`RadialMenu.ringLabel`):
    /// a loadout previews / applies / clears then applies; capture captures this screen / all
    /// screens / opens the editor on a new layout; park parks / restores.
    enum Ring: String, Equatable, CaseIterable {
        case inner, middle, outer
        var position: Int { Self.allCases.firstIndex(of: self)! }
    }

    enum Selection: Equatable {
        case cancel
        case wedge(index: Int, ring: Ring)

        var index: Int? { if case .wedge(let i, _) = self { return i } else { return nil } }
        var ring: Ring? { if case .wedge(_, let r) = self { return r } else { return nil } }
    }

    static let fullTurn = 2 * Double.pi

    var count: Int
    /// How many rings each wedge has (1...3), by wedge index; wedges not listed have three.
    /// A wedge's last ring reaches the outer edge and continues past it.
    var ringCounts: [Int] = []
    /// Inside this radius the wheel is cancelled.
    var deadZone: CGFloat = 46
    /// Outer radius of the inner ring.
    var innerEdge: CGFloat = 100
    /// Outer radius of the middle ring.
    var middleEdge: CGFloat = 148
    /// Outer edge of the wheel; past it the last ring simply continues.
    var outerEdge: CGFloat = 196

    init(count: Int, ringCounts: [Int] = []) {
        self.count = count
        self.ringCounts = ringCounts
    }

    var wedgeAngle: Double { count > 0 ? Self.fullTurn / Double(count) : Self.fullTurn }

    /// Angle of `offset` measured clockwise from straight up, in `0..<2π`.
    static func angle(of offset: CGPoint) -> Double {
        let a = atan2(Double(offset.x), Double(offset.y))
        return a < 0 ? a + fullTurn : a
    }

    static func radius(of offset: CGPoint) -> CGFloat { hypot(offset.x, offset.y) }

    func index(atAngle angle: Double) -> Int {
        guard count > 0 else { return 0 }
        let w = wedgeAngle
        var shifted = (angle + w / 2).truncatingRemainder(dividingBy: Self.fullTurn)
        if shifted < 0 { shifted += Self.fullTurn }
        return max(0, min(count - 1, Int(shifted / w)))
    }

    func centerAngle(of index: Int) -> Double { wedgeAngle * Double(index) }
    func startAngle(of index: Int) -> Double { centerAngle(of: index) - wedgeAngle / 2 }
    func endAngle(of index: Int) -> Double { centerAngle(of: index) + wedgeAngle / 2 }

    /// The ring at `radius` on a three-ring wedge.
    func ring(radius: CGFloat) -> Ring { radius >= middleEdge ? .outer : radius >= innerEdge ? .middle : .inner }

    func ringCount(of index: Int) -> Int {
        ringCounts.indices.contains(index) ? max(1, min(Ring.allCases.count, ringCounts[index])) : Ring.allCases.count
    }

    /// The ring at `radius` on wedge `index`: a wedge with fewer rings keeps its last one.
    func ring(radius: CGFloat, of index: Int) -> Ring {
        Ring.allCases[min(ring(radius: radius).position, ringCount(of: index) - 1)]
    }

    func lastRing(of index: Int) -> Ring { Ring.allCases[ringCount(of: index) - 1] }

    /// The rings wedge `index` has, inside out.
    func rings(of index: Int) -> [Ring] { Array(Ring.allCases.prefix(ringCount(of: index))) }

    /// Radial extent of `ring` on wedge `index`; the wedge's last ring runs to the outer edge.
    func band(_ ring: Ring, of index: Int) -> (r0: CGFloat, r1: CGFloat) {
        let edges = [deadZone, innerEdge, middleEdge, outerEdge]
        let last = ring.position == ringCount(of: index) - 1
        return (edges[ring.position], last ? outerEdge : edges[ring.position + 1])
    }

    /// `shift` forces the wedge's last ring, the keyboard alternative to dragging further out.
    func selection(at offset: CGPoint, shift: Bool = false) -> Selection {
        guard count > 0 else { return .cancel }
        let r = Self.radius(of: offset)
        guard r >= deadZone else { return .cancel }
        let i = index(atAngle: Self.angle(of: offset))
        return .wedge(index: i, ring: shift ? lastRing(of: i) : ring(radius: r, of: i))
    }
}

// MARK: - Controller

/// Call-of-Duty style loadout wheel: held open by a hotkey, centred on the cursor,
/// click-through, drawn in jelly glass. Release applies the highlighted wedge.
@MainActor
final class RadialMenu {
    struct Wedge {
        enum Kind: Equatable { case loadout(String), capture, park, widgets }
        var title: String
        var subtitle: String = ""
        var icons: [NSImage] = []
        var kind: Kind
        var hotkey: HotKey?
    }

    enum Outcome {
        case cancelled
        /// A loadout wedge's middle ring (`clear` false) or outer ring (`clear` true).
        case apply(loadout: String, clear: Bool)
        /// Show what applying a loadout would do (nil: the active one). A loadout wedge's
        /// inner ring, or P over any wedge.
        case preview(loadout: String?)
        /// The capture wedge's inner ring: this screen; middle ring: every display.
        case capture(allScreens: Bool)
        /// The capture wedge's outer ring: open the editor on a fresh layout to draw.
        case drawLayout
        /// The park wedge's inner ring: park the focused window. Its outer ring: bring
        /// every parked window back.
        case park(restore: Bool)
        /// The widgets wedge's inner ring: reveal (or lower) the widgets. Its outer ring: edit them.
        case widgets(edit: Bool)
    }

    /// How many rings a wedge has: park and widgets have two, the others three.
    static func ringCount(for kind: Wedge.Kind) -> Int {
        switch kind {
        case .park, .widgets: return 2
        case .loadout, .capture: return 3
        }
    }

    /// What each ring of a wedge does.
    static func ringLabel(_ ring: RadialGeometry.Ring, for kind: Wedge.Kind) -> String {
        switch (kind, ring) {
        case (.loadout, .inner): return "Preview"
        case (.loadout, .middle): return "Apply"
        case (.loadout, .outer): return "Clear this screen + Apply"
        case (.capture, .inner): return "Capture this screen as a loadout"
        case (.capture, .middle): return "Capture all screens as a loadout"
        case (.capture, .outer): return "Draw a new layout"
        case (.park, .inner): return "Park front window"
        case (.park, .middle), (.park, .outer): return "Restore parked"
        case (.widgets, .inner): return "Reveal widgets"
        case (.widgets, .middle), (.widgets, .outer): return "Edit widgets"
        }
    }

    /// Applied when the hotkey is released.
    var onCommit: ((Outcome) -> Void)?
    /// False when the menu's own hotkey already uses shift, so it cannot double as "clear".
    var shiftSelectsOuter = true
    /// Called whenever a visible wheel goes away, however it was dismissed.
    var onDismiss: (() -> Void)?

    private(set) var wedges: [Wedge] = []
    private(set) var geometry = RadialGeometry(count: 0)
    private(set) var selection: RadialGeometry.Selection = .cancel
    var isVisible: Bool { window?.isVisible ?? false }

    private var window: NSWindow?
    private let wheel = RadialWheelView()
    private let glass = HUDGlassView(style: .plain)
    private var monitors: [Any] = []
    private var keyTap: CFMachPort?
    private var keyMonitor: Any?
    private var timer: Timer?

    private var center: CGPoint = .zero          // screen coords
    private var pointerOffset: CGPoint = .zero   // relative to the wheel's centre
    private var keyboardIndex: Int?

    private static let padding: CGFloat = 52

    // MARK: Lifecycle

    func show(wedges: [Wedge], at point: CGPoint? = nil) {
        guard !wedges.isEmpty else { return }
        let origin = point ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main else { return }
        self.wedges = wedges
        geometry = RadialGeometry(count: wedges.count, ringCounts: wedges.map { Self.ringCount(for: $0.kind) })
        pointerOffset = .zero
        keyboardIndex = nil
        selection = .cancel

        let side = (geometry.outerEdge + Self.padding) * 2
        let inset = side / 2
        center = CGPoint(
            x: min(max(origin.x, screen.frame.minX + inset), screen.frame.maxX - inset),
            y: min(max(origin.y, screen.frame.minY + inset), screen.frame.maxY - inset))

        let w = window ?? makeWindow()
        if w.frame != screen.frame { w.setFrame(screen.frame, display: false) }
        let local = CGRect(x: center.x - screen.frame.minX - inset, y: center.y - screen.frame.minY - inset,
                           width: side, height: side)
        glass.frame = local
        glass.maskImage = Self.maskImage(side: side, geometry: geometry)
        wheel.frame = local
        wheel.configure(geometry: geometry, wedges: wedges)
        wheel.selection = .cancel
        w.orderFrontRegardless()

        startTracking()
        startAnimation()
    }

    func hide() {
        let wasVisible = isVisible
        stopTracking()
        stopAnimation()
        window?.orderOut(nil)
        if wasVisible { onDismiss?() }
    }

    func cancel() {
        guard isVisible else { return }
        hide()
        onCommit?(.cancelled)
    }

    /// The hotkey was released: act on whatever is highlighted.
    func commit() {
        guard isVisible else { return }
        let picked = selection
        hide()
        switch picked {
        case .cancel:
            onCommit?(.cancelled)
        case .wedge(let i, let ring):
            guard wedges.indices.contains(i) else { onCommit?(.cancelled); return }
            switch (wedges[i].kind, ring) {
            case (.capture, .inner): onCommit?(.capture(allScreens: false))
            case (.capture, .middle): onCommit?(.capture(allScreens: true))
            case (.capture, .outer): onCommit?(.drawLayout)
            case (.park, .inner): onCommit?(.park(restore: false))
            case (.park, _): onCommit?(.park(restore: true))
            case (.widgets, .inner): onCommit?(.widgets(edit: false))
            case (.widgets, _): onCommit?(.widgets(edit: true))
            case (.loadout(let name), .inner): onCommit?(.preview(loadout: name))
            case (.loadout(let name), .middle): onCommit?(.apply(loadout: name, clear: false))
            case (.loadout(let name), .outer): onCommit?(.apply(loadout: name, clear: true))
            }
        }
    }

    /// Move the highlight without the mouse (digits 1-9, and the control socket).
    func select(index: Int, ring: RadialGeometry.Ring? = nil) {
        guard wedges.indices.contains(index) else { return }
        keyboardIndex = index
        if let ring {
            let ring = RadialGeometry.Ring.allCases[min(ring.position, geometry.ringCount(of: index) - 1)]
            selection = .wedge(index: index, ring: ring)
            pointerOffset = offset(index: index, ring: ring)
        } else {
            refreshSelection()
        }
        wheel.selection = selection
    }

    /// Wedge list with the angles each one covers; also used to preview the wheel
    /// while it is hidden.
    static func json(wedges: [Wedge], geometry g: RadialGeometry) -> [String: Any] {
        ["rings": ["deadZone": Double(g.deadZone), "inner": Double(g.innerEdge), "middle": Double(g.middleEdge),
                   "outer": Double(g.outerEdge)],
         "wedges": wedges.enumerated().map { i, wedge -> [String: Any] in
            var w: [String: Any] = [
                "index": i,
                "title": wedge.title,
                "subtitle": wedge.subtitle,
                "kind": { () -> String in
                    switch wedge.kind {
                    case .capture: return "capture"
                    case .park: return "park"
                    case .widgets: return "widgets"
                    case .loadout: return "loadout"
                    }
                }(),
                "rings": g.rings(of: i).map { RadialMenu.ringLabel($0, for: wedge.kind) },
                "angleStart": g.startAngle(of: i),
                "angleCenter": g.centerAngle(of: i),
                "angleEnd": g.endAngle(of: i),
                "icons": wedge.icons.count,
            ]
            if i < 9 { w["digit"] = i + 1 }
            if let hk = wedge.hotkey { w["hotkey"] = hk.display }
            return w
         }]
    }

    var json: [String: Any] {
        var d = Self.json(wedges: wedges, geometry: geometry)
        d["visible"] = isVisible
        d["center"] = ["x": Int(center.x), "y": Int(center.y)]
        switch selection {
        case .cancel:
            d["selection"] = ["kind": "cancel"]
        case .wedge(let i, let ring):
            d["selection"] = ["kind": "wedge", "index": i, "ring": ring.rawValue,
                              "title": wedges.indices.contains(i) ? wedges[i].title : ""]
        }
        return d
    }

    // MARK: Selection

    private func offset(index: Int, ring: RadialGeometry.Ring) -> CGPoint {
        let a = geometry.centerAngle(of: index)
        let band = geometry.band(ring, of: index)
        let r = (band.r0 + band.r1) / 2
        return CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
    }

    private var shiftHeld: Bool { shiftSelectsOuter && NSEvent.modifierFlags.contains(.shift) }

    private func refreshSelection() {
        let pointer = geometry.selection(at: pointerOffset, shift: shiftHeld)
        if let k = keyboardIndex {
            let ring = pointer.ring ?? (shiftHeld ? geometry.lastRing(of: k) : .inner)
            selection = .wedge(index: k, ring: RadialGeometry.Ring.allCases[min(ring.position, geometry.ringCount(of: k) - 1)])
        } else {
            selection = pointer
        }
        wheel.selection = selection
    }

    private func pointerMoved(to location: CGPoint) {
        let o = CGPoint(x: location.x - center.x, y: location.y - center.y)
        if RadialGeometry.radius(of: o) >= geometry.deadZone { keyboardIndex = nil }
        pointerOffset = o
        refreshSelection()
    }

    // MARK: Tracking

    private func startTracking() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
        })
        if let global { monitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(to: NSEvent.mouseLocation) }
            return event
        })
        if let local { monitors.append(local) }
        installKeys()
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func stopTracking() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func installKeys() {
        guard keyTap == nil, keyMonitor == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let menu = Unmanaged<RadialMenu>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { menu.handleKey(type: type, event: event) }
        }
        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                       eventsOfInterest: mask, callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            keyTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            return
        }
        NSLog("MacHUD: radial menu could not create a key tap; digits will not be swallowed")
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                _ = self.handleKeyCode(UInt32(event.keyCode))
            }
        })
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyTap, isVisible { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isVisible else { return Unmanaged.passUnretained(event) }
        let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        return handleKeyCode(code) ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when the key was consumed.
    private func handleKeyCode(_ code: UInt32) -> Bool {
        if code == HotKeyCenter.keyCode(for: "escape") {
            cancel()
            return true
        }
        if code == HotKeyCenter.keyCode(for: "p") {
            // Preview the highlighted loadout instead of applying it.
            var name: String?
            if case .wedge(let i, _) = selection, wedges.indices.contains(i), case .loadout(let n) = wedges[i].kind { name = n }
            hide()
            onCommit?(.preview(loadout: name))
            return true
        }
        for digit in 1...9 where code == HotKeyCenter.keyCode(for: "\(digit)") {
            guard wedges.indices.contains(digit - 1) else { return true }
            select(index: digit - 1)
            return true
        }
        return false
    }

    // MARK: Animation

    private func startAnimation() {
        wheel.resetSprings(count: wedges.count)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.wheel.tick() }
        }
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let content = NSView(frame: .zero)
        content.addSubview(glass)
        content.addSubview(wheel)
        w.contentView = content
        window = w
        return w
    }

    // MARK: Shapes

    /// One frosted tile per wedge and ring, plus the centre disc: used both as the
    /// visual-effect mask and as the fill/stroke geometry.
    static func tiles(center c: CGPoint, geometry g: RadialGeometry) -> [(index: Int, ring: RadialGeometry.Ring, path: NSBezierPath)] {
        var out: [(Int, RadialGeometry.Ring, NSBezierPath)] = []
        for i in 0..<max(g.count, 1) {
            let mean = (g.deadZone + g.outerEdge) / 2
            let gap = min(Double(6 / mean), g.wedgeAngle * 0.22)
            let a0 = g.startAngle(of: i) + gap
            let a1 = g.endAngle(of: i) - gap
            let rings = g.count > 0 ? g.rings(of: i) : RadialGeometry.Ring.allCases
            for ring in rings {
                let band = g.band(ring, of: i)
                let r0 = band.r0 + (ring == .inner ? 6 : 3)
                let r1 = band.r1 == g.outerEdge ? g.outerEdge : band.r1 - 3
                out.append((i, ring, segment(center: c, r0: r0, r1: r1, a0: a0, a1: a1)))
            }
        }
        return out.map { (index: $0.0, ring: $0.1, path: $0.2) }
    }

    static func segment(center c: CGPoint, r0: CGFloat, r1: CGFloat, a0: Double, a1: Double) -> NSBezierPath {
        let path = NSBezierPath()
        let m0 = CGFloat(90 - a0 * 180 / .pi)
        let m1 = CGFloat(90 - a1 * 180 / .pi)
        path.move(to: point(c, r0, a0))
        path.line(to: point(c, r1, a0))
        path.appendArc(withCenter: c, radius: r1, startAngle: m0, endAngle: m1, clockwise: true)
        path.line(to: point(c, r0, a1))
        path.appendArc(withCenter: c, radius: r0, startAngle: m1, endAngle: m0, clockwise: false)
        path.close()
        return path
    }

    static func point(_ c: CGPoint, _ r: CGFloat, _ a: Double) -> CGPoint {
        CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y + r * CGFloat(cos(a)))
    }

    private static func maskImage(side: CGFloat, geometry g: RadialGeometry) -> NSImage {
        NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            let c = CGPoint(x: side / 2, y: side / 2)
            NSColor.black.setFill()
            for tile in tiles(center: c, geometry: g) { tile.path.fill() }
            NSBezierPath(ovalIn: CGRect(x: c.x - g.deadZone, y: c.y - g.deadZone,
                                        width: g.deadZone * 2, height: g.deadZone * 2)).fill()
            return true
        }
    }

    // MARK: Icons

    static func icon(for occupant: Occupant, panels: PanelRegistry?) -> NSImage? {
        switch occupant {
        case .app(let bundleID, _):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        case .web:
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        case .panel(let id):
            let symbol = panels?.panel(id: id)?.symbol ?? "square.grid.2x2"
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        }
    }

    static func icons(for loadout: Loadout, panels: PanelRegistry?) -> [NSImage] {
        loadout.slots.prefix(5).compactMap { icon(for: $0.occupant, panels: panels) }
    }
}

// MARK: - Drawing

final class RadialWheelView: NSView {
    private var geometry = RadialGeometry(count: 0)
    private var wedges: [RadialMenu.Wedge] = []
    private var highlight: [Spring] = []
    private var appear = Spring(0)

    var selection: RadialGeometry.Selection = .cancel {
        didSet { guard selection != oldValue else { return }; retarget(); needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(geometry: RadialGeometry, wedges: [RadialMenu.Wedge]) {
        self.geometry = geometry
        self.wedges = wedges
        needsDisplay = true
    }

    func resetSprings(count: Int) {
        highlight = (0..<count).map { _ in Spring(0) }
        appear = Spring(0)
        appear.target = 1
        needsDisplay = true
    }

    private func retarget() {
        for i in highlight.indices { highlight[i].target = (selection.index == i) ? 1 : 0 }
    }

    func tick() {
        let dt = 1.0 / 120.0
        var settled = appear.step(dt: dt, stiffness: 320, damping: 0.62, epsilon: 0.002)
        for i in highlight.indices {
            settled = highlight[i].step(dt: dt, stiffness: 420, damping: 0.66, epsilon: 0.002) && settled
        }
        needsDisplay = true
        _ = settled
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !wedges.isEmpty else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let accent = NSColor.controlAccentColor

        ctx.saveGState()
        let scale = 0.82 + 0.18 * appear.value
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        ctx.setAlpha(max(0, min(1, appear.value * 1.4)))

        for tile in RadialMenu.tiles(center: c, geometry: geometry) {
            guard wedges.indices.contains(tile.index) else { continue }
            let h = highlight.indices.contains(tile.index) ? highlight[tile.index].value : 0
            let active = selection.index == tile.index && selection.ring == tile.ring
            let path = tile.path
            if h > 0.001 {
                let a = geometry.centerAngle(of: tile.index)
                let push = CGFloat(h) * 5
                let t = AffineTransform(translationByX: push * CGFloat(sin(a)), byY: push * CGFloat(cos(a)))
                path.transform(using: t)
            }
            let base = tile.ring == .inner ? 0.10 : 0.05
            NSColor.white.withAlphaComponent(base + 0.10 * h).setFill()
            path.fill()
            if active {
                accent.withAlphaComponent(0.20 + 0.35 * h).setFill()
                path.fill()
            }
            // Jelly sheen: a light band across the top half of the tile.
            ctx.saveGState()
            path.addClip()
            let box = path.bounds
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)])?
                .draw(in: CGRect(x: box.minX, y: box.midY, width: box.width, height: box.height / 2), angle: -90)
            ctx.restoreGState()
            (active ? accent : NSColor.white.withAlphaComponent(0.18 + 0.3 * h)).setStroke()
            path.lineWidth = active ? 2 : 1
            path.stroke()
        }

        for (i, wedge) in wedges.enumerated() {
            drawWedgeContents(wedge, index: i, center: c)
        }

        drawCenter(at: c)
        ctx.restoreGState()
        drawCaption()
    }

    private func drawWedgeContents(_ wedge: RadialMenu.Wedge, index: Int, center c: CGPoint) {
        let h = highlight.indices.contains(index) ? highlight[index].value : 0
        let a = geometry.centerAngle(of: index)
        let r = (geometry.deadZone + geometry.innerEdge) / 2 + CGFloat(h) * 5
        let p = RadialMenu.point(c, r, a)
        let span = geometry.count > 1
            ? max(70, 2 * r * CGFloat(sin(min(geometry.wedgeAngle / 2, .pi / 3))) - 10)
            : 190

        let hasIcons = !wedge.icons.isEmpty
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72 + 0.28 * h),
            .paragraphStyle: style,
        ]
        let titleRect = CGRect(x: p.x - span / 2, y: p.y - 9 + (hasIcons ? 8 : 0), width: span, height: 18)
        (wedge.title as NSString).draw(in: titleRect, withAttributes: attrs)

        if hasIcons {
            let size: CGFloat = 18
            let spacing: CGFloat = 4
            let total = CGFloat(wedge.icons.count) * size + CGFloat(wedge.icons.count - 1) * spacing
            var x = p.x - total / 2
            let y = p.y - 9 - size + 4
            for icon in wedge.icons {
                let box = CGRect(x: x, y: y, width: size, height: size)
                if icon.isTemplate {
                    NSGraphicsContext.current?.saveGraphicsState()
                    icon.draw(in: box)
                    NSColor.white.withAlphaComponent(0.75 + 0.25 * h).set()
                    box.fill(using: .sourceAtop)
                    NSGraphicsContext.current?.restoreGraphicsState()
                } else {
                    icon.draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.7 + 0.3 * h)
                }
                x += size + spacing
            }
        }

        if index < 9 {
            let digit = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.30 + 0.45 * h),
            ])
            let dp = RadialMenu.point(c, geometry.deadZone + 14, a)
            digit.draw(at: CGPoint(x: dp.x - digit.size().width / 2, y: dp.y - digit.size().height / 2))
        }

        // The highlighted wedge names its outer rings; the selected one is bright, the others faint.
        guard selection.index == index, let selected = selection.ring else { return }
        for ring in geometry.rings(of: index) where ring != .inner {
            let label = NSAttributedString(string: RadialMenu.ringLabel(ring, for: wedges[index].kind), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(ring == selected ? 1 : 0.45),
            ])
            let band = geometry.band(ring, of: index)
            let lp = RadialMenu.point(c, (band.r0 + band.r1) / 2 + CGFloat(h) * 5, a)
            let width = min(label.size().width, band.r1 - band.r0 + 40)
            let rect = CGRect(x: lp.x - width / 2, y: lp.y - label.size().height / 2, width: width, height: label.size().height)
            label.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawCenter(at c: CGPoint) {
        let r = geometry.deadZone
        let disc = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        let cancelling = selection == .cancel
        NSColor.white.withAlphaComponent(cancelling ? 0.16 : 0.08).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(cancelling ? 0.55 : 0.2).setStroke()
        disc.lineWidth = 1
        disc.stroke()
        let text = NSAttributedString(string: cancelling ? "Cancel" : "Esc", attributes: [
            .font: NSFont.systemFont(ofSize: cancelling ? 12 : 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(cancelling ? 0.95 : 0.45),
        ])
        text.draw(at: CGPoint(x: c.x - text.size().width / 2, y: c.y - text.size().height / 2))
    }

    private func drawCaption() {
        var caption = "Out to preview · further to apply · furthest to clear this screen + apply · centre cancels"
        if case .wedge(let i, let ring) = selection, wedges.indices.contains(i) {
            let action = RadialMenu.ringLabel(ring, for: wedges[i].kind)
            let sub = wedges[i].subtitle.isEmpty ? "" : " · \(wedges[i].subtitle)"
            caption = "\(wedges[i].title)\(sub)  —  \(action)"
        }
        let str = NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ])
        let s = str.size()
        let rect = CGRect(x: bounds.midX - s.width / 2 - 12, y: 10, width: s.width + 24, height: s.height + 10)
        let bg = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        str.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
    }
}
