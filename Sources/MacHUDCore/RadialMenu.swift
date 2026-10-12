import AppKit
import HUDKit

// MARK: - The tree

/// One petal of the loadout wheel: a top petal (Apply Loadout, Capture, Park, Widgets), a
/// loadout, or an action. A petal with children unfolds them beyond it as the pointer reaches it;
/// an action is what releasing on it does. Pure data, built by `RadialMenu.tree`.
struct RadialNode: Equatable {
    enum Kind: Equatable {
        /// Apply Loadout: the loadouts unfold beyond it.
        case loadouts
        /// A loadout: its actions unfold beyond it.
        case loadout(String)
        /// `offersAllScreens`: whether it has the action that captures every display, which
        /// exists only while multi-desktop loadouts (experimental) are on.
        case capture(offersAllScreens: Bool)
        /// What Park and Restore act on, read as the wheel opens and again as Park is reached.
        case park(RadialMenu.ParkTargets)
        /// What Reveal and Edit toggle, read as the wheel opens.
        case widgets(RadialMenu.WidgetsState)
        /// A leaf: releasing on it does this.
        case action(RadialMenu.Outcome)

        /// The kind as the socket names it.
        var label: String {
            switch self {
            case .loadouts: return "loadouts"
            case .loadout: return "loadout"
            case .capture: return "capture"
            case .park: return "park"
            case .widgets: return "widgets"
            case .action: return "action"
            }
        }
    }

    /// Its step in a path (`loadouts/Messaging/apply`): fixed for the top petals and the
    /// actions, the loadout's name for a loadout.
    var id: String
    /// The word the wheel shows.
    var name: String
    var kind: Kind
    /// The line under the wheel while it is highlighted: what releasing does, or where to go on.
    var hint: String
    /// Its direction from the centre, clockwise from straight up, in radians: the same every
    /// time the wheel opens with the same petals (`RadialMenu.tree`).
    var angle: Double
    var icons: [NSImage] = []
    var hotkey: HotKey? = nil
    var children: [RadialNode] = []
    /// A loadout's row out from the centre (0 the innermost); 0 for every other petal.
    var row = 0

    var outcome: RadialMenu.Outcome? { if case .action(let o) = kind { return o } else { return nil } }
    var isLeaf: Bool { outcome != nil }
}

// MARK: - Controller

/// The loadout wheel: held open by its hotkey, centred on the cursor, click-through, its words
/// upright on one soft dark blur. It opens small, on four top petals (Apply Loadout, Capture,
/// Park and, while an app serves widgets, Widgets); the pointer's path unfolds what lies beyond
/// the petal it reaches (the loadouts beyond Apply Loadout, a loadout's actions beyond it).
/// Releasing on an action does it; anywhere else it cancels.
@MainActor
final class RadialMenu {
    /// What the park petal's actions act on, read as the wheel opens and again whenever the
    /// park petal is reached.
    struct ParkTargets: Equatable {
        /// The focused window's label ("Safari · Page title"); nil when nothing in front can
        /// be parked.
        var focused: String?
        /// The parked windows' labels.
        var parked: [String] = []
    }

    /// What the widgets petal's actions toggle, read as the wheel opens.
    struct WidgetsState: Equatable {
        /// The widgets are raised above the windows: Reveal reads Lower.
        var revealed = false
        /// The widgets are being edited: Edit reads Done.
        var editing = false
    }

    /// A loadout the wheel offers.
    struct LoadoutEntry {
        var name: String
        var icons: [NSImage] = []
        var hotkey: HotKey? = nil
    }

    enum Outcome: Equatable {
        case cancelled
        /// A loadout's Apply (`clear` false) or Clear + Apply (`clear` true).
        case apply(loadout: String, clear: Bool)
        /// Show what applying a loadout would do (nil: the active one). A loadout's Preview, or
        /// P anywhere.
        case preview(loadout: String?)
        /// Capture's This screen, or All screens while it offers every display.
        case capture(allScreens: Bool)
        /// Capture's Draw layout: open the editor on a fresh layout to draw.
        case drawLayout
        /// Park's Park (the focused window) or Restore (every parked window).
        case park(restore: Bool)
        /// Widgets' Reveal (`on`) or Lower, Edit (`on`) or Done. `on` is the state the action
        /// showed, read as the wheel opened: the app sets it rather than toggling the state it
        /// finds then.
        case widgets(edit: Bool, on: Bool)
    }

    // MARK: Building the tree

    nonisolated static let loadoutsID = "loadouts"
    nonisolated static let captureID = "capture"
    nonisolated static let parkID = "park"
    nonisolated static let widgetsID = "widgets"

    /// The top petals' directions: Apply Loadout up, Capture right, Park down, Widgets left.
    /// Each keeps its direction whether or not Widgets is there.
    nonisolated static let topAngles: [String: Double] = [loadoutsID: 0, captureID: .pi / 2, parkID: .pi, widgetsID: 3 * .pi / 2]
    /// Between neighbouring loadouts on a row.
    nonisolated static let loadoutStep = 30.0 * .pi / 180
    /// The farthest a loadout sits from straight up, either side: with half a step's room past
    /// it, the loadouts' arc stays 15° or more from Capture's and Widgets' directions.
    nonisolated static let loadoutSector = 60.0 * .pi / 180
    /// The rows' places, as multiples of `loadoutStep` from straight up, in the order they fill:
    /// five on a row (straight up, then 30° and 60° each side), four on the next between them
    /// (15° and 45° each side), alternating outward. Five labels side by side across the top are
    /// as many as the sector holds without pushing the row far out.
    nonisolated static let loadoutRows: [[Double]] = [[0, 1, -1, 2, -2], [0.5, -0.5, 1.5, -1.5]]
    /// Between neighbouring actions beyond Capture, Park or Widgets.
    nonisolated static let toolStep = 30.0 * .pi / 180
    /// Between a loadout's actions.
    nonisolated static let actionStep = 22.0 * .pi / 180

