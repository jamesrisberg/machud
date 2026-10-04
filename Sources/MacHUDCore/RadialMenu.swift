import AppKit
import HUDKit

/// Where an offset from the wheel's centre points: which wedge, and which ring.
/// Pure maths, no AppKit state, so it can be unit tested. The wheel's layout (`RadialLayout`)
/// sets the radii, sized for the words on each ring.
struct RadialGeometry: Equatable {
    /// The rings, inside out. What each one does depends on the wedge (`RadialMenu.ringLabel`):
    /// a loadout previews / applies / clears then applies; capture captures this screen / (with
    /// multi-desktop loadouts on) all screens / opens the editor on a new layout; park parks /
    /// restores; widgets reveals or lowers / edits or finishes editing.
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
    /// Outer edge of the wheel's rings; past it the last ring simply continues.
    var outerEdge: CGFloat = 196
    /// Where each wedge's name is anchored, past the outer edge. It is not a button: a pointer
    /// there selects the wedge's last ring.
    var nameRadius: CGFloat = 206

    init(count: Int, ringCounts: [Int] = []) {
        self.count = count
        self.ringCounts = ringCounts
    }

    init(count: Int, ringCounts: [Int], deadZone: CGFloat, innerEdge: CGFloat, middleEdge: CGFloat,
         outerEdge: CGFloat, nameRadius: CGFloat) {
        self.count = count
        self.ringCounts = ringCounts
        self.deadZone = deadZone
        self.innerEdge = innerEdge
        self.middleEdge = middleEdge
        self.outerEdge = outerEdge
        self.nameRadius = nameRadius
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
/// click-through, its words upright on one soft dark blur. Release applies the highlighted wedge.
@MainActor
final class RadialMenu {
    struct Wedge {
        /// What the park wedge's rings act on, read as the wheel opens and again whenever the
        /// park wedge becomes highlighted.
        struct ParkTargets: Equatable {
            /// The focused window's label ("Safari · Page title"); nil when nothing in front
            /// can be parked.
            var focused: String?
            /// The parked windows' labels.
            var parked: [String] = []
        }

        /// What the widgets wedge's rings toggle, read as the wheel opens.
        struct WidgetsState: Equatable {
            /// The widgets are raised above the windows: the inner ring lowers them.
            var revealed = false
            /// The widgets are being edited: the outer ring finishes.
            var editing = false
        }

        /// `capture`'s `offersAllScreens`: whether it has the ring that captures every display,
        /// which exists only while multi-desktop loadouts (experimental) are on.
        enum Kind: Equatable {
            case loadout(String), capture(offersAllScreens: Bool), park(ParkTargets), widgets(WidgetsState)
        }
        /// Shown outside the last ring: the loadout's name, or Capture, Park, Widgets.
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
        /// The widgets wedge's inner ring: reveal the widgets (`on`) or lower them. Its outer
        /// ring: start editing them (`on`) or finish. `on` is the state the button showed, read
        /// as the wheel opened: the app sets it rather than toggling the state it finds then.
        case widgets(edit: Bool, on: Bool)
    }

    /// Which buttons show while the pointer is not on their wedge: every wedge's, faint
    /// (`faint`), or only the highlighted wedge's, the others showing their names alone (`hidden`).
    enum RestingButtons { case faint, hidden }
    static let restingButtons: RestingButtons = .faint

    /// How many rings a wedge has: park, widgets and a capture wedge that captures one screen
    /// have two, the others three.
    nonisolated static func ringCount(for kind: Wedge.Kind) -> Int {
        switch kind {
        case .park, .widgets, .capture(offersAllScreens: false): return 2
        case .loadout, .capture(offersAllScreens: true): return 3
        }
    }

    /// The button label on each ring of a wedge.
    nonisolated static func ringLabel(_ ring: RadialGeometry.Ring, for kind: Wedge.Kind) -> String {
        switch (kind, ring) {
        case (.loadout, .inner): return "Preview"
        case (.loadout, .middle): return "Apply"
        case (.loadout, .outer): return "Clear + Apply"
        case (.capture, .inner): return "This screen"
        case (.capture(offersAllScreens: true), .middle): return "All screens"
        case (.capture, .middle), (.capture, .outer): return "Draw layout"
        case (.park, .inner): return "Park"
        case (.park, .middle), (.park, .outer): return "Restore"
        case (.widgets(let state), .inner): return state.revealed ? "Lower" : "Reveal"
        case (.widgets(let state), .middle), (.widgets(let state), .outer): return state.editing ? "Done" : "Edit"
        }
    }

    /// The line under the wheel while `ring` of a wedge of `kind` is highlighted: what releasing
    /// does, and nothing else.
    nonisolated static func hint(_ ring: RadialGeometry.Ring, for kind: Wedge.Kind) -> String {
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
        case (.widgets(let state), .inner): return state.revealed ? "Lower widgets" : "Reveal widgets"
        case (.widgets(let state), .middle), (.widgets(let state), .outer):
            return state.editing ? "Finish editing widgets" : "Edit widgets"
        }
    }

    /// The line under the wheel while nothing is highlighted.
    nonisolated static let idleHint = "Release on a button · centre cancels"

    nonisolated static func hint(for selection: RadialGeometry.Selection, in wedges: [Wedge]) -> String {
        guard case .wedge(let i, let ring) = selection, wedges.indices.contains(i) else { return idleHint }
        return hint(ring, for: wedges[i].kind)
    }

    /// What committing `ring` of a wedge of `kind` does.
    nonisolated static func outcome(of kind: Wedge.Kind, ring: RadialGeometry.Ring) -> Outcome {
        switch (kind, ring) {
        case (.capture, .inner): return .capture(allScreens: false)
        case (.capture(offersAllScreens: true), .middle): return .capture(allScreens: true)
        case (.capture, _): return .drawLayout
        case (.park, .inner): return .park(restore: false)
        case (.park, _): return .park(restore: true)
        case (.widgets(let state), .inner): return .widgets(edit: false, on: !state.revealed)
        case (.widgets(let state), _): return .widgets(edit: true, on: !state.editing)
        case (.loadout(let name), .inner): return .preview(loadout: name)
        case (.loadout(let name), .middle): return .apply(loadout: name, clear: false)
        case (.loadout(let name), .outer): return .apply(loadout: name, clear: true)
        }
    }

    /// Whether the park wedge's targets are asked for again: wedge `index` has just become
    /// highlighted (it was `previous`) and is the park wedge. The wheel is click-through, so a
    /// click under it can change the focused window while it is open; asking again keeps the
    /// hint naming the window a release would park.
    nonisolated static func asksForParkTargets(highlighting index: Int, from previous: Int?, in wedges: [Wedge]) -> Bool {
        guard index != previous, wedges.indices.contains(index), case .park = wedges[index].kind else { return false }
        return true
    }

    /// `wedges` with the park wedge at `index` given `targets`; nil when that changes nothing.
    nonisolated static func refreshed(_ wedges: [Wedge], park index: Int, with targets: Wedge.ParkTargets) -> [Wedge]? {
        guard wedges.indices.contains(index), case .park(let old) = wedges[index].kind, old != targets else { return nil }
        var out = wedges
        out[index].kind = .park(targets)
        return out
    }

    /// Applied when the hotkey is released.
    var onCommit: ((Outcome) -> Void)?
    /// False when the menu's own hotkey already uses shift, so it cannot double as "clear".
    var shiftSelectsOuter = true
    /// Called whenever a visible wheel goes away, however it was dismissed.
    var onDismiss: (() -> Void)?
    /// Reads the park wedge's targets and calls back with them on the main thread
    /// (`asksForParkTargets`). It must not wait for the answer on the main thread: the
    /// Accessibility calls behind it can take a hung app's timeout.
    var readParkTargets: ((@escaping @MainActor (Wedge.ParkTargets) -> Void) -> Void)?
    /// Counts the wheel's openings: an answer about the park wedge from an earlier one is not used.
    private var opening = 0
    /// A read of the park wedge's targets has been asked for and not answered.
    private var parkTargetsAsked = false

    private(set) var wedges: [Wedge] = []
    private(set) var layout = RadialLayout(wedges: [])
    var geometry: RadialGeometry { layout.geometry }
    private(set) var selection: RadialGeometry.Selection = .cancel
    var isVisible: Bool { window?.isVisible ?? false }

    private var window: NSWindow?
    let wheel = RadialWheelView()
    private let tint = RadialTintView(frame: .zero)
    private let backdrop = RadialBackdrop()
    private var monitors: [Any] = []
    private var keyTap: CFMachPort?
    private var keyMonitor: Any?
    private var timer: Timer?
    private var transparencyObserver: NSObjectProtocol?
    /// The last field built: a wheel of the same shape opens with it.
    private var field: RadialField?
    /// The last layout made: a wheel with the same words in the same room opens with it.
    private var laidOut: (key: LayoutKey, layout: RadialLayout)?

    /// What a layout is made from: each wedge's name, ring labels and icon count, and the room.
    struct LayoutKey: Equatable {
        var words: [[String]]
        var icons: [Int]
        var room: CGSize

        init(_ wedges: [Wedge], room: CGSize) {
            words = wedges.map { wedge in
                [wedge.name] + Array(RadialGeometry.Ring.allCases.prefix(RadialMenu.ringCount(for: wedge.kind))).map {
                    RadialMenu.ringLabel($0, for: wedge.kind)
                }
            }
            icons = wedges.map { min($0.icons.count, RadialLayout.maxIcons) }
            self.room = room
        }
    }

    /// The wheel's centre, in screen coordinates.
    private(set) var center: CGPoint = .zero
    private var screenFrame: CGRect = .zero
    private var pointerOffset: CGPoint = .zero   // relative to the wheel's centre
    private var keyboardIndex: Int?
    /// The pointer has gone `pointerTravel` from where the first report after the wheel opened
    /// found it: until it has, it is taken to be at the centre, so nothing is lit and releasing
    /// cancels, wherever it really is. Counting from the first report rather than from the
    /// centre covers a pointer that moving did not stick to (a hovering pen, a remotely driven
    /// pointer), whose next report puts it back where it was.
    private var pointerHasMoved = false
    /// Where the first pointer report after the wheel opened found it.
    private var firstReport: CGPoint?
    /// How far the pointer goes from its first report before the wheel follows it.
    static let pointerTravel: CGFloat = 6

    /// Moves the pointer to a point in display coordinates, which are AX coordinates (y down
    /// from the primary display's top), without a pause before it moves again. Tests record it
    /// instead.
    var warpPointer: (CGPoint) -> Void = { point in
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    /// The modifier keys held now (tests give their own).
    var modifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    /// The screen a wheel opens on, in screen coordinates; `primaryHeight` is the height of the
    /// primary display (the one at the origin), which turns screen points into display points
    /// (`ScreenCoords.axPoint(fromCocoa:primaryHeight:)`).
    struct Display: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
        var primaryHeight: CGFloat
    }

    // MARK: Lifecycle

    func show(wedges: [Wedge], at point: CGPoint? = nil) {
        guard !wedges.isEmpty else { return }
        let origin = point ?? NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let index = ScreenCoords.screenIndex(containing: origin, frames: screens.map(\.frame)) else { return }
        let screen = screens[index]
        let display = Display(frame: screen.frame, visibleFrame: screen.visibleFrame,
                              primaryHeight: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
        // Opened at the pointer (the hotkey), the wheel moves the pointer to its centre when
        // it cannot open around it; opened by a script at a point, it leaves the pointer alone.
        prepare(wedges: wedges, at: origin, on: display, movesPointer: point == nil)

        let w = window ?? makeWindow()
        if w.frame != screenFrame { w.setFrame(screenFrame, display: false) }
        w.orderFrontRegardless()

        startTracking()
        startAnimation()
    }

    /// Sets the wheel up to open at `origin` on `display`, with nothing selected and the pointer
    /// taken to be at the centre until it moves. Where the centre had to move away from
    /// `origin` to keep every word on screen and `movesPointer`, the pointer is moved to the
    /// centre, so a gesture means the same direction and distance from the centre wherever
    /// the wheel opens; it is not moved back. No window is shown and no event is watched.
    func prepare(wedges: [Wedge], at origin: CGPoint, on display: Display, movesPointer: Bool) {
        self.wedges = wedges
        let room = display.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let key = LayoutKey(wedges, room: room.size)
        let layout = laidOut?.key == key ? laidOut!.layout : RadialLayout.fitting(wedges, in: room.size)
        laidOut = (key, layout)
        self.layout = layout
        center = Self.centre(of: layout, at: origin, room: room)
        screenFrame = display.frame
        pointerOffset = .zero
        pointerHasMoved = false
        firstReport = nil
        opening += 1
        parkTargetsAsked = false
        keyboardIndex = nil
        selection = .cancel
        wheel.selection = .cancel
        applyField()
        if movesPointer, hypot(center.x - origin.x, center.y - origin.y) > 0.5 {
            warpPointer(ScreenCoords.axPoint(fromCocoa: center, primaryHeight: display.primaryHeight))
        }
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

    /// What releasing does now: what is highlighted, or cancel.
    var releaseOutcome: Outcome {
        guard case .wedge(let i, let ring) = selection, wedges.indices.contains(i) else { return .cancelled }
        return Self.outcome(of: wedges[i].kind, ring: ring)
    }

    /// The hotkey was released: act on whatever is highlighted.
    func commit() {
        guard isVisible else { return }
        let outcome = releaseOutcome
        hide()
        onCommit?(outcome)
    }

    /// Move the highlight without the mouse (digits 1-9, and the control socket).
    func select(index: Int, ring: RadialGeometry.Ring? = nil) {
        guard wedges.indices.contains(index) else { return }
        keyboardIndex = index
        if let ring {
            let previous = selection.index
            let ring = RadialGeometry.Ring.allCases[min(ring.position, geometry.ringCount(of: index) - 1)]
            selection = .wedge(index: index, ring: ring)
            pointerOffset = offset(index: index, ring: ring)
            noteHighlight(from: previous)
        } else {
            refreshSelection()
        }
        wheel.selection = selection
    }

    /// Wedge list with the angles each one covers, each ring's label and hint, the icons drawn
    /// by its name, the rings' radii, and with a `selection` what it highlights and the hint
    /// showing; also used to describe the wheel while it is hidden.
    static func json(wedges: [Wedge], layout: RadialLayout, selection: RadialGeometry.Selection? = nil) -> [String: Any] {
        let g = layout.geometry
        var d: [String: Any] = [
            "rings": ["deadZone": Double(g.deadZone), "inner": Double(g.innerEdge), "middle": Double(g.middleEdge),
                      "outer": Double(g.outerEdge), "names": Double(g.nameRadius)],
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
                    "icons": layout.icons(of: i),
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
        var d = Self.json(wedges: wedges, layout: layout, selection: selection)
        d["visible"] = isVisible
        d["center"] = ["x": Int(center.x), "y": Int(center.y)]
        return d
    }

    // MARK: Placement

    /// Room kept between the wheel's words and the edge of the screen's visible frame.
    static let screenMargin: CGFloat = 8

    /// The wheel's layout and centre (screen coordinates) for a wheel opened at `pointer` on a
    /// screen whose visible frame (less the menu bar and the Dock) is `visibleFrame`: full size
    /// where it fits, smaller where it would not, and moved in from the edges so every word and
    /// the hint are on screen. The field may fade out past the edge.
    static func place(wedges: [Wedge], at pointer: CGPoint, visibleFrame: CGRect) -> (layout: RadialLayout, center: CGPoint) {
        let room = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let layout = RadialLayout.fitting(wedges, in: room.size)
        return (layout, centre(of: layout, at: pointer, room: room))
    }

    /// Where `layout`'s centre goes for a wheel opened at `pointer`: there, or moved in from
    /// the edges of `room` so every word and the hint are inside it.
    static func centre(of layout: RadialLayout, at pointer: CGPoint, room: CGRect) -> CGPoint {
        let b = layout.bounds
        return CGPoint(x: min(max(pointer.x, room.minX - b.minX), room.maxX - b.maxX),
                       y: min(max(pointer.y, room.minY - b.minY), room.maxY - b.maxY))
    }

    /// Shapes the backdrop and the wheel's view to the field, which follows Reduce transparency.
    private func applyField() {
        let shape = RadialField.Shape(layout: layout, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        let field = self.field?.shape == shape ? self.field! : RadialField(shape: shape)
        self.field = field
        let canvas = field.canvas
        let local = CGRect(x: center.x - screenFrame.minX - canvas.center.x, y: center.y - screenFrame.minY - canvas.center.y,
                           width: canvas.size.width, height: canvas.size.height)
        backdrop.view.frame = local
        backdrop.show(field: field.blurImage)
        tint.frame = local
        tint.image = field.tintImage
        wheel.frame = local
        wheel.configure(layout: layout, field: field, wedges: wedges)
    }

    // MARK: Selection

    private func offset(index: Int, ring: RadialGeometry.Ring) -> CGPoint {
        let a = geometry.centerAngle(of: index)
        let band = geometry.band(ring, of: index)
        let r = (band.r0 + band.r1) / 2
        return CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
    }

    private var shiftHeld: Bool { shiftSelectsOuter && modifiers().contains(.shift) }

    private func refreshSelection() {
        let previous = selection.index
        let pointer = geometry.selection(at: pointerOffset, shift: shiftHeld)
        if let k = keyboardIndex {
            let ring = pointer.ring ?? (shiftHeld ? geometry.lastRing(of: k) : .inner)
            selection = .wedge(index: k, ring: RadialGeometry.Ring.allCases[min(ring.position, geometry.ringCount(of: k) - 1)])
        } else {
            selection = pointer
        }
        noteHighlight(from: previous)
        wheel.selection = selection
    }

    /// The park wedge asks for its targets again as it becomes highlighted (`asksForParkTargets`).
    private func noteHighlight(from previous: Int?) {
        guard let i = selection.index, Self.asksForParkTargets(highlighting: i, from: previous, in: wedges),
              let read = readParkTargets, !parkTargetsAsked else { return }
        parkTargetsAsked = true
        let asked = opening
        read { [weak self] targets in
            guard let self, self.opening == asked else { return }
            self.parkTargetsAsked = false
            // Only while the park wedge is still highlighted: its hint is the one that shows.
            guard self.selection.index == i, let fresh = Self.refreshed(self.wedges, park: i, with: targets) else { return }
            self.wedges = fresh
            self.wheel.update(wedges: fresh)
        }
    }

    /// A mouse-moved or dragged event: the pointer is at `location` (screen coordinates),
    /// having moved by `delta`. Nothing changes until the pointer has gone `pointerTravel` from
    /// where the first report found it.
    func pointerMoved(to location: CGPoint, delta: CGVector) {
        if !pointerHasMoved {
            guard delta.dx != 0 || delta.dy != 0 else { return }
            guard let first = firstReport else { firstReport = location; return }
            guard hypot(location.x - first.x, location.y - first.y) >= Self.pointerTravel else { return }
            pointerHasMoved = true
        }
        let o = CGPoint(x: location.x - center.x, y: location.y - center.y)
        if RadialGeometry.radius(of: o) >= geometry.deadZone { keyboardIndex = nil }
        pointerOffset = o
        refreshSelection()
    }

    /// A modifier key changed (Shift reaches the last ring): the selection is read again with
    /// the pointer where the wheel last saw it, the centre until it has moved.
    func modifiersChanged() {
        refreshSelection()
    }

    // MARK: Tracking

    private func startTracking() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .flagsChanged]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        })
        if let global { monitors.append(global) }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        })
        if let local { monitors.append(local) }
        installKeys()
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.applyField() } }
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            modifiersChanged()
        } else {
            pointerMoved(to: NSEvent.mouseLocation, delta: CGVector(dx: event.deltaX, dy: event.deltaY))
        }
    }

    private func stopTracking() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let observer = transparencyObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        transparencyObserver = nil
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
    func handleKeyCode(_ code: UInt32) -> Bool {
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
        wheel.resetSprings()
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
        // The words are white on a dark field: dark in a light system appearance too, so the
        // system's material the backdrop shows with Reduce transparency on is the dark one.
        w.appearance = NSAppearance(named: .darkAqua)
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        let content = NSView(frame: .zero)
        content.addSubview(backdrop.view)
        content.addSubview(tint)
        content.addSubview(wheel)
        wheel.onShown = { [weak tint] shown in tint?.shown = shown }
        w.contentView = content
        window = w
        return w
    }

    /// The view the wheel draws in, centred where its centre is.
    struct Canvas: Equatable {
        var size: CGSize
        var center: CGPoint
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
        loadout.slots.prefix(RadialLayout.maxIcons).compactMap { icon(for: $0.occupant, panels: panels) }
    }
}

