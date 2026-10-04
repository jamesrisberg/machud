import AppKit
import HUDKit

/// Where an offset from the wheel's centre points: which wedge, and which ring.
/// Pure maths, no AppKit state, so it can be unit tested.
struct RadialGeometry: Equatable {
    /// The rings, inside out. What each one does depends on the wedge (`RadialMenu.ringLabel`):
    /// a loadout previews / applies / clears then applies; capture captures this screen / (with
    /// multi-desktop loadouts on) all screens / opens the editor on a new layout; park parks /
    /// restores; widgets reveals / edits.
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
    /// A wedge's last ring reaches the outer edge and continues past it, over the name band.
    var ringCounts: [Int] = []
    /// Inside this radius the wheel is cancelled.
    var deadZone: CGFloat = 46
    /// Outer radius of the inner ring.
    var innerEdge: CGFloat = 100
    /// Outer radius of the middle ring.
    var middleEdge: CGFloat = 148
    /// Outer edge of the wheel's rings; past it the last ring simply continues.
    var outerEdge: CGFloat = 196

    /// The rings move out by `growth(count:)`, so a wheel of many wedges still has room for a
    /// word on its inner ring.
    init(count: Int, ringCounts: [Int] = []) {
        self.init(count: count, ringCounts: ringCounts, growth: Self.growth(count: count))
    }

    private init(count: Int, ringCounts: [Int], growth: CGFloat) {
        self.count = count
        self.ringCounts = ringCounts
        innerEdge += growth
        middleEdge += growth
        outerEdge += growth
    }

    /// How far the rings move out at `count` wedges: not at all up to eight; past that, until a
    /// line of text on the inner ring has 40 pt of arc. The dead zone stays where it is, and the
    /// middle and outer rings keep their depth.
    static func growth(count: Int) -> CGFloat {
        var growth: CGFloat = 0
        while growth < 200 {
            let g = RadialGeometry(count: count, ringCounts: [], growth: growth)
            let band = g.labelBand(.inner, of: 0)
            let line = (band.inner + band.outer) / 2 - 6
            if g.textAngle(at: line) * Double(line) >= 40 { break }
            growth += 1
        }
        return growth
    }

    var wedgeAngle: Double { count > 0 ? Self.fullTurn / Double(count) : Self.fullTurn }

    /// Radians left clear between a wedge's edge and its tiles.
    var tileGap: Double { min(Double(6 / ((deadZone + outerEdge) / 2)), wedgeAngle * 0.22) }

    /// Points kept clear at each end of a line of text, inside the tile gaps.
    static let textInset: CGFloat = 4

    /// The angle a line of text in a wedge may span at radius `r`: the wedge less the tile gaps
    /// and the insets, and never more than 135° (a wheel of one or two wedges).
    func textAngle(at r: CGFloat) -> Double {
        min(wedgeAngle - 2 * tileGap, .pi * 0.75) - 2 * Double(Self.textInset / max(r, 1))
    }

    /// Where `ring`'s button label sits on wedge `index`: inside the ring's tile, and on the
    /// inner ring clear of the digit by the dead zone.
    func labelBand(_ ring: Ring, of index: Int) -> (inner: CGFloat, outer: CGFloat) {
        let band = band(ring, of: index)
        if ring == .inner { return (max(deadZone + 16, band.r1 - 38), band.r1 - 3) }
        return (band.r0 + 3, band.r1 - 3)
    }

    /// Up to this many wedges, the name band also carries each wedge's icons.
    static let iconLimit = 8
    var showsIcons: Bool { count <= Self.iconLimit }
    static let iconRow: CGFloat = 18

    /// The band outside the last ring that carries each wedge's name, and on a wheel of up to
    /// `iconLimit` wedges its icons, under the name. It is not a button: a pointer over it
    /// selects the wedge's last ring.
    var nameBand: (inner: CGFloat, outer: CGFloat) {
        (outerEdge + 6, outerEdge + 6 + (showsIcons ? Self.iconRow : 0) + 36)
    }