    /// Where each of `count` loadouts goes: its row (0 the innermost) and its angle from Apply
    /// Loadout's direction, filling `loadoutRows` in turn, so a loadout added at the end moves
    /// none of the others.
    nonisolated static func loadoutPlaces(_ count: Int) -> [(row: Int, offset: Double)] {
        var out: [(row: Int, offset: Double)] = []
        var row = 0
        while out.count < count {
            for place in loadoutRows[row % loadoutRows.count] where out.count < count {
                out.append((row, place * loadoutStep))
            }
            row += 1
        }
        return out
    }

    /// `count` angles `step` apart, centred on 0, in clockwise order.
    nonisolated static func spread(_ count: Int, step: Double) -> [Double] {
        (0..<count).map { (Double($0) - Double(count - 1) / 2) * step }
    }

    nonisolated private static func symbol(_ name: String) -> [NSImage] {
        [NSImage(systemSymbolName: name, accessibilityDescription: nil)].compactMap { $0 }
    }

    /// The wheel's tree: Apply Loadout with `loadouts` beyond it (each with Preview / Apply /
    /// Clear + Apply), Capture (This screen / Draw layout, with All screens between them when
    /// `offersAllScreens`), Park (Park / Restore) and, with a `widgets` state, Widgets
    /// (Reveal or Lower / Edit or Done).
    nonisolated static func tree(loadouts: [LoadoutEntry], offersAllScreens: Bool, park: ParkTargets,
                                 widgets: WidgetsState?) -> [RadialNode] {
        let up = topAngles[loadoutsID]!
        let entries = zip(loadouts, loadoutPlaces(loadouts.count)).map { entry, place in
            loadoutNode(entry, angle: RadialGeometry.normalized(up + place.offset), row: place.row)
        }
        var out = [
            RadialNode(id: loadoutsID, name: "Apply Loadout", kind: .loadouts,
                       hint: loadouts.isEmpty ? "No loadouts yet: capture one" : "Move out to a loadout",
                       angle: up, icons: symbol("rectangle.3.group"), children: entries),
            captureNode(offersAllScreens: offersAllScreens),
            parkNode(park),
        ]
        if let widgets { out.append(widgetsNode(widgets)) }
        return out
    }

    nonisolated static func loadoutNode(_ entry: LoadoutEntry, angle: Double, row: Int = 0) -> RadialNode {
        let name = entry.name
        let actions: [(String, String, String, Outcome)] = [
            ("preview", "Preview", "Preview \(name)", .preview(loadout: name)),
            ("apply", "Apply", "Apply \(name)", .apply(loadout: name, clear: false)),
            ("clear", "Clear + Apply", "Clear this screen and apply \(name)", .apply(loadout: name, clear: true)),
        ]
        return RadialNode(id: name, name: name, kind: .loadout(name), hint: "Move out to preview or apply \(name)",
                          angle: angle, icons: entry.icons, hotkey: entry.hotkey,
                          children: leaves(actions, around: angle, step: actionStep), row: row)
    }

    nonisolated private static func leaves(_ actions: [(id: String, name: String, hint: String, outcome: Outcome)],
                                           around angle: Double, step: Double) -> [RadialNode] {
        zip(actions, spread(actions.count, step: step)).map { action, offset in
            RadialNode(id: action.id, name: action.name, kind: .action(action.outcome), hint: action.hint,
                       angle: RadialGeometry.normalized(angle + offset))
        }
    }

    nonisolated static func captureNode(offersAllScreens: Bool) -> RadialNode {
        let angle = topAngles[captureID]!
        var actions: [(String, String, String, Outcome)] = [("screen", "This screen", "Capture this screen as a loadout", .capture(allScreens: false))]
        if offersAllScreens { actions.append(("all", "All screens", "Capture every screen as a loadout", .capture(allScreens: true))) }
        actions.append(("draw", "Draw layout", "Draw a new layout", .drawLayout))
        return RadialNode(id: captureID, name: "Capture", kind: .capture(offersAllScreens: offersAllScreens),
                          hint: "Move out to capture", angle: angle, icons: symbol("camera.viewfinder"),
                          children: leaves(actions, around: angle, step: toolStep))
    }

    nonisolated static func parkNode(_ targets: ParkTargets) -> RadialNode {
        let angle = topAngles[parkID]!
        let park = targets.focused.map { "Park \($0)" } ?? "Focus a window to park"
        let restore: String
        switch targets.parked.count {
        case 0: restore = targets.focused == nil ? "Focus a window to park" : "Nothing is parked"
        case 1: restore = "Restore \(targets.parked[0])"
        case let n: restore = "Restore \(n) parked windows"
        }
        return RadialNode(id: parkID, name: "Park", kind: .park(targets), hint: "Move out to park or restore", angle: angle,
                          icons: symbol("rectangle.portrait.and.arrow.right"),
                          children: leaves([("park", "Park", park, .park(restore: false)), ("restore", "Restore", restore, .park(restore: true))],
                                           around: angle, step: toolStep))
    }