// MARK: - Backdrop

/// What the wheel's tint and words sit on: HUDKit's soft backdrop (`HUDSoftBackdropView`), a
/// blur of what is behind the window shown through the field, so its edge fades out instead of
/// ending in a line. With a field it always draws: the blur, or the system's material (opaque
/// and dark with Reduce transparency on; AppKit's own translucent material where the blur
/// cannot be made). It draws no tint of its own: the wheel's tint is its own view
/// (`RadialTintView`), the same over either. Nothing else in the wheel's window may be on the
/// window server's blur (`HUDGlassView` with the window blur): that blur covers everything the
/// window draws and would end in a line.
@MainActor
final class RadialBackdrop {
    let view: HUDSoftBackdropView
    private var shown: CGImage?

    /// `view` stands in for the backdrop (tests); nil makes the family's.
    init(view: HUDSoftBackdropView? = nil) {
        self.view = view ?? HUDSoftBackdropView(frame: .zero)
        self.view.tint = nil
        // HUDKit's log lines about the backdrop name it by this.
        self.view.identifier = NSUserInterfaceItemIdentifier("loadout wheel")
    }

    var path: HUDSoftBackdropView.Path { view.path }

    /// Shows the blur through `field`'s alpha, stretched over the view, and says how the
    /// backdrop draws now. The same field again is left as it is: a new one has the backdrop
    /// build its material again.
    @discardableResult
    func show(field: CGImage) -> HUDSoftBackdropView.Path {
        if field !== shown {
            shown = field
            view.field = NSImage(cgImage: field, size: CGSize(width: field.width, height: field.height))
        }
        return view.path
    }
}