    /// The part of the name band the name's lines take: outside the icons.
    var nameTextBand: (inner: CGFloat, outer: CGFloat) {
        (nameBand.inner + (showsIcons ? Self.iconRow : 0), nameBand.outer)
    }

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
        /// What the park wedge's rings act on, read as the wheel opens.
        struct ParkTargets: Equatable {
            /// The focused window's label ("Safari · Page title"); nil when nothing in front
            /// can be parked.
            var focused: String?
            /// The parked windows' labels.
            var parked: [String] = []
        }

        /// `capture`'s `offersAllScreens`: whether it has the ring that captures every display,
        /// which exists only while multi-desktop loadouts (experimental) are on.
        enum Kind: Equatable { case loadout(String), capture(offersAllScreens: Bool), park(ParkTargets), widgets }
        /// Shown on the band outside the last ring: the loadout's name, or Capture, Park, Widgets.
        var name: String
        var icons: [NSImage] = []
        var kind: Kind
        var hotkey: HotKey?
    }

    enum Outcome: Equatable {
        case cancelled
        /// A loadout wedge's middle ring (`clear` false) or outer ring (`clear` true).
        case apply(loadout: String, clear: Bool)
        /// Show what applying a loadout would do (nil: the active one). A loadout wedge's
        /// inner ring, or P over any wedge.
        case preview(loadout: String?)
        /// The capture wedge's inner ring: this screen; its middle ring, when it offers every
        /// display: every display.
        case capture(allScreens: Bool)
        /// The capture wedge's last ring: open the editor on a fresh layout to draw.
        case drawLayout
        /// The park wedge's inner ring: park the focused window. Its outer ring: bring
        /// every parked window back.
        case park(restore: Bool)
        /// The widgets wedge's inner ring: reveal (or lower) the widgets. Its outer ring: edit them.
        case widgets(edit: Bool)
    }

    /// How many rings a wedge has: park, widgets and a capture wedge that captures one screen
    /// have two, the others three.
    static func ringCount(for kind: Wedge.Kind) -> Int {
        switch kind {
        case .park, .widgets, .capture(offersAllScreens: false): return 2
        case .loadout, .capture(offersAllScreens: true): return 3
        }
    }

    /// The button label on each ring of a wedge.
    static func ringLabel(_ ring: RadialGeometry.Ring, for kind: Wedge.Kind) -> String {
        switch (kind, ring) {
        case (.loadout, .inner): return "Preview"
        case (.loadout, .middle): return "Apply"
        case (.loadout, .outer): return "Clear + Apply"
        case (.capture, .inner): return "This screen"
        case (.capture(offersAllScreens: true), .middle): return "All screens"
        case (.capture, .middle), (.capture, .outer): return "Draw layout"
        case (.park, .inner): return "Park"
        case (.park, .middle), (.park, .outer): return "Restore"
        case (.widgets, .inner): return "Reveal"
        case (.widgets, .middle), (.widgets, .outer): return "Edit"
        }
    }

    /// The line under the wheel while `ring` of a wedge of `kind` is highlighted: what releasing
    /// does, and nothing else.
    static func hint(_ ring: RadialGeometry.Ring, for kind: Wedge.Kind) -> String {
        switch (kind, ring) {
        case (.loadout(let name), .inner): return "Preview \(name)"
        case (.loadout(let name), .middle): return "Apply \(name)"
        case (.loadout(let name), .outer): return "Clear this screen and apply \(name)"
        case (.capture, .inner): return "Capture this screen as a loadout"
        case (.capture(offersAllScreens: true), .middle): return "Capture every screen as a loadout"
        case (.capture, .middle), (.capture, .outer): return "Draw a new layout"
        case (.park(let targets), .inner):
            return targets.focused.map { "Park \($0)" } ?? "Focus a window to park"
        case (.park(let targets), .middle), (.park(let targets), .outer):
            switch targets.parked.count {
            case 0: return targets.focused == nil ? "Focus a window to park" : "Nothing is parked"
            case 1: return "Restore \(targets.parked[0])"
            case let n: return "Restore \(n) parked windows"
            }
        case (.widgets, .inner): return "Reveal widgets"
        case (.widgets, .middle), (.widgets, .outer): return "Edit widgets"
        }
    }

    /// The line under the wheel while nothing is highlighted.
    static let idleHint = "Release on a button · centre cancels"

    static func hint(for selection: RadialGeometry.Selection, in wedges: [Wedge]) -> String {
        guard case .wedge(let i, let ring) = selection, wedges.indices.contains(i) else { return idleHint }
        return hint(ring, for: wedges[i].kind)
    }

    /// The hint fitted to lines at most `width` long: one line, else two, shrinking to the
    /// floor, and at worst truncated.
    static func fitHint(_ text: String, width: CGFloat) -> TextFit {
        TextFit.fit(text, style: .hint) { lines, _ in Array(repeating: width, count: lines) }
    }

    /// What committing `ring` of a wedge of `kind` does.
    static func outcome(of kind: Wedge.Kind, ring: RadialGeometry.Ring) -> Outcome {
        switch (kind, ring) {
        case (.capture, .inner): return .capture(allScreens: false)
        case (.capture(offersAllScreens: true), .middle): return .capture(allScreens: true)
        case (.capture, _): return .drawLayout
        case (.park, .inner): return .park(restore: false)
        case (.park, _): return .park(restore: true)
        case (.widgets, .inner): return .widgets(edit: false)
        case (.widgets, _): return .widgets(edit: true)
        case (.loadout(let name), .inner): return .preview(loadout: name)
        case (.loadout(let name), .middle): return .apply(loadout: name, clear: false)
        case (.loadout(let name), .outer): return .apply(loadout: name, clear: true)
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

        let canvas = Self.canvas(for: geometry)
        let frame = screen.frame
        center = CGPoint(
            x: min(max(origin.x, frame.minX + canvas.center.x), frame.maxX - (canvas.size.width - canvas.center.x)),
            y: min(max(origin.y, frame.minY + canvas.center.y), frame.maxY - (canvas.size.height - canvas.center.y)))

        let w = window ?? makeWindow()
        if w.frame != frame { w.setFrame(frame, display: false) }
        let local = CGRect(origin: CGPoint(x: center.x - frame.minX - canvas.center.x, y: center.y - frame.minY - canvas.center.y),
                           size: canvas.size)
        glass.frame = local
        glass.maskImage = Self.maskImage(canvas: canvas, geometry: geometry)
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
            onCommit?(Self.outcome(of: wedges[i].kind, ring: ring))
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

    /// Wedge list with the angles each one covers, each ring's label and hint, and with a
    /// `selection` what it highlights and the hint showing; also used to describe the wheel
    /// while it is hidden.
    static func json(wedges: [Wedge], geometry g: RadialGeometry, selection: RadialGeometry.Selection? = nil) -> [String: Any] {
        var d: [String: Any] = [
            "rings": ["deadZone": Double(g.deadZone), "inner": Double(g.innerEdge), "middle": Double(g.middleEdge),
                      "outer": Double(g.outerEdge), "names": Double(g.nameBand.outer)],
            "wedges": wedges.enumerated().map { i, wedge -> [String: Any] in
                var w: [String: Any] = [
                    "index": i,
                    "name": wedge.name,
                    "kind": { () -> String in
                        switch wedge.kind {
                        case .capture: return "capture"
                        case .park: return "park"
                        case .widgets: return "widgets"
                        case .loadout: return "loadout"
                        }
                    }(),
                    "rings": g.rings(of: i).map { RadialMenu.ringLabel($0, for: wedge.kind) },
                    "hints": g.rings(of: i).map { RadialMenu.hint($0, for: wedge.kind) },
                    "angleStart": g.startAngle(of: i),
                    "angleCenter": g.centerAngle(of: i),
                    "angleEnd": g.endAngle(of: i),
                    "icons": wedge.icons.count,
                ]
                if i < 9 { w["digit"] = i + 1 }
                if let hk = wedge.hotkey { w["hotkey"] = hk.display }
                return w
            },
        ]
        switch selection {
        case nil:
            break
        case .wedge(let i, let ring) where wedges.indices.contains(i):
            d["selection"] = ["kind": "wedge", "index": i, "ring": ring.rawValue, "name": wedges[i].name,
                              "hint": hint(ring, for: wedges[i].kind)]
        case .cancel?, .wedge?:
            d["selection"] = ["kind": "cancel", "hint": idleHint]
        }
        return d
    }

    var json: [String: Any] {
        var d = Self.json(wedges: wedges, geometry: geometry, selection: selection)
        d["visible"] = isVisible
        d["center"] = ["x": Int(center.x), "y": Int(center.y)]
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

    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        // The labels, strokes and fills are white: dark in a light system appearance too, so the
        // glass's tint (white in a light appearance) never sits under them.
        w.appearance = NSAppearance(named: .darkAqua)
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

    /// The wheel's view: the name band with room for a highlighted tile's push, and the hint
    /// below it. `center` is the wheel's centre in the view; the hint's lines are at most
    /// `hintWidth` long and its pill stays under `hintTop`.
    struct Canvas: Equatable {
        var size: CGSize
        var center: CGPoint
        var hintTop: CGFloat
        var hintWidth: CGFloat
    }

    /// How far a highlighted wedge's tiles and text move outward.
    static let push: CGFloat = 5

    static func canvas(for g: RadialGeometry) -> Canvas {
        let reach = (g.nameBand.outer + push + 6).rounded(.up)
        let hint: CGFloat = 46   // two lines of the hint in their pill, and a gap
        return Canvas(size: CGSize(width: reach * 2, height: reach * 2 + hint),
                      center: CGPoint(x: reach, y: hint + reach), hintTop: hint, hintWidth: reach * 2 - 40)
    }

    /// One frosted tile per wedge and ring: part of the glass's shape, and the fill/stroke geometry.
    static func tiles(center c: CGPoint, geometry g: RadialGeometry) -> [(index: Int, ring: RadialGeometry.Ring, path: NSBezierPath)] {
        var out: [(Int, RadialGeometry.Ring, NSBezierPath)] = []
        for i in 0..<max(g.count, 1) {
            let a0 = g.startAngle(of: i) + g.tileGap
            let a1 = g.endAngle(of: i) - g.tileGap
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

    /// One tile per wedge on the name band, behind its name.
    static func nameTiles(center c: CGPoint, geometry g: RadialGeometry) -> [(index: Int, path: NSBezierPath)] {
        (0..<g.count).map { i in
            (i, segment(center: c, r0: g.nameBand.inner, r1: g.nameBand.outer,
                        a0: g.startAngle(of: i) + g.tileGap, a1: g.endAngle(of: i) - g.tileGap))
        }
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

    /// The glass's shape: every tile, the name tiles and the centre disc.
    static func glassShape(center c: CGPoint, geometry g: RadialGeometry) -> [NSBezierPath] {
        tiles(center: c, geometry: g).map(\.path) + nameTiles(center: c, geometry: g).map(\.path)
            + [NSBezierPath(ovalIn: CGRect(x: c.x - g.deadZone, y: c.y - g.deadZone, width: g.deadZone * 2, height: g.deadZone * 2))]
    }

    private static func maskImage(canvas: Canvas, geometry g: RadialGeometry) -> NSImage {
        NSImage(size: canvas.size, flipped: false) { _ in
            NSColor.black.setFill()
            for path in glassShape(center: canvas.center, geometry: g) { path.fill() }
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
    /// A wedge's name and its rings' labels, fitted to their arcs once per configuration.
    private struct WedgeText {
        var name: ArcText
        var labels: [RadialGeometry.Ring: ArcText]
    }

    private var geometry = RadialGeometry(count: 0)
    private var wedges: [RadialMenu.Wedge] = []
    private var texts: [WedgeText] = []
    private var highlight: [Spring] = []
    private var appear = Spring(0)
    private var hintFit: (text: String, fit: TextFit)?

    var selection: RadialGeometry.Selection = .cancel {
        didSet { guard selection != oldValue else { return }; retarget(); needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(geometry: RadialGeometry, wedges: [RadialMenu.Wedge]) {
        self.geometry = geometry
        self.wedges = wedges
        texts = wedges.enumerated().map { i, wedge in
            WedgeText(name: geometry.fitName(wedge.name),
                      labels: Dictionary(uniqueKeysWithValues: geometry.rings(of: i).map { ring in
                          (ring, geometry.fitLabel(RadialMenu.ringLabel(ring, for: wedge.kind), ring: ring, of: i))
                      }))
        }
        hintFit = nil
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

    /// Steps the springs; redraws only while something moves.
    func tick() {
        let dt = 1.0 / 120.0
        let before = (appear.value, highlight.map(\.value))
        _ = appear.step(dt: dt, stiffness: 320, damping: 0.62, epsilon: 0.002)
        for i in highlight.indices {
            _ = highlight[i].step(dt: dt, stiffness: 420, damping: 0.66, epsilon: 0.002)
        }
        if appear.value != before.0 || highlight.map(\.value) != before.1 { needsDisplay = true }
    }

    private func highlightValue(_ index: Int) -> Double {
        highlight.indices.contains(index) ? highlight[index].value : 0
    }

    /// Moves `path` outward along wedge `index`'s centre line by its highlight.
    private func pushed(_ path: NSBezierPath, _ index: Int, _ h: Double) -> NSBezierPath {
        guard h > 0.001 else { return path }
        let a = geometry.centerAngle(of: index)
        let push = CGFloat(h) * RadialMenu.push
        path.transform(using: AffineTransform(translationByX: push * CGFloat(sin(a)), byY: push * CGFloat(cos(a))))
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !wedges.isEmpty else { return }
        let canvas = RadialMenu.canvas(for: geometry)
        let c = canvas.center
        let accent = NSColor.controlAccentColor

        ctx.saveGState()
        let scale = 0.82 + 0.18 * appear.value
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        ctx.setAlpha(max(0, min(1, appear.value * 1.4)))

        for tile in RadialMenu.tiles(center: c, geometry: geometry) {
            guard wedges.indices.contains(tile.index) else { continue }
            let h = highlightValue(tile.index)
            let active = selection.index == tile.index && selection.ring == tile.ring
            let path = pushed(tile.path, tile.index, h)
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

        // The name band: not a button; a wedge's name lights up while any of its rings is highlighted.
        for tile in RadialMenu.nameTiles(center: c, geometry: geometry) {
            let h = highlightValue(tile.index)
            let path = pushed(tile.path, tile.index, h)
            // Darker than the rings, so the names hold up over a bright desktop.
            NSColor.black.withAlphaComponent(0.22).setFill()
            path.fill()
            if h > 0.001 {
                accent.withAlphaComponent(0.30 * h).setFill()
                path.fill()
            }
            (h > 0.001 ? accent.withAlphaComponent(0.25 + 0.5 * h) : NSColor.white.withAlphaComponent(0.10)).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        for (i, wedge) in wedges.enumerated() {
            drawWedgeContents(wedge, index: i, center: c, in: ctx)
        }

        drawCenter(at: c)
        ctx.restoreGState()
        drawHint(canvas)
    }

    /// Draws `text` along its arcs on wedge `index`, `push` further out, in white at `alpha`.
    private func drawArc(_ text: ArcText, style: TextFit.Style, index: Int, push: CGFloat, alpha: CGFloat,
                         center c: CGPoint, in ctx: CGContext) {
        let font = style.font(text.fit.size)
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        for (line, radius) in zip(text.fit.lines, text.baselines) {
            ArcText.draw(line, font: font, radius: radius + push, centerAngle: geometry.centerAngle(of: index), center: c, in: ctx)
        }
        ctx.restoreGState()
    }

    private func drawWedgeContents(_ wedge: RadialMenu.Wedge, index: Int, center c: CGPoint, in ctx: CGContext) {
        guard texts.indices.contains(index) else { return }
        let h = highlightValue(index)
        let push = CGFloat(h) * RadialMenu.push
        let a = geometry.centerAngle(of: index)
        let here = selection.index == index

        // Every ring's button label; the highlighted wedge's are brighter, the selected one brightest.
        for ring in geometry.rings(of: index) {
            guard let label = texts[index].labels[ring] else { continue }
            let alpha: CGFloat = here && selection.ring == ring ? 1 : 0.55 + 0.25 * CGFloat(h)
            drawArc(label, style: .label, index: index, push: push, alpha: alpha, center: c, in: ctx)
        }

        drawArc(texts[index].name, style: .name, index: index, push: push, alpha: 0.78 + 0.22 * CGFloat(h), center: c, in: ctx)
        if geometry.showsIcons { drawIcons(wedge.icons, index: index, push: push, h: h, center: c, in: ctx) }

        if index < 9 {
            let digit = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.30 + 0.45 * h),
            ])
            let dp = RadialMenu.point(c, geometry.deadZone + 10 + push, a)
            digit.draw(at: CGPoint(x: dp.x - digit.size().width / 2, y: dp.y - digit.size().height / 2))
        }
    }

    /// A wedge's icons in a row along the name band, under its name, standing on the arc like its text.
    private func drawIcons(_ icons: [NSImage], index: Int, push: CGFloat, h: Double, center c: CGPoint, in ctx: CGContext) {
        guard !icons.isEmpty else { return }
        let size: CGFloat = 14
        let spacing: CGFloat = 4
        let radius = geometry.nameBand.inner + RadialGeometry.iconRow / 2 + push
        let room = geometry.textAngle(at: radius - size / 2) * Double(radius - size / 2)
        let fitting = max(0, min(icons.count, Int((CGFloat(room) + spacing) / (size + spacing))))
        let shown = icons.prefix(fitting)
        let total = CGFloat(shown.count) * size + CGFloat(max(0, shown.count - 1)) * spacing
        for (k, icon) in shown.enumerated() {
            let spot = ArcText.place(x: CGFloat(k) * (size + spacing) + size / 2, lineWidth: total, radius: radius,
                                     centerAngle: geometry.centerAngle(of: index), center: c)
            ctx.saveGState()
            ctx.translateBy(x: spot.point.x, y: spot.point.y)
            ctx.rotate(by: spot.rotation)
            let box = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
            (icon.isTemplate ? Self.white(icon) : icon)
                .draw(in: box, from: .zero, operation: .sourceOver, fraction: 0.75 + 0.25 * h)
            ctx.restoreGState()
        }
    }

    /// A template symbol in white, tinted in its own image so it composites over anything.
    private static func white(_ icon: NSImage) -> NSImage {
        NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
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

    /// What releasing does, in a pill under the wheel, fitted to the view's width.
    private func drawHint(_ canvas: RadialMenu.Canvas) {
        let text = RadialMenu.hint(for: selection, in: wedges)
        let fit = hintFit?.text == text ? hintFit!.fit : RadialMenu.fitHint(text, width: canvas.hintWidth)
        hintFit = (text, fit)
        let font = TextFit.Style.hint.font(fit.size)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = (fit.lines.map { TextFit.width($0, font: font) }.max() ?? 0) + 24
        let height = lineHeight * CGFloat(fit.lines.count) + 10
        let rect = CGRect(x: canvas.center.x - width / 2, y: canvas.hintTop - 4 - height, width: width, height: height)
        let bg = NSBezierPath(roundedRect: rect, xRadius: min(rect.height / 2, 14), yRadius: min(rect.height / 2, 14))
        NSColor.black.withAlphaComponent(0.6).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        for (i, line) in fit.lines.enumerated() {
            let string = NSAttributedString(string: line, attributes: attributes)
            let y = rect.maxY - 5 - lineHeight * CGFloat(i + 1) + (lineHeight - string.size().height) / 2
            string.draw(at: CGPoint(x: rect.midX - string.size().width / 2, y: y))
        }
    }
}