    nonisolated static func widgetsNode(_ state: WidgetsState) -> RadialNode {
        let angle = topAngles[widgetsID]!
        let reveal = state.revealed ? ("Lower", "Lower widgets") : ("Reveal", "Reveal widgets")
        let edit = state.editing ? ("Done", "Finish editing widgets") : ("Edit", "Edit widgets")
        return RadialNode(id: widgetsID, name: "Widgets", kind: .widgets(state),
                          hint: "Move out to \(state.revealed ? "lower" : "reveal") or \(state.editing ? "finish editing" : "edit") widgets",
                          angle: angle, icons: symbol("square.grid.2x2"),
                          children: leaves([("reveal", reveal.0, reveal.1, .widgets(edit: false, on: !state.revealed)),
                                            ("edit", edit.0, edit.1, .widgets(edit: true, on: !state.editing))],
                                           around: angle, step: toolStep))
    }

    // MARK: Reading the tree

    /// The line under the wheel while nothing is highlighted.
    nonisolated static let idleHint = "Release on an action · centre cancels"

    nonisolated static func node(at path: [String], in tree: [RadialNode]) -> RadialNode? {
        var nodes = tree
        var found: RadialNode?
        for id in path {
            guard let next = nodes.first(where: { $0.id == id }) else { return nil }
            found = next
            nodes = next.children
        }
        return found
    }

    /// The line under the wheel while `path` is highlighted.
    nonisolated static func hint(for path: [String], in tree: [RadialNode]) -> String {
        node(at: path, in: tree)?.hint ?? idleHint
    }

    /// What releasing on `path` does: its action, or cancel anywhere else.
    nonisolated static func outcome(of path: [String], in tree: [RadialNode]) -> Outcome {
        node(at: path, in: tree)?.outcome ?? .cancelled
    }

    /// The loadout on `path`, if it runs through one.
    nonisolated static func loadout(on path: [String], in tree: [RadialNode]) -> String? {
        for k in path.indices {
            if case .loadout(let name)? = node(at: Array(path[...k]), in: tree)?.kind { return name }
        }
        return nil
    }