// MARK: - Drawing

/// The wheel's tint: the field's tint profile (black, its alpha the profile) stretched over the
/// canvas, composited by the GPU and drawn once per configuration, under the words. Its opacity
/// is `RadialField.darkness` times how far the wheel has faded in (`shown`).
final class RadialTintView: NSView {
    var image: CGImage? { didSet { layer?.contents = image } }
    var shown: CGFloat = 1 { didSet { alphaValue = RadialField.darkness * shown } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .linear
        alphaValue = RadialField.darkness * shown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The wheel's words, over its tint (`RadialTintView`). Each word is rendered once per
/// configuration and backing scale, white with its soft dark shadow, and once more lit (with its
/// glow, a button at its grown size); a frame draws those pictures at the springs' strengths, and
/// the hint again only when it changes.
final class RadialWheelView: NSView {
    /// A word drawn once: its picture and where it goes, in wheel coordinates.
    private struct Still {
        var image: CGImage
        var rect: CGRect
        /// How many times its word's rest size the picture shows it.
        var grown: CGFloat = 1
    }

    private static let empty: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    private struct Drawn {
        var role: RadialLayout.Word.Role
        var rest: Still
        var lit: Still?
        /// How many times its size it grows lit (`RadialLayout.Word.grow`).
        var grow: CGFloat = 1
    }

    /// The most a button grows under the pointer, about its own centre; each grows as far as
    /// its region allows (`RadialLayout.Word.grow`).
    nonisolated static let grow: CGFloat = 1.3
    /// How far a lit word's glow reaches past its box, at full size. The field's blur is full a
    /// little further out (`RadialField.pad`).
    nonisolated static let glowReach: CGFloat = 14
    /// How far the light under a hovered button reaches past most of its box, at full size: as
    /// far as the full blur around a lone word.
    nonisolated static let lightReach: CGFloat = RadialField.pad

    /// Which buttons show while the pointer is not on their wedge.
    var restingButtons = RadialMenu.restingButtons { didSet { if restingButtons != oldValue { needsDisplay = true } } }

    /// Called with how far the wheel has faded in (0...1), for the tint under it.
    var onShown: ((CGFloat) -> Void)?

    private var layout = RadialLayout(wedges: [])
    private var wedges: [RadialMenu.Wedge] = []
    private var origin: CGPoint = .zero
    /// The words drawn, at `drawnScale` pixels per point (0: not yet).
    private var drawn: [Drawn] = []
    private var drawnScale: CGFloat = 0
    private var drawnAppearance: NSAppearance.Name?
    /// How many times the words have been drawn into their pictures (tests).
    private(set) var wordRenders = 0
    /// Each name's icons in a row, by wedge, drawn once per configuration (the icons are the
    /// wedges', which a new configuration brings anew); nil until drawn.
    private var iconRows: [Int: Still]?
    private var buttonIndex: [RadialLayout.Word.Role: Int] = [:]
    private var hint: (text: String, still: Still)?

    /// Per wedge: highlighted.
    private var highlight: [Spring] = []
    /// Per button, in the layout's order: under the pointer.
    private var lit: [Spring] = []
    private var cancelLit = Spring(1)
    private var appear = Spring(1)

    var selection: RadialGeometry.Selection = .cancel {
        didSet { guard selection != oldValue else { return }; retarget(); needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var buttonRoles: [RadialLayout.Word.Role] {
        layout.words.compactMap { if case .button = $0.role { return $0.role } else { return nil } }
    }

    func configure(layout: RadialLayout, field: RadialField, wedges: [RadialMenu.Wedge]) {
        // The words are drawn again only for a new layout: they depend on it, the backing scale
        // and the appearance alone.
        if layout != self.layout {
            drawn = []
            drawnScale = 0
        }
        self.layout = layout
        self.wedges = wedges
        origin = field.canvas.center
        iconRows = nil
        hint = nil
        let roles = buttonRoles
        buttonIndex = Dictionary(uniqueKeysWithValues: roles.enumerated().map { ($1, $0) })
        if highlight.count != wedges.count { highlight = wedges.map { _ in Spring(0) } }
        if lit.count != roles.count { lit = roles.map { _ in Spring(0) } }
        retarget()
        needsDisplay = true
    }

    /// The same wheel with wedges whose kinds changed but whose labels did not (the park
    /// wedge's targets): only the hint changes.
    func update(wedges: [RadialMenu.Wedge]) {
        self.wedges = wedges
        needsDisplay = true
    }

    func resetSprings() {
        highlight = wedges.map { _ in Spring(0) }
        lit = buttonRoles.map { _ in Spring(0) }
        cancelLit = Spring(selection == .cancel ? 1 : 0)
        appear = Spring(0)
        appear.target = 1
        onShown?(0)
        retarget()
        needsDisplay = true
    }

    /// At rest with `selection` highlighted, as if the springs had settled (snapshots).
    func settle(selection: RadialGeometry.Selection) {
        self.selection = selection
        retarget()
        for i in highlight.indices { highlight[i].jump(to: highlight[i].target) }
        for i in lit.indices { lit[i].jump(to: lit[i].target) }
        cancelLit.jump(to: cancelLit.target)
        appear.jump(to: 1)
        onShown?(1)
        needsDisplay = true
    }

    private func retarget() {
        for i in highlight.indices { highlight[i].target = selection.index == i ? 1 : 0 }
        for (role, k) in buttonIndex where lit.indices.contains(k) {
            guard case .button(let i, let ring) = role else { continue }
            lit[k].target = selection == .wedge(index: i, ring: ring) ? 1 : 0
        }
        cancelLit.target = selection == .cancel ? 1 : 0
    }

    private var springs: [Spring] { highlight + lit + [cancelLit, appear] }

    /// Whether a spring is still moving.
    var isMoving: Bool { springs.contains { $0.value != $0.target || $0.velocity != 0 } }

    /// Steps the springs; redraws only while something moves.
    func tick() {
        let dt = 1.0 / 120.0
        let before = springs
        _ = appear.step(dt: dt, stiffness: 320, damping: 0.62, epsilon: 0.002)
        _ = cancelLit.step(dt: dt, stiffness: 420, damping: 0.7, epsilon: 0.002)
        for i in highlight.indices { _ = highlight[i].step(dt: dt, stiffness: 420, damping: 0.66, epsilon: 0.002) }
        for i in lit.indices { _ = lit[i].step(dt: dt, stiffness: 380, damping: 0.55, epsilon: 0.002) }
        if appear.value != before[before.count - 1].value { onShown?(shown) }
        if springs != before { needsDisplay = true }
    }

    private var shown: CGFloat { max(0, min(1, CGFloat(appear.value) * 1.4)) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    // MARK: Pictures

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Draws each word once, at `scale` pixels per point.
    private func prepare(scale: CGFloat) {
        let s = layout.scale
        drawn = layout.words.compactMap { word -> Drawn? in
            let text = PreparedText(word.fit, style: word.style)
            switch word.role {
            case .button:
                return Drawn(role: word.role, rest: Self.still(text, frame: word.frame, align: 0.5, scale: scale, size: s),
                             lit: Self.still(text, frame: word.frame, align: 0.5, scale: scale, size: s, glow: true, grow: word.grow),
                             grow: word.grow)
            case .name:
                return Drawn(role: word.role, rest: Self.still(text, frame: word.frame, align: word.align, scale: scale, size: s),
                             lit: Self.still(text, frame: word.frame, align: word.align, scale: scale, size: s, glow: true))
            case .digit:
                return Drawn(role: word.role, rest: Self.still(text, frame: word.frame, align: 0.5, scale: scale, size: s), lit: nil)
            case .centre:
                let escape = PreparedText(TextFit(lines: ["Esc"], size: word.style.preferred - 1.5 * s, truncated: false), style: word.style)
                return Drawn(role: word.role, rest: Self.still(escape, frame: word.frame, align: 0.5, scale: scale, size: s),
                             lit: Self.still(text, frame: word.frame, align: 0.5, scale: scale, size: s, glow: true))
            }
        }
        drawnScale = scale
        drawnAppearance = effectiveAppearance.name
        wordRenders += 1
        iconRows = nil
        hint = nil
    }

    /// Each name's icons in a row under its lines, with the words' soft dark shadow.
    private func prepareIcons(scale: CGFloat) {
        var rows: [Int: Still] = [:]
        for word in layout.words {
            guard case .name(let i) = word.role, word.icons > 0, wedges.indices.contains(i) else { continue }
            rows[i] = Self.still(nil, frame: word.frame, align: word.align, scale: scale, size: layout.scale,
                                 icons: Array(wedges[i].icons.prefix(word.icons)))
        }
        iconRows = rows
    }

    /// `text` in white inside `frame` (its lines from the top, placed across by `align`), or a
    /// name's `icons` in a row at the frame's foot, with a soft dark shadow and, when `glow`, a
    /// white glow, `grow` times its size about its centre: rendered at `scale` pixels per point,
    /// the shadows sized for wheel scale `size`.
    private static func still(_ text: PreparedText?, frame: CGRect, align: CGFloat, scale: CGFloat, size s: CGFloat,
                              icons: [NSImage] = [], glow: Bool = false, grow: CGFloat = 1) -> Still {
        let margin = (glow ? glowReach : 6) * s
        let grown = CGRect(x: frame.midX - frame.width * grow / 2, y: frame.midY - frame.height * grow / 2,
                           width: frame.width * grow, height: frame.height * grow)
        let rect = grown.insetBy(dx: -margin, dy: -margin).integral
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: max(1, Int(rect.width * scale)), height: max(1, Int(rect.height * scale)),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Still(image: empty, rect: rect, grown: grow)
        }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        if grow != 1 {
            ctx.translateBy(x: frame.midX, y: frame.midY)
            ctx.scaleBy(x: grow, y: grow)
            ctx.translateBy(x: -frame.midX, y: -frame.midY)
        }
        // Shadows are in the bitmap's pixels, whatever the transform.
        let px = scale * grow
        func words() {
            if let text {
                text.draw(in: CGRect(x: frame.minX, y: frame.maxY - text.height, width: frame.width, height: text.height),
                          align: align, in: ctx)
            }
            guard !icons.isEmpty else { return }
            let side = RadialLayout.iconSize * s, spacing = RadialLayout.iconSpacing * s
            let row = CGFloat(icons.count) * side + CGFloat(icons.count - 1) * spacing
            let x = frame.minX + (frame.width - row) * align
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for (k, icon) in icons.enumerated() {
                (icon.isTemplate ? white(icon) : icon).draw(in: CGRect(x: x + CGFloat(k) * (side + spacing), y: frame.minY,
                                                                        width: side, height: side))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.setFillColor(NSColor.white.cgColor)
        if glow {
            ctx.setShadow(offset: .zero, blur: 10 * s * px, color: NSColor.white.withAlphaComponent(0.8).cgColor)
            words()
        }
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * s * px), blur: 4 * s * px, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        words()
        return Still(image: ctx.makeImage() ?? empty, rect: rect, grown: grow)
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

    // MARK: Frames

    private func value(_ springs: [Spring], _ i: Int) -> CGFloat {
        springs.indices.contains(i) ? CGFloat(springs[i].value) : 0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !wedges.isEmpty else { return }
        if drawnScale != backingScale || drawnAppearance != effectiveAppearance.name { prepare(scale: backingScale) }
        if iconRows == nil { prepareIcons(scale: backingScale) }
        let shown = self.shown
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.interpolationQuality = .high
        let grow = 0.9 + 0.1 * CGFloat(appear.value)
        ctx.scaleBy(x: grow, y: grow)
        let hovered = CGFloat(highlight.map(\.value).max() ?? 0)
        func recede(_ i: Int) -> CGFloat { max(0, hovered - value(highlight, i)) }
        drawLight(in: ctx, shown: shown)
        for word in drawn {
            switch word.role {
            case .button(let i, _):
                let l = value(lit, buttonIndex[word.role] ?? -1)
                let h = value(highlight, i)
                let resting: CGFloat = restingButtons == .faint ? 0.45 - 0.13 * recede(i) : 0
                let base = resting + (0.88 - resting) * h
                draw(word, alpha: (base + (1 - base) * l) * shown, lit: l, grow: 1 + (word.grow - 1) * l, in: ctx)
            case .name(let i):
                let h = value(highlight, i)
                let alpha = (0.88 + 0.12 * h - 0.3 * recede(i)) * shown
                draw(word, alpha: alpha, lit: h, in: ctx)
                if let row = iconRows?[i], alpha > 0.004 {
                    ctx.saveGState()
                    ctx.setAlpha(min(1, alpha + 0.1 * shown))
                    ctx.draw(row.image, in: row.rect)
                    ctx.restoreGState()
                }
            case .digit(let i):
                let h = value(highlight, i)
                draw(word, alpha: (0.32 + 0.4 * h - 0.12 * recede(i)) * shown, lit: 0, in: ctx)
            case .centre:
                let c = CGFloat(cancelLit.value)
                draw(word, alpha: 0.5 * shown, lit: c, litAlpha: shown, in: ctx)
            }
        }
        drawHint(in: ctx, alpha: 0.95 * shown)
        ctx.restoreGState()
    }

    /// Draws `word` at `alpha`, crossfading to its lit picture by `lit`, `grow` times its rest size.
    private func draw(_ word: Drawn, alpha: CGFloat, lit l: CGFloat, litAlpha: CGFloat? = nil, grow: CGFloat = 1,
                      in ctx: CGContext) {
        let l = max(0, min(1, l))
        func put(_ still: Still, _ a: CGFloat, scale: CGFloat) {
            guard a > 0.004 else { return }
            ctx.saveGState()
            ctx.setAlpha(min(1, a))
            let r = still.rect
            ctx.draw(still.image, in: CGRect(x: r.midX - r.width * scale / 2, y: r.midY - r.height * scale / 2,
                                             width: r.width * scale, height: r.height * scale))
            ctx.restoreGState()
        }
        guard let lit = word.lit, l > 0.004 else {
            put(word.rest, alpha, scale: grow)
            return
        }
        put(word.rest, alpha * (1 - l), scale: grow)
        put(lit, (litAlpha ?? alpha) * l, scale: grow / lit.grown)
    }

    /// A very soft light under the button the pointer is on, with no edge.
    private func drawLight(in ctx: CGContext, shown: CGFloat) {
        for (role, k) in buttonIndex {
            let l = value(lit, k) * shown
            guard l > 0.01, let frame = layout.word(role)?.frame else { continue }
            let radius = max(frame.width, frame.height) * 0.8 + Self.lightReach * layout.scale
            let colors = [NSColor.white.withAlphaComponent(0.13 * l).cgColor, NSColor.white.withAlphaComponent(0.05 * l).cgColor,
                          NSColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { continue }
            let c = CGPoint(x: frame.midX, y: frame.midY)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        }
    }

    /// What releasing does, in plain words under the wheel, fitted to the hint's zone.
    private func drawHint(in ctx: CGContext, alpha: CGFloat) {
        let text = RadialMenu.hint(for: selection, in: wedges)
        if hint?.text != text {
            let fit = layout.fitHint(text)
            let prepared = PreparedText(fit, style: layout.hintStyle)
            let zone = layout.hintZone
            let frame = CGRect(x: zone.minX, y: zone.maxY - prepared.height, width: zone.width, height: prepared.height)
            hint = (text, Self.still(prepared, frame: frame, align: 0.5, scale: drawnScale, size: layout.scale))
        }
        guard let hint, alpha > 0.004 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(hint.still.image, in: hint.still.rect)
        ctx.restoreGState()
    }
}
