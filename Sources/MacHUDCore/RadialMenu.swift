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
    /// time the wheel opens with the same petals (`RadialMenu.tree`). An action's only orders it
    /// among its siblings: `RadialLayout` places it as a leaf beside its branch, and the
    /// direction the centre sees it in is its petal's (`RadialLayout.petal(_:)`).
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

/// The loadout wheel: held open by its hotkey, centred on the cursor, click-through, each of its
/// words upright in its own glass bubble (`RadialWheelView`). It opens small, on four top petals
/// (Apply Loadout, Capture, Park and, while an app serves widgets, Widgets); the pointer's path
/// unfolds what lies beyond the petal it reaches (the loadouts beyond Apply Loadout, a loadout's
/// actions beyond it). Releasing on an action does it; anywhere else it cancels.
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
    /// Between neighbouring actions of a branch (a loadout's, Capture's, Park's or Widgets'), in
    /// the tree: it orders them clockwise about the branch's direction.
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
                          children: leaves(actions, around: angle), row: row)
    }

    /// `actions` as leaves fanning out about `angle`, their branch's direction.
    nonisolated private static func leaves(_ actions: [(id: String, name: String, hint: String, outcome: Outcome)],
                                           around angle: Double) -> [RadialNode] {
        zip(actions, spread(actions.count, step: actionStep)).map { action, offset in
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
                          children: leaves(actions, around: angle))
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
                                           around: angle))
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
                                           around: angle))
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
            // Where the centre sees it: an action sits beside its branch, wherever its place among
            // its siblings puts it.
            var d: [String: Any] = ["id": node.id, "path": path.joined(separator: "/"), "name": node.name,
                                    "kind": node.kind.label, "hint": node.hint, "angle": layout.petal(path)?.angle ?? node.angle]
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
    private var monitors: [Any] = []
    private var keyTap: CFMachPort?
    private var keyMonitor: Any?
    /// The last layout made, and the extent it is placed by: a wheel with the same words in the
    /// same room opens with them.
    private var laidOut: (key: LayoutKey, layout: RadialLayout, extent: CGRect)?

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
        // Opened by the hotkey, the wheel moves the pointer to its centre; opened by a script, on
        // the screen holding the point it gave, it leaves the pointer alone.
        prepare(tree: tree, at: NSEvent.mouseLocation, on: display, movesPointer: point == nil)

        let w = window ?? makeWindow()
        if w.frame != screenFrame { w.setFrame(screenFrame, display: false) }
        w.orderFrontRegardless()

        startTracking()
        wheel.open()
    }

    /// Sets the wheel up to open on `display`, in the middle of it as far as its rows of loadouts
    /// leave room (`centre(of:in:)`), with nothing selected and
    /// the pointer taken to be at the centre until it moves. When `movesPointer`, the pointer (at
    /// `pointer`) is moved to the wheel's centre, so a gesture means the same direction from the
    /// centre every time; it is not moved back. No window is shown and no event is watched.
    func prepare(tree: [RadialNode], at pointer: CGPoint, on display: Display, movesPointer: Bool) {
        self.tree = tree
        let room = display.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let key = LayoutKey(tree, room: room.size)
        let fitted = laidOut?.key == key ? (laidOut!.layout, laidOut!.extent) : RadialLayout.fitting(tree, in: room.size)
        laidOut = (key, fitted.0, fitted.1)
        self.layout = fitted.0
        center = Self.centre(of: fitted.1, in: room)
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
        if movesPointer, hypot(center.x - pointer.x, center.y - pointer.y) > 0.5 {
            warpPointer(ScreenCoords.axPoint(fromCocoa: center, primaryHeight: display.primaryHeight))
        }
    }

    func hide() {
        let wasVisible = isVisible
        stopTracking()
        wheel.close()
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

    /// The wheel's layout and centre (screen coordinates) on a screen whose visible frame (less
    /// the menu bar and the Dock) is `visibleFrame`: at the screen's size (`RadialLayout.fitting`),
    /// in the middle of it as far as its rows of loadouts leave room (`centre(of:in:)`).
    static func place(tree: [RadialNode], visibleFrame: CGRect) -> (layout: RadialLayout, center: CGPoint) {
        let room = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        let fitted = RadialLayout.fitting(tree, in: room.size)
        return (fitted.layout, centre(of: fitted.extent, in: room))
    }

    /// Where the wheel's centre goes: the middle of `room`, moved only as far as keeps `extent`
    /// (the wheel's, about its centre) inside it. The extent is that of the rows of loadouts in
    /// use, so up to `RadialLayout.fittedRows` rows the wheel moves only when a new row needs
    /// the room: down, and a little sideways where the rows fill the screen's width. An extent
    /// too big for `room` is centred on it.
    static func centre(of extent: CGRect, in room: CGRect) -> CGPoint {
        func axis(_ low: CGFloat, _ high: CGFloat, _ near: CGFloat, _ far: CGFloat) -> CGFloat {
            guard far - near <= high - low else { return (low + high - near - far) / 2 }
            return min(max((low + high) / 2, low - near), high - far)
        }
        return CGPoint(x: axis(room.minX, room.maxX, extent.minX, extent.maxX).rounded(),
                       y: axis(room.minY, room.maxY, extent.minY, extent.maxY).rounded())
    }

    /// The wheel's view on the canvas of the layout's words, centred where the wheel's centre is.
    private func applyLayout() {
        let canvas = RadialWheelView.canvas(for: layout)
        wheel.frame = CGRect(x: center.x - screenFrame.minX - canvas.center.x, y: center.y - screenFrame.minY - canvas.center.y,
                             width: canvas.size.width, height: canvas.size.height)
        wheel.configure(layout: layout, canvas: canvas, tree: tree, selection: selection)
    }

    // MARK: Selection

    /// Highlights `path`: the branches along it open and the park petal, newly reached, asks for
    /// its targets again. The wheel's bubbles follow; nothing here waits for them.
    private func highlight(_ path: [String]) {
        guard path != selection else { return }
        let previous = selection
        selection = path
        wheel.selection = path
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
    }

    private func handle(_ event: NSEvent) {
        pointerMoved(to: NSEvent.mouseLocation, delta: CGVector(dx: event.deltaX, dy: event.deltaY))
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

    // MARK: Window

    func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        // The words are white on dark glass: dark in a light system appearance too, so the
        // glass's tint, and the system's material it shows with Reduce transparency on, are the
        // dark ones.
        w.appearance = NSAppearance(named: .darkAqua)
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        // Made without defer, so the window server's blur under the bubbles (`HUDGlassView`) is
        // set on it before it first shows.
        let content = NSView(frame: .zero)
        content.addSubview(wheel)
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