    /// `text` (`loadouts/Messaging/apply`) as a path in `tree`, nil when it names no node. A
    /// loadout's name may hold a `/`: each step takes the longest id that matches.
    nonisolated static func path(_ text: String, in tree: [RadialNode]) -> [String]? {
        var rest = Substring(text.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces)))
        var nodes = tree
        var path: [String] = []
        while !rest.isEmpty {
            let match = nodes.filter { rest == $0.id || rest.hasPrefix($0.id + "/") }.max { $0.id.count < $1.id.count }
            guard let match else { return nil }
            path.append(match.id)
            rest = rest.dropFirst(match.id.count).drop { $0 == "/" }
            nodes = match.children
        }
        return path.isEmpty ? nil : path
    }

    /// The petals the digits pick now: the children of the open branch (`RadialLayout.openBranch`),
    /// the top petals when none is open.
    nonisolated static func digitLevel(for path: [String], in tree: [RadialNode]) -> (branch: [String], ids: [String]) {
        var branch = path
        while let node = node(at: branch, in: tree), node.children.isEmpty { branch.removeLast() }
        let children = branch.isEmpty ? tree : node(at: branch, in: tree)?.children ?? tree
        return (branch, children.map(\.id))
    }

    /// Whether the park petal's targets are asked for again: the park petal has just been
    /// reached (`path` runs through it, `previous` did not). The wheel is click-through, so a
    /// click under it can change the focused window while it is open; asking again keeps the
    /// hint naming the window a release would park.
    nonisolated static func asksForParkTargets(highlighting path: [String], from previous: [String]) -> Bool {
        path.first == parkID && previous.first != parkID
    }

    /// `tree` with the park petal given `targets`; nil when that changes nothing.
    nonisolated static func refreshed(_ tree: [RadialNode], park targets: ParkTargets) -> [RadialNode]? {
        guard let i = tree.firstIndex(where: { $0.id == parkID }), case .park(let old) = tree[i].kind, old != targets else { return nil }
        var out = tree
        out[i] = parkNode(targets)
        return out
    }

    /// What a leaf does, as the socket names it.
    nonisolated static func actionName(_ outcome: Outcome) -> String {
        switch outcome {
        case .cancelled: return "cancel"
        case .apply(_, clear: false): return "apply"
        case .apply(_, clear: true): return "clearAndApply"
        case .preview: return "preview"
        case .capture(allScreens: false): return "captureScreen"
        case .capture(allScreens: true): return "captureAllScreens"
        case .drawLayout: return "drawLayout"
        case .park(restore: false): return "park"
        case .park(restore: true): return "restore"
        case .widgets(edit: false, on: true): return "revealWidgets"
        case .widgets(edit: false, on: false): return "lowerWidgets"
        case .widgets(edit: true, on: true): return "editWidgets"
        case .widgets(edit: true, on: false): return "finishEditingWidgets"
        }
    }

    /// The tree as the socket shows it, each node with its `id`, `path`, `name`, `kind`, `hint`,
    /// `angle`, the `radius` its word is anchored at, a loadout's `row` (1 the innermost), its `digit` among its siblings (1 to 9),
    /// the `icons` drawn by it, a loadout's `hotkey`, and its `children` or, for a leaf, its
    /// `action`; with a `selection`, what is highlighted and the hint showing. Also used to
    /// describe the wheel while it is hidden.
    static func json(tree: [RadialNode], layout: RadialLayout, selection: [String]? = nil) -> [String: Any] {
        func describe(_ node: RadialNode, parent: [String], digit: Int) -> [String: Any] {
            let path = parent + [node.id]
            var d: [String: Any] = ["id": node.id, "path": path.joined(separator: "/"), "name": node.name,
                                    "kind": node.kind.label, "hint": node.hint, "angle": node.angle]
            if let word = layout.word(path) { d["radius"] = Double(RadialGeometry.radius(of: word.anchor)) }
            if case .loadout = node.kind { d["row"] = node.row + 1 }
            if digit <= 9 { d["digit"] = digit }
            let icons = layout.icons(of: path)
            if icons > 0 { d["icons"] = icons }
            if let hk = node.hotkey { d["hotkey"] = hk.display }
            if let outcome = node.outcome {
                d["action"] = actionName(outcome)
            } else {
                d["children"] = node.children.enumerated().map { describe($1, parent: path, digit: $0 + 1) }
            }
            return d
        }
        var d: [String: Any] = [
            "deadZone": Double(layout.deadZone),
            "tree": tree.enumerated().map { describe($1, parent: [], digit: $0 + 1) },
        ]
        if let selection {
            if selection.isEmpty || node(at: selection, in: tree) == nil {
                d["selection"] = ["kind": "cancel", "hint": idleHint]
            } else {
                let node = node(at: selection, in: tree)!
                d["selection"] = ["kind": node.isLeaf ? "action" : "branch", "path": selection.joined(separator: "/"),
                                  "name": node.name, "hint": node.hint]
            }
        }
        return d
    }

    // MARK: State

    /// Called when the wheel closes on a release, an action key or a cancel.
    var onCommit: ((Outcome) -> Void)?
    /// Called whenever a visible wheel goes away, however it was dismissed.
    var onDismiss: (() -> Void)?
    /// Reads the park petal's targets and calls back with them on the main thread
    /// (`asksForParkTargets`). It must not wait for the answer on the main thread: the
    /// Accessibility calls behind it can take a hung app's timeout.
    var readParkTargets: ((@escaping @MainActor @Sendable (ParkTargets) -> Void) -> Void)?
    /// Counts the wheel's openings: an answer about the park petal from an earlier one is not used.
    private var opening = 0
    /// A read of the park petal's targets has been asked for and not answered.
    private var parkTargetsAsked = false
    /// The park petal was reached again while a read was out: that read's answer is older
    /// than the highlight, so it is not used, and the wheel asks again as it lands.
    private var parkTargetsStale = false

    private(set) var tree: [RadialNode] = []
    private(set) var layout = RadialLayout(tree: [])
    /// The path highlighted: empty for none (the centre).
    private(set) var selection: [String] = []
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
    /// The fields of the last layout, built as its branches open: every one covers `whole`'s
    /// rectangle.
    private var fields: (layout: RadialLayout, reduced: Bool, whole: RadialField, open: [[String]: RadialField])?
    /// The last layout made: a wheel with the same words in the same room opens with it.
    private var laidOut: (key: LayoutKey, layout: RadialLayout)?

    /// What a layout is made from: each node's path, word, icon count and direction, and the room.
    struct LayoutKey: Equatable {
        var words: [String]
        var room: CGSize

        init(_ tree: [RadialNode], room: CGSize) {
            func walk(_ nodes: [RadialNode], _ parent: [String]) -> [String] {
                nodes.flatMap { node -> [String] in
                    let path = parent + [node.id]
                    return ["\(path)\u{1}\(node.name)\u{1}\(min(node.icons.count, RadialLayout.maxIcons))\u{1}\(node.angle)"]
                        + walk(node.children, path)
                }
            }
            words = walk(tree, [])
            self.room = room
        }
    }

    /// The wheel's centre, in screen coordinates.
    private(set) var center: CGPoint = .zero
    private var screenFrame: CGRect = .zero
    private var pointerOffset: CGPoint = .zero   // relative to the wheel's centre
    /// A path picked by a digit or the socket: it holds until the pointer leaves the dead zone.
    private var keyboardPath: [String]?
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

    /// The screen a wheel opens on, in screen coordinates; `primaryHeight` is the height of the
    /// primary display (the one at the origin), which turns screen points into display points
    /// (`ScreenCoords.axPoint(fromCocoa:primaryHeight:)`).
    struct Display: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
        var primaryHeight: CGFloat
    }

    // MARK: Lifecycle

    func show(tree: [RadialNode], at point: CGPoint? = nil) {
        guard !tree.isEmpty else { return }
        let origin = point ?? NSEvent.mouseLocation
        let screens = NSScreen.screens
        guard let index = ScreenCoords.screenIndex(containing: origin, frames: screens.map(\.frame)) else { return }
        let screen = screens[index]
        let display = Display(frame: screen.frame, visibleFrame: screen.visibleFrame,
                              primaryHeight: NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY)
        // Opened at the pointer (the hotkey), the wheel moves the pointer to its centre when
        // it cannot open around it; opened by a script at a point, it leaves the pointer alone.
        prepare(tree: tree, at: origin, on: display, movesPointer: point == nil)

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
    func prepare(tree: [RadialNode], at origin: CGPoint, on display: Display, movesPointer: Bool) {
        self.tree = tree
        let room = display.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let key = LayoutKey(tree, room: room.size)
        let layout = laidOut?.key == key ? laidOut!.layout : RadialLayout.fitting(tree, in: room.size)
        laidOut = (key, layout)
        self.layout = layout
        center = Self.centre(of: layout, at: origin, room: room)
        screenFrame = display.frame
        pointerOffset = .zero
        pointerHasMoved = false
        firstReport = nil
        opening += 1
        parkTargetsAsked = false
        parkTargetsStale = false
        keyboardPath = nil
        selection = []
        applyLayout()
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

    /// What releasing does now: the action highlighted, or cancel.
    var releaseOutcome: Outcome { Self.outcome(of: selection, in: tree) }

    /// The hotkey was released: do the action highlighted, else cancel.
    func commit() {
        guard isVisible else { return }
        let outcome = releaseOutcome
        hide()
        onCommit?(outcome)
    }

    /// Highlights `path` without the mouse (digits, and the control socket): its branch opens
    /// as if the pointer had reached it, and it holds until the pointer leaves the dead zone.
    /// False when the tree has no such path.
    @discardableResult
    func select(path: [String]) -> Bool {
        guard Self.node(at: path, in: tree) != nil else { return false }
        keyboardPath = path
        highlight(path)
        return true
    }

    var json: [String: Any] {
        var d = Self.json(tree: tree, layout: layout, selection: selection)
        d["visible"] = isVisible
        d["center"] = ["x": Int(center.x), "y": Int(center.y)]
        return d
    }

    // MARK: Placement

    /// Room kept between the wheel's words and the edge of the screen's visible frame.
    static let screenMargin: CGFloat = 8

    /// The wheel's layout and centre (screen coordinates) for a wheel opened at `pointer` on a
    /// screen whose visible frame (less the menu bar and the Dock) is `visibleFrame`: full size
    /// where it fits, smaller where it would not, and moved in from the edges so every word that
    /// can show and the hint are on screen, whichever branches open. The field may fade out past
    /// the edge.
    static func place(tree: [RadialNode], at pointer: CGPoint, visibleFrame: CGRect) -> (layout: RadialLayout, center: CGPoint) {
        let room = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let layout = RadialLayout.fitting(tree, in: room.size)
        return (layout, centre(of: layout, at: pointer, room: room))
    }

    /// Where `layout`'s centre goes for a wheel opened at `pointer`: there, or moved in from
    /// the edges of `room` so every word and the hint are inside it.
    static func centre(of layout: RadialLayout, at pointer: CGPoint, room: CGRect) -> CGPoint {
        let b = layout.bounds
        return CGPoint(x: min(max(pointer.x, room.minX - b.minX), room.maxX - b.maxX),
                       y: min(max(pointer.y, room.minY - b.minY), room.maxY - b.maxY))
    }

    /// The wheel's views on the canvas of every word's field, which follows Reduce transparency,
    /// and the words of the layout.
    private func applyLayout() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if fields?.layout != layout || fields?.reduced != reduced {
            fields = (layout, reduced, RadialField(layout: layout, reduced: reduced), [:])
        }
        let canvas = fields!.whole.canvas
        let local = CGRect(x: center.x - screenFrame.minX - canvas.center.x, y: center.y - screenFrame.minY - canvas.center.y,
                           width: canvas.size.width, height: canvas.size.height)
        backdrop.view.frame = local
        tint.frame = local
        wheel.frame = local
        wheel.configure(layout: layout, canvas: canvas, tree: tree)
        wheel.selection = selection
        applyField()
    }

    /// The field of the branch open now, over the whole field's rectangle.
    func field(open: [String]) -> RadialField? {
        guard var fields else { return nil }
        let branch = layout.openBranch(open)
        if let field = fields.open[branch] { return field }
        let field = RadialField(shape: RadialField.Shape(layout: layout, open: branch, reduced: fields.reduced),
                                over: fields.whole.support)
        fields.open[branch] = field
        self.fields = fields
        return field
    }

    /// Shows the field of the branch open now under the words.
    private func applyField() {
        guard let field = field(open: selection) else { return }
        backdrop.show(field: field.blurImage)
        tint.image = field.tintImage
    }

    // MARK: Selection

    /// Highlights `path`: the branches along it open (their field with them) and the park petal,
    /// newly reached, asks for its targets again.
    private func highlight(_ path: [String]) {
        guard path != selection else { return }
        let previous = selection
        selection = path
        wheel.selection = path
        if layout.openBranch(path) != layout.openBranch(previous) { applyField() }
        noteHighlight(from: previous)
    }

    private func refreshSelection() {
        if let keyboardPath {
            highlight(keyboardPath)
        } else {
            highlight(layout.selection(at: pointerOffset, open: selection))
        }
    }

    /// The park petal asks for its targets again as it is reached (`asksForParkTargets`).
    private func noteHighlight(from previous: [String]) {
        guard Self.asksForParkTargets(highlighting: selection, from: previous) else { return }
        // One read out at a time: a highlight while one is out makes its answer too old to use.
        if parkTargetsAsked { parkTargetsStale = true } else { askForParkTargets() }
    }

    /// Asks for the park petal's targets; the answer replaces them while the park petal is still
    /// on the path in the same opening, unless it was reached again meanwhile, when the wheel
    /// asks again instead.
    private func askForParkTargets() {
        guard let read = readParkTargets else { return }
        parkTargetsAsked = true
        let asked = opening
        read { [weak self] targets in
            guard let self, self.opening == asked else { return }
            self.parkTargetsAsked = false
            let highlighted = self.selection.first == Self.parkID
            if self.parkTargetsStale {
                self.parkTargetsStale = false
                if highlighted { self.askForParkTargets() }
                return
            }
            // Only while the park petal is still on the path: its hints are the ones that show.
            guard highlighted, let fresh = Self.refreshed(self.tree, park: targets) else { return }
            self.tree = fresh
            self.wheel.update(tree: fresh)
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
        if RadialGeometry.radius(of: o) >= layout.deadZone { keyboardPath = nil }
        pointerOffset = o
        refreshSelection()
    }

    // MARK: Tracking

    private func startTracking() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
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
            MainActor.assumeIsolated { if self?.isVisible == true { self?.applyLayout() } }
        }
    }

    private func handle(_ event: NSEvent) {
        pointerMoved(to: NSEvent.mouseLocation, delta: CGVector(dx: event.deltaX, dy: event.deltaY))
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

    /// Esc cancels; P previews the loadout on the path (the active one where there is none);
    /// a digit picks that petal among the ones showing at the open branch. Returns true when
    /// the key was consumed.
    func handleKeyCode(_ code: UInt32) -> Bool {
        if code == HotKeyCenter.keyCode(for: "escape") {
            cancel()
            return true
        }
        if code == HotKeyCenter.keyCode(for: "p") {
            let name = Self.loadout(on: selection, in: tree)
            hide()
            onCommit?(.preview(loadout: name))
            return true
        }
        for digit in 1...9 where code == HotKeyCenter.keyCode(for: "\(digit)") {
            let level = Self.digitLevel(for: selection, in: tree)
            guard level.ids.indices.contains(digit - 1) else { return true }
            select(path: level.branch + [level.ids[digit - 1]])
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
/// glow, at its grown size); a frame draws those pictures at the springs' strengths, and the
/// hint again only when it changes. A branch's children fade in sliding out from the centre as
/// it opens, and fade out as it closes.
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
        /// How many times its size it grows lit (`RadialLayout.Word.grow`), from `anchor`.
        var grow: CGFloat = 1
        var anchor: CGPoint
    }

    /// The most a petal grows under the pointer, from its anchor; each grows as far as the
    /// words showing with it allow (`RadialLayout.Word.grow`).
    nonisolated static let grow: CGFloat = 1.25
    /// How far a lit word's glow reaches past its box, at full size. The field's blur is full a
    /// little further out (`RadialField.pad`).
    nonisolated static let glowReach: CGFloat = 14
    /// How far the light under a hovered petal reaches past most of its box, at full size: as
    /// far as the full blur around a lone word.
    nonisolated static let lightReach: CGFloat = RadialField.pad
    /// How far a branch's children slide out as they unfold, at full size.
    static let unfold: CGFloat = 14

    /// Called with how far the wheel has faded in (0...1), for the tint under it.
    var onShown: ((CGFloat) -> Void)?

    private var layout = RadialLayout(tree: [])
    private var tree: [RadialNode] = []
    private var origin: CGPoint = .zero
    /// The words drawn, at `drawnScale` pixels per point (0: not yet).
    private var drawn: [Drawn] = []
    private var drawnScale: CGFloat = 0
    private var drawnAppearance: NSAppearance.Name?
    /// How many times the words have been drawn into their pictures (tests).
    private(set) var wordRenders = 0
    /// Each petal's icons in a row, by path, drawn once per configuration (the icons are the
    /// tree's, which a new configuration brings anew); nil until drawn.
    private var iconRows: [[String]: Still]?
    private var hint: (text: String, zone: CGRect, still: Still)?

    /// Every petal's path, in the layout's order, and its place in the springs.
    private var paths: [[String]] = []
    private var slot: [[String]: Int] = [:]
    /// The petals under each branch, by the branch's path.
    private var family: [[String]: [[String]]] = [:]
    /// Per petal: showing (its branch is open), on the highlighted path, the one highlighted.
    private var shown: [Spring] = []
    private var onPath: [Spring] = []
    private var lit: [Spring] = []
    private var cancelLit = Spring(1)
    private var appear = Spring(1)

    var selection: [String] = [] {
        didSet { guard selection != oldValue else { return }; retarget(); needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(layout: RadialLayout, canvas: RadialMenu.Canvas, tree: [RadialNode]) {
        // The words are drawn again only for a new layout: they depend on it, the backing scale
        // and the appearance alone.
        if layout != self.layout {
            drawn = []
            drawnScale = 0
        }
        self.layout = layout
        self.tree = tree
        origin = canvas.center
        iconRows = nil
        hint = nil
        let paths = layout.words.compactMap(\.role.path)
        if paths != self.paths {
            self.paths = paths
            slot = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
            family = Dictionary(grouping: paths) { Array($0.dropLast()) }
            shown = paths.map { _ in Spring(0) }
            onPath = paths.map { _ in Spring(0) }
            lit = paths.map { _ in Spring(0) }
        }
        retarget()
        needsDisplay = true
    }

    /// The same wheel with nodes whose kinds changed but whose words did not (the park petal's
    /// targets): only the hint changes.
    func update(tree: [RadialNode]) {
        self.tree = tree
        needsDisplay = true
    }

    func resetSprings() {
        shown = paths.map { _ in Spring(0) }
        onPath = paths.map { _ in Spring(0) }
        lit = paths.map { _ in Spring(0) }
        cancelLit = Spring(selection.isEmpty ? 1 : 0)
        appear = Spring(0)
        appear.target = 1
        onShown?(0)
        retarget()
        // The top petals are there as the wheel fades in; only what unfolds later slides out.
        for (k, path) in paths.enumerated() where path.count == 1 { shown[k].jump(to: shown[k].target) }
        needsDisplay = true
    }

    /// At rest with `selection` highlighted, as if the springs had settled (snapshots).
    func settle(selection: [String]) {
        self.selection = selection
        retarget()
        for springs in [\RadialWheelView.shown, \.onPath, \.lit] as [ReferenceWritableKeyPath<RadialWheelView, [Spring]>] {
            for i in self[keyPath: springs].indices { self[keyPath: springs][i].jump(to: self[keyPath: springs][i].target) }
        }
        cancelLit.jump(to: cancelLit.target)
        appear.jump(to: 1)
        onShown?(1)
        needsDisplay = true
    }

    private func retarget() {
        let showing = Set(layout.showing(open: layout.openBranch(selection)))
        for (k, path) in paths.enumerated() {
            shown[k].target = showing.contains(path) ? 1 : 0
            onPath[k].target = !selection.isEmpty && selection.starts(with: path) ? 1 : 0
            lit[k].target = path == selection ? 1 : 0
        }
        cancelLit.target = selection.isEmpty ? 1 : 0
    }

    private var springs: [Spring] { shown + onPath + lit + [cancelLit, appear] }

    /// Whether a spring is still moving.
    var isMoving: Bool { springs.contains { $0.value != $0.target || $0.velocity != 0 } }

    /// Steps the springs; redraws only while something moves.
    func tick() {
        let dt = 1.0 / 120.0
        let before = springs
        _ = appear.step(dt: dt, stiffness: 320, damping: 0.62, epsilon: 0.002)
        _ = cancelLit.step(dt: dt, stiffness: 420, damping: 0.7, epsilon: 0.002)
        for i in shown.indices { _ = shown[i].step(dt: dt, stiffness: 520, damping: 0.8, epsilon: 0.002) }
        for i in onPath.indices { _ = onPath[i].step(dt: dt, stiffness: 420, damping: 0.66, epsilon: 0.002) }
        for i in lit.indices { _ = lit[i].step(dt: dt, stiffness: 380, damping: 0.55, epsilon: 0.002) }
        if appear.value != before[before.count - 1].value { onShown?(faded) }
        if springs != before { needsDisplay = true }
    }

    private var faded: CGFloat { max(0, min(1, CGFloat(appear.value) * 1.4)) }

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
        drawn = layout.words.map { word -> Drawn in
            let text = PreparedText(word.fit, style: word.style)
            switch word.role {
            case .node:
                return Drawn(role: word.role,
                             rest: Self.still(text, frame: word.frame, align: word.align, anchor: word.anchor, scale: scale, size: s),
                             lit: Self.still(text, frame: word.frame, align: word.align, anchor: word.anchor, scale: scale, size: s,
                                             glow: true, grow: word.grow),
                             grow: word.grow, anchor: word.anchor)
            case .digit:
                return Drawn(role: word.role, rest: Self.still(text, frame: word.frame, align: 0.5, anchor: word.anchor, scale: scale, size: s),
                             lit: nil, anchor: word.anchor)
            case .centre:
                let escape = PreparedText(TextFit(lines: ["Esc"], size: word.style.preferred - 1.5 * s, truncated: false), style: word.style)
                return Drawn(role: word.role, rest: Self.still(escape, frame: word.frame, align: 0.5, anchor: word.anchor, scale: scale, size: s),
                             lit: Self.still(text, frame: word.frame, align: 0.5, anchor: word.anchor, scale: scale, size: s, glow: true),
                             anchor: word.anchor)
            }
        }
        drawnScale = scale
        drawnAppearance = effectiveAppearance.name
        wordRenders += 1
        iconRows = nil
        hint = nil
    }

    /// Each petal's icons in a row under its lines, with the words' soft dark shadow.
    private func prepareIcons(scale: CGFloat) {
        var rows: [[String]: Still] = [:]
        for word in layout.words {
            guard let path = word.role.path, word.icons > 0, let node = RadialMenu.node(at: path, in: tree) else { continue }
            rows[path] = Self.still(nil, frame: word.frame, align: word.align, anchor: word.anchor, scale: scale, size: layout.scale,
                                    icons: Array(node.icons.prefix(word.icons)))
        }
        iconRows = rows
    }

    /// `text` in white inside `frame` (its lines from the top, placed across by `align`), or a
    /// petal's `icons` in a row at the frame's foot, with a soft dark shadow and, when `glow`, a
    /// white glow, `grow` times its size from `anchor`: rendered at `scale` pixels per point,
    /// the shadows sized for wheel scale `size`.
    private static func still(_ text: PreparedText?, frame: CGRect, align: CGFloat, anchor: CGPoint, scale: CGFloat, size s: CGFloat,
                              icons: [NSImage] = [], glow: Bool = false, grow: CGFloat = 1) -> Still {
        let margin = (glow ? glowReach : 6) * s
        let grown = RadialLayout.grown(frame, by: grow, about: anchor)
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
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.scaleBy(x: grow, y: grow)
            ctx.translateBy(x: -anchor.x, y: -anchor.y)
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

    private func value(_ springs: [Spring], _ path: [String]) -> CGFloat {
        guard let k = slot[path], springs.indices.contains(k) else { return 0 }
        return CGFloat(springs[k].value)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !tree.isEmpty else { return }
        if drawnScale != backingScale || drawnAppearance != effectiveAppearance.name { prepare(scale: backingScale) }
        if iconRows == nil { prepareIcons(scale: backingScale) }
        let faded = self.faded
        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.interpolationQuality = .high
        let grow = 0.9 + 0.1 * CGFloat(appear.value)
        ctx.scaleBy(x: grow, y: grow)
        drawLight(in: ctx, faded: faded)
        // How deep the path reaches, eased with the springs.
        let depth = paths.reduce(CGFloat(0)) { max($0, CGFloat($1.count) * value(onPath, $1)) }
        for word in drawn {
            switch word.role {
            case .node(let path):
                let unfolded = max(0, min(1, value(shown, path)))
                guard unfolded > 0.004 else { continue }
                let h = value(onPath, path), l = value(lit, path)
                // Siblings of the petal on the path step back, the more so once the path has
                // gone on past them.
                let siblings = family[Array(path.dropLast())] ?? []
                let recede = max(0, (siblings.map { value(onPath, $0) }.max() ?? 0) - h)
                let beyond = recede * CGFloat(max(0, min(1, depth - CGFloat(path.count))))
                let alpha = (0.86 + 0.14 * h - 0.3 * recede - 0.22 * beyond) * faded * unfolded
                // Sliding out from the centre as it unfolds.
                let a = RadialGeometry.angle(of: word.anchor)
                let slide = RadialGeometry.point(-Self.unfold * layout.scale * (1 - unfolded), a)
                ctx.saveGState()
                ctx.translateBy(x: slide.x, y: slide.y)
                draw(word, alpha: alpha, lit: max(l, 0.5 * h), grow: 1 + (word.grow - 1) * l, in: ctx)
                if let row = iconRows?[path], alpha > 0.004 {
                    let g = 1 + (word.grow - 1) * l
                    ctx.saveGState()
                    ctx.setAlpha(min(1, alpha + 0.1 * faded * unfolded))
                    ctx.draw(row.image, in: RadialLayout.grown(row.rect, by: g, about: word.anchor))
                    ctx.restoreGState()
                }
                ctx.restoreGState()
            case .digit(let i):
                guard tree.indices.contains(i) else { continue }
                let path = [tree[i].id]
                let h = value(onPath, path)
                let others = tree.map { value(onPath, [$0.id]) }.max() ?? 0
                draw(word, alpha: (0.32 + 0.4 * h - 0.12 * max(0, others - h)) * faded, lit: 0, in: ctx)
            case .centre:
                let c = CGFloat(cancelLit.value)
                draw(word, alpha: 0.5 * faded, lit: c, litAlpha: faded, in: ctx)
            }
        }
        drawHint(in: ctx, alpha: 0.95 * faded)
        ctx.restoreGState()
    }

    /// Draws `word` at `alpha`, crossfading to its lit picture by `lit`, `grow` times its rest
    /// size from its anchor.
    private func draw(_ word: Drawn, alpha: CGFloat, lit l: CGFloat, litAlpha: CGFloat? = nil, grow: CGFloat = 1,
                      in ctx: CGContext) {
        let l = max(0, min(1, l))
        func put(_ still: Still, _ a: CGFloat, scale: CGFloat) {
            guard a > 0.004 else { return }
            ctx.saveGState()
            ctx.setAlpha(min(1, a))
            ctx.draw(still.image, in: RadialLayout.grown(still.rect, by: scale, about: word.anchor))
            ctx.restoreGState()
        }
        guard let lit = word.lit, l > 0.004 else {
            put(word.rest, alpha, scale: grow)
            return
        }
        put(word.rest, alpha * (1 - l), scale: grow)
        put(lit, (litAlpha ?? alpha) * l, scale: grow / lit.grown)
    }

    /// A very soft light under the petal highlighted, with no edge.
    private func drawLight(in ctx: CGContext, faded: CGFloat) {
        for (k, path) in paths.enumerated() {
            let l = CGFloat(lit[k].value) * faded
            guard l > 0.01, let word = layout.word(path) else { continue }
            let frame = word.frame
            let radius = max(frame.width, frame.height) * 0.8 + Self.lightReach * layout.scale
            let colors = [NSColor.white.withAlphaComponent(0.13 * l).cgColor, NSColor.white.withAlphaComponent(0.05 * l).cgColor,
                          NSColor.white.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) else { continue }
            let c = CGPoint(x: frame.midX, y: frame.midY)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        }
    }

    /// What releasing does, in plain words under the words showing, fitted to the hint's zone.
    private func drawHint(in ctx: CGContext, alpha: CGFloat) {
        let text = RadialMenu.hint(for: selection, in: tree)
        let zone = layout.hintZone(open: selection)
        if hint?.text != text || hint?.zone != zone {
            let fit = TextFit.fit(text, style: layout.hintStyle, width: zone.width)
            let prepared = PreparedText(fit, style: layout.hintStyle)
            let frame = CGRect(x: zone.minX, y: zone.maxY - prepared.height, width: zone.width, height: prepared.height)
            hint = (text, zone, Self.still(prepared, frame: frame, align: 0.5, anchor: CGPoint(x: frame.midX, y: frame.maxY),
                                           scale: drawnScale, size: layout.scale))
        }
        guard let hint, alpha > 0.004 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(hint.still.image, in: hint.still.rect)
        ctx.restoreGState()
    }
}
