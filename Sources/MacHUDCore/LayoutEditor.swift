import AppKit
import HUDKit

// MARK: - Controller

/// Full-screen visual editor for layouts. Works on an editing copy of the config
/// and writes it back through the store on Save.
final class LayoutEditorController: NSObject {
    private let store: LayoutStore
    private var window: EditorWindow?
    private var view: EditorView?
    var onClose: (() -> Void)?
    /// Supplies registered panel ids at the moment the editor opens (set by main.swift
    /// once panels — stream D — are registered).
    var panelChoicesProvider: (() -> [PanelChoice])?
    /// Captures what is on screen for a layout (wired to the loadout engine), so new
    /// loadouts in the editor start with the current arrangement.
    var captureProvider: ((Layout) -> [Slot])?
    /// The desktop widgets, shown and moved in the editor (the widget layer).
    weak var widgets: LayoutEditorWidgets?

    var isOpen: Bool { window != nil }

    init(store: LayoutStore) {
        self.store = store
    }

    /// Open on a loadout's layout with that loadout selected, so its regions and
    /// occupants are what is being edited ("Edit Layout" on a loadout).
    func open(loadout name: String) {
        guard let loadout = store.loadout(named: name) else { open(); return }
        let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        let descriptors = NSScreen.screens.map(\.descriptor)
        let position = screen.flatMap { NSScreen.screens.firstIndex(of: $0) }
        // A per-display loadout edits the layout of the display under the mouse.
        let layoutName = (loadout.screens ?? []).first { $0.screen.index(in: descriptors) == position }?.layout
            ?? loadout.layout
        if let i = store.layouts.firstIndex(where: { $0.name == layoutName }) { store.select(index: i) }
        open()
        guard let view, view.layout?.name == layoutName else { return }
        view.selectedLoadoutName = name
    }

    /// Open on a new, empty layout ("Layout N") to draw regions from scratch; Save keeps it
    /// and makes it the snap layout.
    func openNew() { open(newLayout: true) }

    func open(newLayout: Bool = false) {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
        let w = EditorWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)

        var config = store.config
        var index = min(UserDefaults.standard.integer(forKey: "activeLayout"), max(store.layouts.count - 1, 0))
        if newLayout || config.layouts.isEmpty {
            // Blank canvas to draw on.
            var n = config.layouts.count + 1
            while config.layouts.contains(where: { $0.name == "Layout \(n)" }) { n += 1 }
            config.layouts.append(Layout(name: "Layout \(n)", regions: []))
            index = config.layouts.count - 1
        }

        let v = EditorView(frame: CGRect(origin: .zero, size: screen.frame.size))
        v.screenOrigin = screen.frame.origin
        v.visible = screen.visibleFrame.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)
        v.config = config
        v.layoutIndex = index
        v.panelChoices = panelChoicesProvider?() ?? []
        v.captureProvider = captureProvider
        v.widgetSource = widgets
        let loadoutsAtOpen = config.loadouts
        v.onSave = { [weak self] config, layoutIndex in
            guard let self else { return }
            self.store.save(Self.saved(config, current: self.store.config, loadoutsAtOpen: loadoutsAtOpen))
            self.store.select(index: layoutIndex)
            self.close()
        }
        v.onCancel = { [weak self] in self?.close() }
        w.contentView = v
        window = w
        view = v

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        v.buildPanel()
        v.reloadWidgets()
    }

    /// What Save writes: the editor's copy of the config, with the loadouts as they are now
    /// when the editor left them untouched (captured or applied meanwhile), and always the
    /// widgets as they are now: the editor changes widgets through the widget layer at once,
    /// so its copy of them is stale.
    static func saved(_ edited: Config, current: Config, loadoutsAtOpen: [Loadout]?) -> Config {
        var merged = edited
        if edited.loadouts == loadoutsAtOpen { merged.loadouts = current.loadouts }
        merged.widgets = current.widgets
        return merged
    }

    /// The placed widgets or the widget types changed.
    func widgetsChanged() { view?.reloadWidgets() }

    func close() {
        view?.stopAnimation()
        window?.orderOut(nil)
        window = nil
        view = nil
        onClose?()
    }
}

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Spring

typealias Spring = HUDSpring

struct RectSpring {
    var x: Spring, y: Spring, w: Spring, h: Spring

    init(_ r: FractionRect) {
        x = Spring(r.x); y = Spring(r.y); w = Spring(r.w); h = Spring(r.h)
    }

    var rect: FractionRect { FractionRect(x: x.value, y: y.value, w: w.value, h: h.value) }
    var target: FractionRect {
        get { FractionRect(x: x.target, y: y.target, w: w.target, h: h.target) }
        set { x.target = newValue.x; y.target = newValue.y; w.target = newValue.w; h.target = newValue.h }
    }

    mutating func jump(to r: FractionRect) { x.jump(to: r.x); y.jump(to: r.y); w.jump(to: r.w); h.jump(to: r.h) }

    mutating func step(dt: Double, stiffness: Double, damping: Double, epsilon: Double) -> Bool {
        let a = x.step(dt: dt, stiffness: stiffness, damping: damping, epsilon: epsilon)
        let b = y.step(dt: dt, stiffness: stiffness, damping: damping, epsilon: epsilon)
        let c = w.step(dt: dt, stiffness: stiffness, damping: damping, epsilon: epsilon)
        let d = h.step(dt: dt, stiffness: stiffness, damping: damping, epsilon: epsilon)
        return a && b && c && d
    }
}

// MARK: - Glass panel (floating toolbar)

/// Frosted, draggable container. Clicks on its own background start a drag;
/// clicks on embedded controls go to the controls.
final class GlassPanel: HUDGlassView {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?   // delta in superview coords
    var onDragEnded: (() -> Void)?
    private var lastPoint: CGPoint = .zero

    init(frame: NSRect) {
        super.init(frame: frame, style: .panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        lastPoint = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        onDragMoved?(CGPoint(x: p.x - lastPoint.x, y: p.y - lastPoint.y))
        lastPoint = p
    }

    override func mouseUp(with event: NSEvent) { onDragEnded?() }
}

/// Label that never eats mouse events, so the panel behind it can be dragged.
final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Loadout fixups

/// Pure helpers that keep loadouts consistent with layout edits. No AppKit/UI
/// dependencies so they can be unit tested directly.
enum LoadoutFixup {
    /// Drop any slot referencing `regionID` from every loadout.
    static func removingRegion(_ regionID: String, from loadouts: [Loadout]) -> [Loadout] {
        loadouts.map { loadout in
            var loadout = loadout
            loadout.slots.removeAll { $0.regionID == regionID }
            return loadout
        }
    }

    /// Repoint loadouts that referenced `oldName` at `newName` after a layout rename.
    static func renamingLayout(from oldName: String, to newName: String, in loadouts: [Loadout]) -> [Loadout] {
        loadouts.map { loadout in
            var loadout = loadout
            if loadout.layout == oldName { loadout.layout = newName }
            return loadout
        }
    }
}

// MARK: - Widgets in the editor

/// A placed desktop widget as the layout editor shows it.
struct EditorWidget: Equatable {
    var id: String
    var title: String
    var symbol: String
    var size: HUDWidgetSize
    /// Cocoa screen coordinates.
    var frame: CGRect
}

/// A widget type the editor's Add Widget menu offers.
struct EditorWidgetType: Equatable {
    var app: String
    var appName: String
    var type: String
    var title: String
    var symbol: String
    var sizes: [HUDWidgetSize]
    /// False for a type that allows one instance and has it.
    var canAdd: Bool
}

/// The desktop widgets as the layout editor works with them. Changes go through the widget
/// layer at once, the same path as every other widget change, so they are not part of the
/// editor's Save, Cancel or undo.
@MainActor
protocol LayoutEditorWidgets: AnyObject {
    /// The widgets placed on the display whose frame is `screenFrame`.
    func editorWidgets(on screenFrame: CGRect) -> [EditorWidget]
    func editorWidgetTypes() -> [EditorWidgetType]
    /// The grid widgets snap to: the saved one, which the editor shows unless another
    /// density is picked and not yet saved.
    var editorWidgetGrid: GridSize { get }
    /// Moves a widget to the free spot nearest `frame`. Returns a note when it went elsewhere
    /// or could not move.
    func editorMove(_ id: String, to frame: CGRect) -> String?
    /// Adds a widget at the first free spot on that display; `done` gets a note or why not.
    func editorAdd(app: String, type: String, size: HUDWidgetSize, screenFrame: CGRect, done: @escaping (String?) -> Void)
}

// MARK: - Editor view

final class EditorView: NSView {
    var screenOrigin: CGPoint = .zero
    /// The screen's visible frame in view coordinates. Regions are fractions of this.
    var visible: CGRect = .zero
    var config: Config = .defaults { didSet { syncPanel(); requestPanelAvoidance() } }
    var layoutIndex = 0 { didSet { selected = nil; hitPaintFor = nil; selectedLoadoutName = nil; syncPanel(); requestPanelAvoidance(); needsDisplay = true } }
    var onSave: ((Config, Int) -> Void)?
    var onCancel: (() -> Void)?
    var captureProvider: ((Layout) -> [Slot])?
    /// Registered panel ids (dock, dev servers, ...), offered by the occupant picker.
    var panelChoices: [PanelChoice] = []
    /// The desktop widgets: shown as fixed-size blocks, moved and added live.
    weak var widgetSource: LayoutEditorWidgets?
    /// The widgets on this screen, Cocoa screen coordinates.
    private var widgetBlocks: [EditorWidget] = []
    private var widgetPreview: CGRect?
    /// What the last widget move or add said (moved elsewhere, no room).
    private var widgetNote: String?

    private var selected: Int?
    private var hovered: Int?
    private var undoStack: [Config] = []
    private var dirty = false
    private var showHelp = false
    /// Armed by the card's hit-zone button: next drag paints that region's hit zone.
    private var hitPaintFor: Int?
    /// Name of the loadout currently shown/edited for this layout, if any.
    fileprivate(set) var selectedLoadoutName: String? { didSet { syncLoadoutPopup(); needsDisplay = true } }
    private var occupantPopover: NSPopover?

    private enum Edge { case left, right, top, bottom }
    private enum Drag {
        case create(anchor: CGPoint)
        case move(index: Int, start: FractionRect, startPoint: CGPoint)
        case resize(index: Int, edges: Set<Edge>, start: FractionRect)
        case hit(index: Int, anchor: CGPoint)
        /// A widget, in view coordinates.
        case widget(id: String, start: CGRect, startPoint: CGPoint)
    }
    private var drag: Drag?
    private var rawAnchor: CGPoint?
    private var rawCurrent: CGPoint?
    private var live: RectSpring?

    private enum CardButton: CaseIterable { case delete, rename, hitZone, occupant }
    private let cardButtonSize: CGFloat = 24
    private let cardButtonGap: CGFloat = 6

    // Floating panel
    private let panel = GlassPanel(frame: .zero)
    private let layoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let loadoutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gridPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widgetPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private var widgetSeparator: NSView?
    private let gridPresets: [GridSize] = [
        GridSize(cols: 24, rows: 12), GridSize(cols: 48, rows: 27), GridSize(cols: 64, rows: 36),
        GridSize(cols: 96, rows: 54), GridSize(cols: 128, rows: 72), GridSize(cols: 192, rows: 108),
    ]
    private var panelPreferred: CGPoint = .zero        // where the user last put it (center)
    private var panelX = Spring(0), panelY = Spring(0) // animated center
    private var panelDragging = false
    private var panelBuilt = false

    private var animTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var hoverCursor: NSCursor = .arrow

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    fileprivate var layout: Layout? {
        get { config.layouts.indices.contains(layoutIndex) ? config.layouts[layoutIndex] : nil }
        set { if let v = newValue, config.layouts.indices.contains(layoutIndex) { config.layouts[layoutIndex] = v } }
    }
    private var grid: GridSize { config.grid ?? .default }
    private var minW: Double { 1.0 / Double(grid.cols) }
    private var minH: Double { 1.0 / Double(grid.rows) }

    // MARK: Coordinates (fractions are top-left based)

    private func toFraction(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - visible.minX) / visible.width, y: (visible.maxY - p.y) / visible.height)
    }

    private func toView(_ r: FractionRect) -> CGRect { r.cocoaRect(in: visible) }

    private func fractionRect(from a: CGPoint, to b: CGPoint) -> FractionRect {
        FractionRect(x: min(a.x, b.x), y: min(a.y, b.y), w: abs(a.x - b.x), h: abs(a.y - b.y))
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// The rect a region is currently drawn at (spring position while it is being dragged).
    private func displayRect(_ i: Int) -> FractionRect? {
        guard let l = layout, l.regions.indices.contains(i) else { return nil }
        if let d = drag, let live {
            switch d {
            case .move(let idx, _, _), .resize(let idx, _, _): if idx == i { return live.rect }
            default: break
            }
        }
        return l.regions[i].frame
    }

    // MARK: Snapping — always lands exactly on a grid line

    private func snapX(_ fx: Double) -> Double { clamp01((Double(grid.cols) * fx).rounded() / Double(grid.cols)) }
    private func snapY(_ fy: Double) -> Double { clamp01((Double(grid.rows) * fy).rounded() / Double(grid.rows)) }
    private func snapPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: snapX(p.x), y: snapY(p.y)) }

    // MARK: Hit testing

    /// Delete/rename/hit-zone are always available; the occupant button only appears
    /// once a loadout is selected for this layout (there is nothing to assign otherwise).
    private var activeCardButtons: [CardButton] {
        selectedLoadoutName != nil ? CardButton.allCases : [.delete, .rename, .hitZone]
    }

    private func cardButtonRects(for r: CGRect) -> [(CardButton, CGRect)] {
        let buttons = activeCardButtons
        let s = cardButtonSize, g = cardButtonGap
        let needed = CGFloat(buttons.count) * (s + g) + 10
        guard r.width > needed + 20, r.height > s + 30 else { return [] }
        var x = r.maxX - 10 - s
        let y = r.maxY - 10 - s
        var out: [(CardButton, CGRect)] = []
        for b in buttons.reversed() {
            out.append((b, CGRect(x: x, y: y, width: s, height: s)))
            x -= s + g
        }
        return out.reversed()
    }

    private func cardButtonRect(for index: Int, button: CardButton) -> CGRect? {
        guard let fr = displayRect(index) else { return nil }
        let r = toView(fr).insetBy(dx: 1.5, dy: 1.5)
        return cardButtonRects(for: r).first { $0.0 == button }?.1
    }

    private func showsButtons(_ i: Int) -> Bool { i == selected || i == hovered }

    private func hitCardButton(at p: CGPoint) -> (index: Int, button: CardButton)? {
        guard let l = layout else { return nil }
        for i in l.regions.indices.reversed() where showsButtons(i) {
            guard let fr = displayRect(i) else { continue }
            for (b, rect) in cardButtonRects(for: toView(fr).insetBy(dx: 1.5, dy: 1.5)) where rect.contains(p) {
                return (i, b)
            }
        }
        return nil
    }

    private func hitRegion(at p: CGPoint) -> (index: Int, edges: Set<Edge>)? {
        guard let l = layout else { return nil }
        let tol: CGFloat = 8
        var order = Array(drawOrder(l).reversed())
        if let s = selected { order.removeAll { $0 == s }; order.insert(s, at: 0) }
        for i in order {
            let r = toView(l.regions[i].frame)
            guard r.insetBy(dx: -tol, dy: -tol).contains(p) else { continue }
            var edges = Set<Edge>()
            if abs(p.x - r.minX) <= tol { edges.insert(.left) }
            if abs(p.x - r.maxX) <= tol { edges.insert(.right) }
            if abs(p.y - r.maxY) <= tol { edges.insert(.top) }
            if abs(p.y - r.minY) <= tol { edges.insert(.bottom) }
            if edges.isEmpty && !r.contains(p) { continue }
            return (i, edges)
        }
        return nil
    }

    private func cursor(for edges: Set<Edge>) -> NSCursor {
        if edges.isEmpty { return .openHand }
        if edges.count == 2 { return .crosshair }
        if edges.contains(.left) || edges.contains(.right) { return .resizeLeftRight }
        return .resizeUpDown
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard visible.contains(p), layout != nil else { return }
        if widgetNote != nil { widgetNote = nil; needsDisplay = true }
        // Widgets lie over the regions; ⌘-drag (a new region) and hit-zone painting reach under them.
        let underWidgets = hitPaintFor != nil || !event.modifierFlags.intersection([.command, .option]).isEmpty
        if !underWidgets, let block = hitWidget(at: p) {
            drag = .widget(id: block.id, start: block.rect, startPoint: p)
            widgetPreview = block.rect
            NSCursor.closedHand.push()
            needsDisplay = true
            return
        }
        let fp = toFraction(p)
        rawAnchor = fp
        rawCurrent = fp

        if let hit = hitCardButton(at: p) {
            rawAnchor = nil; rawCurrent = nil
            selected = hit.index
            perform(hit.button, on: hit.index)
            needsDisplay = true
            return
        }

        let paintTarget: Int? = hitPaintFor ?? (event.modifierFlags.contains(.option) ? selected : nil)
        if let s = paintTarget, layout!.regions.indices.contains(s) {
            pushUndo()
            let a = snapPoint(fp)
            drag = .hit(index: s, anchor: a)
            live = RectSpring(FractionRect(x: a.x, y: a.y, w: 0, h: 0))
            hitPaintFor = nil
            return
        }

        // ⌘-drag always draws a new region, so one can be drawn on top of another
        // (overlapping regions are stacked windows; ⌘↑/⌘↓ order them).
        if !event.modifierFlags.contains(.command), let hit = hitRegion(at: p) {
            selected = hit.index
            pushUndo()
            let start = layout!.regions[hit.index].frame
            drag = hit.edges.isEmpty
                ? .move(index: hit.index, start: start, startPoint: fp)
                : .resize(index: hit.index, edges: hit.edges, start: start)
            live = RectSpring(start)
            NSCursor.closedHand.push()
        } else {
            selected = nil
            pushUndo()
            let a = snapPoint(fp)
            drag = .create(anchor: a)
            live = RectSpring(FractionRect(x: a.x, y: a.y, w: 0, h: 0))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .widget(_, let start, let startPoint) = drag {
            widgetPreview = widgetGrid.dragged(start, by: CGSize(width: p.x - startPoint.x, height: p.y - startPoint.y))
            requestPanelAvoidance()
            needsDisplay = true
            return
        }
        guard let d = drag, var spring = live else { return }
        let fp = CGPoint(x: clamp01(toFraction(p).x), y: clamp01(toFraction(p).y))
        rawCurrent = fp

        switch d {
        case .create(let anchor), .hit(_, let anchor):
            spring.target = fractionRect(from: anchor, to: snapPoint(fp))

        case .move(let index, let start, let startPoint):
            _ = index
            let dx = fp.x - startPoint.x, dy = fp.y - startPoint.y
            var nx = snapX(start.x + dx)
            var ny = snapY(start.y + dy)
            nx = min(max(nx, 0), snapX(1 - start.w))
            ny = min(max(ny, 0), snapY(1 - start.h))
            spring.target = FractionRect(x: nx, y: ny, w: start.w, h: start.h)

        case .resize(_, let edges, let start):
            var left = start.x, right = start.x + start.w
            var top = start.y, bottom = start.y + start.h
            if edges.contains(.left) { left = min(snapX(fp.x), right - minW) }
            if edges.contains(.right) { right = max(snapX(fp.x), left + minW) }
            if edges.contains(.top) { top = min(snapY(fp.y), bottom - minH) }
            if edges.contains(.bottom) { bottom = max(snapY(fp.y), top + minH) }
            spring.target = FractionRect(x: left, y: top, w: right - left, h: bottom - top)

        case .widget:
            return
        }
        live = spring
        startAnimation()
        requestPanelAvoidance()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .widget(let id, let start, _) = drag {
            NSCursor.pop()
            let target = widgetPreview ?? start
            drag = nil
            widgetPreview = nil
            if target != start { moveWidget(id, to: target) }
            requestPanelAvoidance()
            needsDisplay = true
            return
        }
        defer {
            drag = nil; rawAnchor = nil; rawCurrent = nil; live = nil
            requestPanelAvoidance(); needsDisplay = true
        }
        guard let d = drag, let spring = live, var l = layout else { return }
        let target = spring.target
        NSCursor.pop()

        let rawDistance: CGFloat = {
            guard let a = rawAnchor, let c = rawCurrent else { return 0 }
            return hypot((a.x - c.x) * visible.width, (a.y - c.y) * visible.height)
        }()

        switch d {
        case .create:
            guard rawDistance > 6, target.w >= minW * 0.5, target.h >= minH * 0.5 else {
                _ = undoStack.popLast()   // plain click: deselect only
                return
            }
            l.regions.append(Region(name: "Region \(l.regions.count + 1)", x: target.x, y: target.y,
                                    w: max(target.w, minW), h: max(target.h, minH), hit: nil))
            layout = l
            selected = l.regions.count - 1
            dirty = true

        case .hit(let index, _):
            guard l.regions.indices.contains(index), rawDistance > 6,
                  target.w >= minW * 0.5, target.h >= minH * 0.5 else { _ = undoStack.popLast(); return }
            l.regions[index].hit = target
            layout = l
            dirty = true

        case .widget:
            return

        case .move(let index, let start, _), .resize(let index, _, let start):
            guard l.regions.indices.contains(index) else { return }
            if target == start { _ = undoStack.popLast(); return }
            l.regions[index].x = target.x
            l.regions[index].y = target.y
            l.regions[index].w = target.w
            l.regions[index].h = target.h
            layout = l
            dirty = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        let c: NSCursor
        var newHover: Int?
        if !visible.contains(p) {
            c = .arrow
        } else if hitWidget(at: p) != nil {
            c = .openHand
        } else if hitCardButton(at: p) != nil {
            c = .pointingHand
            newHover = hovered
        } else if hitPaintFor != nil {
            c = .crosshair
            newHover = hitPaintFor
        } else if let hit = hitRegion(at: p) {
            c = cursor(for: hit.edges)
            newHover = hit.index
        } else {
            c = .crosshair
        }
        if c != hoverCursor { hoverCursor = c; c.set() }
        if newHover != hovered { hovered = newHover; needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    // MARK: Animation

    private func startAnimation() {
        guard animTimer == nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let dt = 1.0 / 120.0
        var settled = true

        if var spring = live {
            // Epsilon of a quarter pixel in fraction units.
            let eps = 0.25 / Double(max(visible.width, 1))
            let done = spring.step(dt: dt, stiffness: 900, damping: 0.55, epsilon: eps)
            live = spring
            settled = settled && done
            needsDisplay = true
        }

        if !panelDragging {
            let a = panelX.step(dt: dt, stiffness: 260, damping: 0.72, epsilon: 0.2)
            let b = panelY.step(dt: dt, stiffness: 260, damping: 0.72, epsilon: 0.2)
            placePanel()
            settled = settled && a && b
        }

        if settled { stopAnimation() }
    }

    func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        switch event.keyCode {
        case 53: // Esc
            if drag != nil { cancelDrag() }
            else if hitPaintFor != nil { hitPaintFor = nil; needsDisplay = true }
            else if selected != nil { selected = nil; needsDisplay = true }
            else if !dirty { onCancel?() }
            else { NSSound.beep() }
        case 51, 117: // Backspace / Delete
            if flags.contains(.option) { clearHitZone() } else { deleteSelected() }
        case 36, 76: // Return
            renameSelected()
        case 48: // Tab
            if !config.layouts.isEmpty { layoutIndex = (layoutIndex + 1) % config.layouts.count }
        case 123: nudge(dx: -1, dy: 0)
        case 124: nudge(dx: 1, dy: 0)
        case 126: if cmd { bumpZ(up: true) } else { nudge(dx: 0, dy: -1) }
        case 125: if cmd { bumpZ(up: false) } else { nudge(dx: 0, dy: 1) }
        default:
            let chars = event.charactersIgnoringModifiers ?? ""
            if cmd {
                switch chars {
                case "s": save()
                case "z": undo()
                case ".": onCancel?()
                default: super.keyDown(with: event)
                }
            } else if chars == "?" || chars == "/" {
                showHelp.toggle(); needsDisplay = true
            } else if chars == "h", let s = selected {
                toggleHitZone(s)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Stacking

    private func zValue(for regionID: String) -> Int {
        currentLoadout?.slot(regionID: regionID)?.stackOrder ?? 0
    }

    /// Regions in ascending z (list order on ties): later ones draw on top.
    private func drawOrder(_ l: Layout) -> [Int] {
        ZOrder.raiseOrder(l.regions.map { $0.id.map(zValue(for:)) ?? 0 })
    }

    private func isStacked(_ regionID: String, in l: Layout) -> Bool {
        guard let mine = l.region(id: regionID)?.frame else { return false }
        return l.regions.contains { $0.id != regionID && ZOrder.overlaps($0.frame, mine) }
    }

    /// ⌘↑ / ⌘↓: move the selected region's slot one step in front of (or behind) the
    /// regions it overlaps. Needs a loadout with an occupant in that region.
    private func bumpZ(up: Bool) {
        guard let s = selected, let l = layout, l.regions.indices.contains(s), let id = l.regions[s].id,
              let name = selectedLoadoutName, var loadouts = config.loadouts,
              let li = loadouts.firstIndex(where: { $0.name == name }),
              let si = loadouts[li].slots.firstIndex(where: { $0.regionID == id }) else { NSSound.beep(); return }
        var rects: [String: FractionRect] = [:]
        var zs: [String: Int] = [:]
        for region in l.regions {
            guard let rid = region.id else { continue }
            rects[rid] = region.frame
            zs[rid] = loadouts[li].slot(regionID: rid)?.stackOrder ?? 0
        }
        guard let z = ZOrder.bumped(id, up: up, rects: rects, z: zs) else { NSSound.beep(); return }
        pushUndo()
        loadouts[li].slots[si].z = z == 0 ? nil : z
        config.loadouts = loadouts
        dirty = true
        needsDisplay = true
    }

    private func cancelDrag() {
        if case .widget = drag {
            // Nothing was pushed for undo: widgets move live.
            drag = nil; widgetPreview = nil
            NSCursor.pop()
            needsDisplay = true
            return
        }
        drag = nil; rawAnchor = nil; rawCurrent = nil; live = nil
        _ = undoStack.popLast()
        NSCursor.pop()
        requestPanelAvoidance()
        needsDisplay = true
    }

    private func nudge(dx: Int, dy: Int) {
        guard let s = selected, var l = layout, l.regions.indices.contains(s) else { return }
        pushUndo()
        var r = l.regions[s]
        r.x = min(max(r.x + Double(dx) * minW, 0), 1 - r.w)
        r.y = min(max(r.y + Double(dy) * minH, 0), 1 - r.h)
        l.regions[s] = r
        layout = l
        dirty = true
        needsDisplay = true
    }

    // MARK: Editing operations

    private func perform(_ button: CardButton, on index: Int) {
        switch button {
        case .delete: deleteRegion(index)
        case .rename: renameRegion(index)
        case .hitZone: toggleHitZone(index)
        case .occupant: openOccupantPicker(for: index)
        }
    }

    // MARK: Loadouts / occupants

    private var currentLayoutLoadouts: [Loadout] {
        guard let name = layout?.name else { return [] }
        return (config.loadouts ?? []).filter { $0.layout == name }
    }

    private var currentLoadout: Loadout? {
        guard let name = selectedLoadoutName else { return nil }
        return config.loadouts?.first { $0.name == name }
    }

    private func occupant(for regionID: String) -> Occupant? {
        currentLoadout?.slot(regionID: regionID)?.occupant
    }

    /// Creates (or reuses) a loadout named `name` for the current layout and selects it.
    private func createLoadout(named name: String) {
        guard let l = layout else { return }
        pushUndo()
        var loadouts = config.loadouts ?? []
        if !loadouts.contains(where: { $0.name == name }) {
            // Start from what is on screen now; the user refines from there.
            let slots = captureProvider?(l) ?? []
            loadouts.append(Loadout(name: name, layout: l.name, slots: slots, hotkey: nil))
        }
        config.loadouts = loadouts
        selectedLoadoutName = name
        dirty = true
    }

    /// Refill the selected loadout's slots from the windows currently in this layout's regions.
    @objc private func captureIntoLoadout() {
        guard let l = layout, let capture = captureProvider else { return }
        guard let name = ensureLoadoutSelected(), var loadouts = config.loadouts,
              let i = loadouts.firstIndex(where: { $0.name == name }) else { return }
        let slots = capture(l)
        guard !slots.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to capture"
            alert.informativeText = "No window is sitting in a region of “\(l.name)” on this screen. Close the editor, arrange windows (⇧-drag into regions), then capture again."
            alert.runModal()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        pushUndo()
        loadouts[i].slots = slots
        config.loadouts = loadouts
        dirty = true
        needsDisplay = true
    }

    private func newLoadoutPrompt() {
        guard let name = prompt(title: "New loadout name", value: "Loadout \((config.loadouts?.count ?? 0) + 1)"),
              !name.isEmpty else {
            syncLoadoutPopup()
            return
        }
        createLoadout(named: name)
    }

    /// The loadout to assign occupants into: the selected one, or a freshly created one.
    private func ensureLoadoutSelected() -> String? {
        if let name = selectedLoadoutName { return name }
        guard let name = prompt(title: "New loadout name", value: "Loadout \((config.loadouts?.count ?? 0) + 1)"),
              !name.isEmpty else { return nil }
        createLoadout(named: name)
        return selectedLoadoutName
    }

    private func openOccupantPicker(for index: Int) {
        guard var l = layout, l.regions.indices.contains(index) else { return }
        guard let loadoutName = ensureLoadoutSelected() else { return }
        let regionID: String
        if let id = l.regions[index].id {
            regionID = id
        } else {
            regionID = UUID().uuidString.lowercased()
            l.regions[index].id = regionID
            layout = l
        }
        guard let rect = cardButtonRect(for: index, button: .occupant) else { return }

        let picker = OccupantPicker()
        picker.panelChoices = panelChoices
        picker.configuredBrowser = config.browser
        picker.current = currentLoadout?.slot(regionID: regionID)?.occupant
        picker.onSelect = { [weak self] occupant in
            guard let self else { return }
            self.pushUndo()
            var loadouts = self.config.loadouts ?? []
            if let li = loadouts.firstIndex(where: { $0.name == loadoutName }) {
                loadouts[li].set(occupant, regionID: regionID)
                self.config.loadouts = loadouts
                self.dirty = true
            }
            self.needsDisplay = true
            self.occupantPopover?.performClose(nil)
        }

        let popover = NSPopover()
        popover.contentViewController = picker
        popover.behavior = .transient
        popover.contentSize = picker.view.frame.size
        occupantPopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    private func pushUndo() {
        undoStack.append(config)
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func undo() {
        guard let c = undoStack.popLast() else { NSSound.beep(); return }
        config = c
        if !config.layouts.indices.contains(layoutIndex) { layoutIndex = max(config.layouts.count - 1, 0) }
        if let s = selected, !(layout?.regions.indices.contains(s) ?? false) { selected = nil }
        hovered = nil
        dirty = true
        needsDisplay = true
    }

    private func deleteSelected() {
        guard let s = selected else { return }
        deleteRegion(s)
    }

    /// `internal` (not `private`) so tests can exercise the loadout fixup wiring
    /// directly, not just the pure `LoadoutFixup` functions.
    func deleteRegion(_ i: Int) {
        guard var l = layout, l.regions.indices.contains(i) else { return }
        pushUndo()
        let regionID = l.regions[i].id
        l.regions.remove(at: i)
        layout = l
        if let regionID, let loadouts = config.loadouts {
            config.loadouts = LoadoutFixup.removingRegion(regionID, from: loadouts)
        }
        selected = nil
        hovered = nil
        dirty = true
        needsDisplay = true
    }

    private func clearHitZone() {
        guard let s = selected, var l = layout, l.regions.indices.contains(s), l.regions[s].hit != nil else { return }
        pushUndo()
        l.regions[s].hit = nil
        layout = l
        dirty = true
        needsDisplay = true
    }

    /// Hit-zone button: clears an existing hit zone, otherwise arms painting one.
    private func toggleHitZone(_ i: Int) {
        guard var l = layout, l.regions.indices.contains(i) else { return }
        if l.regions[i].hit != nil {
            pushUndo()
            l.regions[i].hit = nil
            layout = l
            dirty = true
        } else {
            hitPaintFor = (hitPaintFor == i) ? nil : i
            selected = i
        }
        needsDisplay = true
    }

    private func renameSelected() {
        guard let s = selected else { return }
        renameRegion(s)
    }

    private func renameRegion(_ i: Int) {
        guard var l = layout, l.regions.indices.contains(i) else { return }
        guard let name = prompt(title: "Region name", value: l.regions[i].name ?? "") else { return }
        pushUndo()
        l.regions[i].name = name.isEmpty ? nil : name
        layout = l
        dirty = true
        needsDisplay = true
    }

    private func prompt(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        return result == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func save() { onSave?(config, layoutIndex) }

    // MARK: Floating panel

    func buildPanel() {
        guard !panelBuilt else { return }
        panelBuilt = true
        addSubview(panel)

        panel.onDragBegan = { [weak self] in
            guard let self else { return }
            self.panelDragging = true
            self.panelX.velocity = 0; self.panelY.velocity = 0
        }
        panel.onDragMoved = { [weak self] delta in
            guard let self else { return }
            self.panelX.jump(to: self.panelX.value + delta.x)
            self.panelY.jump(to: self.panelY.value + delta.y)
            self.placePanel()
        }
        panel.onDragEnded = { [weak self] in
            guard let self else { return }
            self.panelDragging = false
            // Where it was dropped becomes the new preference; it still steps aside for regions.
            self.panelPreferred = CGPoint(x: self.panelX.value, y: self.panelY.value)
            self.requestPanelAvoidance()
        }

        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChosen)
        loadoutPopup.target = self
        loadoutPopup.action = #selector(loadoutChosen)
        gridPopup.target = self
        gridPopup.action = #selector(gridChosen)
        for g in gridPresets { gridPopup.addItem(withTitle: "\(g.cols) × \(g.rows)") }
        widgetPopup.toolTip = "Add a desktop widget on this screen (it is placed at once)"
        widgetSeparator = separatorView()
        for popup in [layoutPopup, loadoutPopup, gridPopup, widgetPopup] {
            popup.bezelStyle = .texturedRounded
            popup.controlSize = .regular
            popup.font = .systemFont(ofSize: 12, weight: .medium)
        }

        func icon(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
            let b = NSButton(image: img ?? NSImage(), target: self, action: sel)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.contentTintColor = .white
            b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            return b
        }
        func text(_ title: String, _ sel: Selector, key: String, mods: NSEvent.ModifierFlags) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = mods
            return b
        }

        let grip = PassiveLabel(labelWithString: "⋮⋮")
        grip.textColor = NSColor.white.withAlphaComponent(0.5)
        grip.font = .systemFont(ofSize: 15, weight: .bold)
        grip.toolTip = "Drag to move"

        let gridLabel = PassiveLabel(labelWithString: "Grid")
        gridLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        gridLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let loadoutLabel = PassiveLabel(labelWithString: "Loadout")
        loadoutLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        loadoutLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let saveBtn = text("Save", #selector(saveTapped), key: "s", mods: .command)
        saveBtn.bezelColor = .controlAccentColor

        let stack = NSStackView(views: [
            grip,
            layoutPopup,
            icon("plus", "New layout", #selector(newLayout)),
            icon("pencil", "Rename layout", #selector(renameLayout)),
            icon("trash", "Delete layout", #selector(deleteLayout)),
            separatorView(),
            loadoutLabel, loadoutPopup,
            icon("camera.viewfinder", "Capture windows on screen into this loadout", #selector(captureIntoLoadout)),
            separatorView(),
            gridLabel, gridPopup,
            widgetSeparator!, widgetPopup,
            separatorView(),
            icon("questionmark.circle", "Show shortcuts", #selector(toggleHelp)),
            text("Cancel", #selector(cancelTapped), key: ".", mods: .command),
            saveBtn,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        syncPanel()
        // Start bottom-center of the editable area.
        panelPreferred = CGPoint(x: visible.midX, y: visible.minY + 24 + panel.frame.height / 2)
        panelX.jump(to: panelPreferred.x)
        panelY.jump(to: panelPreferred.y)
        placePanel()
        requestPanelAvoidance()
    }

    private func separatorView() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return v
    }

    private func syncPanel() {
        guard panelBuilt else { return }
        layoutPopup.removeAllItems()
        for l in config.layouts { layoutPopup.addItem(withTitle: l.name) }
        if config.layouts.indices.contains(layoutIndex) { layoutPopup.selectItem(at: layoutIndex) }
        syncLoadoutPopup()
        if let i = gridPresets.firstIndex(of: grid) {
            gridPopup.selectItem(at: i)
        } else {
            if gridPopup.numberOfItems == gridPresets.count { gridPopup.addItem(withTitle: "\(grid.cols) × \(grid.rows)") }
            gridPopup.selectItem(at: gridPopup.numberOfItems - 1)
        }
        panel.layoutSubtreeIfNeeded()
        let size = panel.fittingSize
        if panel.frame.size != size {
            panel.setFrameSize(size)
            placePanel()
        }
    }

    private func placePanel() {
        let size = panel.frame.size
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let inset: CGFloat = 12
        let cx = min(max(panelX.value, visible.minX + inset + half.width), visible.maxX - inset - half.width)
        let cy = min(max(panelY.value, visible.minY + inset + half.height), visible.maxY - inset - half.height)
        panel.setFrameOrigin(CGPoint(x: (cx - half.width).rounded(), y: (cy - half.height).rounded()))
    }

    /// Steer the panel to the nearest spot to its preferred position that does not
    /// overlap any region; if none exists, minimize the overlap.
    private func requestPanelAvoidance() {
        guard panelBuilt, !panelDragging, let l = layout else { return }
        let size = panel.frame.size
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let inset: CGFloat = 12
        let pad: CGFloat = 14
        let blocks: [CGRect] = (l.regions.indices.compactMap { displayRect($0) }.map(toView) + widgetRects.map(\.rect))
            .map { $0.insetBy(dx: -pad, dy: -pad) }

        let minX = visible.minX + inset + half.width, maxX = visible.maxX - inset - half.width
        let minY = visible.minY + inset + half.height, maxY = visible.maxY - inset - half.height
        guard minX <= maxX, minY <= maxY else { return }

        func overlap(_ c: CGPoint) -> CGFloat {
            let r = CGRect(x: c.x - half.width, y: c.y - half.height, width: size.width, height: size.height)
            return blocks.reduce(0) { $0 + $1.intersection(r).area }
        }

        let pref = CGPoint(x: min(max(panelPreferred.x, minX), maxX), y: min(max(panelPreferred.y, minY), maxY))
        var best = pref
        if overlap(pref) > 0 {
            let step: CGFloat = 16
            var bestScore = CGFloat.greatestFiniteMagnitude
            var y = minY
            while y <= maxY + 0.001 {
                var x = minX
                while x <= maxX + 0.001 {
                    let c = CGPoint(x: x, y: y)
                    let o = overlap(c)
                    let d = hypot(c.x - pref.x, c.y - pref.y)
                    // Overlap dominates; distance breaks ties.
                    let score = o * 1000 + d
                    if score < bestScore { bestScore = score; best = c }
                    x += step
                }
                y += step
            }
        }
        if panelX.target != best.x || panelY.target != best.y {
            panelX.target = best.x
            panelY.target = best.y
            startAnimation()
        }
    }

    /// Rebuilds the loadout popup: "None", loadouts for the current layout, "New Loadout…".
    /// Drops `selectedLoadoutName` if it no longer names a loadout for this layout.
    private func syncLoadoutPopup() {
        guard panelBuilt else { return }
        let names = currentLayoutLoadouts.map { $0.name }
        if let name = selectedLoadoutName, !names.contains(name) {
            selectedLoadoutName = nil   // re-enters via didSet with corrected state
            return
        }
        loadoutPopup.removeAllItems()
        loadoutPopup.addItem(withTitle: "None")
        for n in names { loadoutPopup.addItem(withTitle: n) }
        loadoutPopup.addItem(withTitle: "New Loadout…")
        if let name = selectedLoadoutName, let i = names.firstIndex(of: name) {
            loadoutPopup.selectItem(at: i + 1)
        } else {
            loadoutPopup.selectItem(at: 0)
        }
    }

    @objc private func layoutChosen() { layoutIndex = layoutPopup.indexOfSelectedItem }
    @objc private func loadoutChosen() {
        let i = loadoutPopup.indexOfSelectedItem
        let names = currentLayoutLoadouts.map { $0.name }
        if i == 0 {
            selectedLoadoutName = nil
        } else if i == names.count + 1 {
            newLoadoutPrompt()
        } else if names.indices.contains(i - 1) {
            selectedLoadoutName = names[i - 1]
        }
    }
    @objc private func gridChosen() {
        let i = gridPopup.indexOfSelectedItem
        guard gridPresets.indices.contains(i) else { return }
        pushUndo()
        config.grid = gridPresets[i]
        dirty = true
        needsDisplay = true
    }
    @objc private func toggleHelp() { showHelp.toggle(); needsDisplay = true }
    @objc private func saveTapped() { save() }
    @objc private func cancelTapped() {
        if dirty {
            let alert = NSAlert()
            alert.messageText = "Discard layout changes?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Keep Editing")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        onCancel?()
    }
    @objc private func renameLayout() {
        guard var l = layout, let name = prompt(title: "Layout name", value: l.name), !name.isEmpty else { return }
        pushUndo()
        let oldName = l.name
        l.name = name
        layout = l
        if let loadouts = config.loadouts {
            config.loadouts = LoadoutFixup.renamingLayout(from: oldName, to: name, in: loadouts)
        }
        dirty = true
    }
    @objc private func newLayout() {
        guard let name = prompt(title: "New layout name", value: "Layout \(config.layouts.count + 1)"), !name.isEmpty else { return }
        pushUndo()
        config.layouts.append(Layout(name: name, regions: []))
        layoutIndex = config.layouts.count - 1
        dirty = true
    }
    @objc private func deleteLayout() {
        guard config.layouts.count > 1, layout != nil else { NSSound.beep(); return }
        pushUndo()
        config.layouts.remove(at: layoutIndex)
        layoutIndex = min(layoutIndex, config.layouts.count - 1)
        dirty = true
    }

    // MARK: Widgets

    /// The layout grid on this screen as widgets snap to it, in view coordinates: the saved
    /// grid, so the preview is where the widget stays (until a new density is saved, which
    /// moves every widget onto it).
    private var widgetGrid: WidgetGrid { WidgetGrid(visible: visible, grid: widgetSource?.editorWidgetGrid ?? grid) }

    private var screenFrame: CGRect { CGRect(origin: screenOrigin, size: bounds.size) }

    /// The widget blocks in view coordinates, the one being dragged at its preview.
    private var widgetRects: [(widget: EditorWidget, rect: CGRect)] {
        widgetBlocks.map { w in
            if case .widget(let id, _, _) = drag, id == w.id, let widgetPreview { return (w, widgetPreview) }
            return (w, w.frame.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y))
        }
    }

    private func hitWidget(at p: CGPoint) -> (id: String, rect: CGRect)? {
        widgetRects.last { $0.rect.contains(p) }.map { ($0.widget.id, $0.rect) }
    }

    /// Reads the placed widgets and the widget types again.
    func reloadWidgets() {
        widgetBlocks = widgetSource?.editorWidgets(on: screenFrame) ?? []
        syncWidgetPopup()
        requestPanelAvoidance()
        needsDisplay = true
    }

    private func moveWidget(_ id: String, to rect: CGRect) {
        widgetNote = widgetSource?.editorMove(id, to: rect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y))
        reloadWidgets()
    }

    /// The Add Widget pull-down: every widget type by app, a submenu of sizes when it has several.
    private func syncWidgetPopup() {
        guard panelBuilt else { return }
        let types = widgetSource?.editorWidgetTypes() ?? []
        widgetPopup.isHidden = types.isEmpty
        widgetSeparator?.isHidden = types.isEmpty
        let menu = NSMenu()
        let head = NSMenuItem(title: "Add Widget", action: nil, keyEquivalent: "")
        head.image = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)
        menu.addItem(head)
        let apps = Set(types.map(\.app)).count
        var lastApp: String?
        for t in types {
            if apps > 1, t.app != lastApp {
                if lastApp != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: t.appName, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            lastApp = t.app
            let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            item.isEnabled = t.canAdd
            func sizeItem(_ title: String, _ size: HUDWidgetSize) -> NSMenuItem {
                let mi = NSMenuItem(title: title, action: t.canAdd ? #selector(widgetChosen(_:)) : nil, keyEquivalent: "")
                mi.target = self
                mi.representedObject = [t.app, t.type, size.rawValue]
                mi.isEnabled = t.canAdd
                return mi
            }
            if t.sizes.count == 1 {
                let mi = sizeItem(t.title, t.sizes[0])
                mi.image = item.image
                menu.addItem(mi)
            } else {
                let sub = NSMenu()
                for size in t.sizes { sub.addItem(sizeItem(WidgetMenuModel.title(size), size)) }
                item.submenu = sub
                menu.addItem(item)
            }
        }
        menu.autoenablesItems = false
        widgetPopup.menu = menu
        panel.layoutSubtreeIfNeeded()
        let size = panel.fittingSize
        if panel.frame.size != size { panel.setFrameSize(size); placePanel() }
    }

    @objc private func widgetChosen(_ item: NSMenuItem) {
        guard let parts = item.representedObject as? [String], parts.count == 3,
              let size = HUDWidgetSize(rawValue: parts[2]) else { return }
        widgetSource?.editorAdd(app: parts[0], type: parts[1], size: size, screenFrame: screenFrame) { [weak self] note in
            self?.widgetNote = note
            self?.reloadWidgets()
        }
    }

    /// Each widget as a fixed-size block with its symbol and title; the one being dragged is
    /// accented, with its starting place dashed.
    private func drawWidgets() {
        let accent = NSColor.controlAccentColor
        let radius = HUDWidgetStyle.cornerRadius
        if case .widget(_, let start, _) = drag {
            let ghost = NSBezierPath(roundedRect: start.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            ghost.setLineDash([6, 4], count: 2, phase: 0)
            ghost.lineWidth = 1
            NSColor.white.withAlphaComponent(0.5).setStroke()
            ghost.stroke()
        }
        for (widget, rect) in widgetRects {
            var dragging = false
            if case .widget(let id, _, _) = drag, id == widget.id { dragging = true }
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            NSColor(calibratedWhite: 0.13, alpha: 0.85).setFill()
            path.fill()
            if dragging { accent.withAlphaComponent(0.3).setFill(); path.fill() }
            (dragging ? accent : NSColor.white.withAlphaComponent(0.6)).setStroke()
            path.lineWidth = dragging ? 2.5 : 1.5
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
            let title = NSAttributedString(string: widget.title, attributes: attrs)
            let ts = title.size()
            let icon = symbol(widget.symbol, size: 20)
            let iconHeight = icon?.size.height ?? 0
            let total = iconHeight + 6 + ts.height
            var y = rect.midY + total / 2
            if let icon {
                y -= iconHeight
                icon.draw(in: CGRect(x: rect.midX - icon.size.width / 2, y: y, width: icon.size.width, height: icon.size.height))
                y -= 6
            }
            title.draw(at: CGPoint(x: rect.midX - min(ts.width, rect.width - 16) / 2, y: y - ts.height))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        GridDrawing.backdrop(bounds, visible: visible)
        GridDrawing.lines(grid, in: visible)

        guard let l = layout else { return }
        let accent = NSColor.controlAccentColor

        var creating = false
        var hitPainting: Int?
        if let d = drag {
            switch d {
            case .create: creating = true
            case .hit(let i, _): hitPainting = i
            default: break
            }
        }

        for i in drawOrder(l) {
            let region = l.regions[i]
            let isSel = (i == selected)
            let fr = displayRect(i) ?? region.frame
            let r = toView(fr).insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            (isSel ? accent.withAlphaComponent(0.32) : NSColor.white.withAlphaComponent(0.11)).setFill()
            path.fill()
            (isSel ? accent : NSColor.white.withAlphaComponent(0.7)).setStroke()
            path.lineWidth = isSel ? 3 : 1.5
            path.stroke()

            let hitRect: FractionRect? = (i == hitPainting ? live?.rect : nil) ?? region.hit
            if let h = hitRect, h != region.frame || i == hitPainting {
                let hp = NSBezierPath(roundedRect: toView(h).insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
                hp.setLineDash([6, 4], count: 2, phase: 0)
                hp.lineWidth = isSel ? 2 : 1
                (isSel ? accent : NSColor.white.withAlphaComponent(0.6)).setStroke()
                hp.stroke()
                accent.withAlphaComponent(isSel ? 0.15 : 0.06).setFill()
                hp.fill()
            }

            let name = region.name ?? "Region \(i + 1)"
            var sub = "\(pct(fr.w)) × \(pct(fr.h))"
            if let regionID = region.id, let slot = currentLoadout?.slot(regionID: regionID), slot.isParked {
                sub += " · parked \(slot.parkEdge.rawValue)"
            }
            if hitPaintFor == i { sub = "drag anywhere to paint hit zone" }
            let labelSize = labelAttributedString(name, sub: sub).size()
            drawLabel(name, sub: sub, at: CGPoint(x: r.midX, y: r.midY), emphasized: isSel)

            if let regionID = region.id, let occ = occupant(for: regionID) {
                let badgeY = r.midY - labelSize.height / 2 - 6 - 14
                if badgeY - 14 > r.minY + 4 {
                    drawOccupantBadge(occ, at: CGPoint(x: r.midX, y: badgeY))
                }
            }

            if let regionID = region.id, isStacked(regionID, in: l) {
                drawZBadge(zValue(for: regionID), in: r, emphasized: isSel)
            }
            if isSel { drawHandles(r) }
            if showsButtons(i) { drawCardButtons(for: r, region: region) }
        }

        if creating || hitPainting != nil, let live {
            if let a = rawAnchor, let c = rawCurrent {
                let rp = NSBezierPath(rect: toView(fractionRect(from: a, to: c)))
                NSColor.white.withAlphaComponent(0.22).setStroke()
                rp.lineWidth = 1
                rp.stroke()
            }
            let r = toView(live.rect)
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            if hitPainting != nil { path.setLineDash([6, 4], count: 2, phase: 0) }
            accent.withAlphaComponent(0.3).setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 2.5
            path.stroke()
            let t = live.target
            drawLabel("\(pct(t.w)) × \(pct(t.h))", sub: nil, at: CGPoint(x: r.midX, y: r.midY), emphasized: true)
        }

        if l.regions.isEmpty && drag == nil {
            drawLabel("Drag anywhere to draw your first region", sub: "Regions snap to the grid · hold ⇧ while dragging a window to use them",
                      at: CGPoint(x: visible.midX, y: visible.midY), emphasized: false)
        }

        drawWidgets()

        if dirty { drawHint("● Unsaved changes") }
        if let widgetNote { drawHint(widgetNote, color: .white, line: 1) }
        if showHelp { drawHelp() }
    }

    private func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }

    private func drawHandles(_ r: CGRect) {
        let pts = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ]
        for p in pts {
            let h = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            NSColor.white.setFill(); h.fill()
            NSColor.controlAccentColor.setStroke(); h.lineWidth = 2; h.stroke()
        }
    }

    private func symbol(_ name: String, size: CGFloat) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private func drawCardButtons(for r: CGRect, region: Region) {
        for (kind, rect) in cardButtonRects(for: r) {
            let active: Bool
            switch kind {
            case .hitZone: active = region.hit != nil
            case .occupant: active = region.id.flatMap { occupant(for: $0) } != nil
            default: active = false
            }
            drawGlassCircle(rect, active: active)
            let name: String
            switch kind {
            case .delete: name = "xmark"
            case .rename: name = "pencil"
            case .hitZone: name = region.hit != nil ? "scope" : "plus.viewfinder"
            case .occupant: name = "app.badge"
            }
            if let img = symbol(name, size: 11) {
                let s = img.size
                img.draw(in: CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
        }
    }

    /// Icon for an occupant badge: the app's real icon, or a placeholder symbol.
    private func occupantIcon(for occupant: Occupant) -> NSImage? {
        switch occupant {
        case .app(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return symbol("app", size: 12)
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .web:
            return symbol("globe", size: 12)
        case .panel:
            return symbol("square.grid.2x2.fill", size: 12)
        }
    }

    private func drawOccupantBadge(_ occupant: Occupant, at c: CGPoint) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
        let full = occupant.label
        let text = (full as NSString).size(withAttributes: attrs).width > 140 ? String(full.prefix(18)) + "…" : full
        let strSize = (text as NSString).size(withAttributes: attrs)
        let iconSize: CGFloat = 14
        let gap: CGFloat = 4
        let contentWidth = iconSize + gap + strSize.width
        let rect = CGRect(x: c.x - contentWidth / 2 - 8, y: c.y - max(strSize.height, iconSize) / 2 - 4,
                          width: contentWidth + 16, height: max(strSize.height, iconSize) + 8)
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        if let icon = occupantIcon(for: occupant) {
            icon.draw(in: CGRect(x: rect.minX + 8, y: c.y - iconSize / 2, width: iconSize, height: iconSize))
        }
        (text as NSString).draw(at: CGPoint(x: rect.minX + 8 + iconSize + gap, y: c.y - strSize.height / 2), withAttributes: attrs)
    }

    /// Small "jelly" glass disc.
    private func drawGlassCircle(_ rect: CGRect, active: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.7) : NSColor(calibratedWhite: 0.25, alpha: 0.75)).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let top = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0.05)])?
            .draw(in: top, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func labelAttributedString(_ text: String, sub: String?) -> NSAttributedString {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let title = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
        if let sub {
            title.append(NSAttributedString(string: "\n\(sub)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para]))
        }
        return title
    }

    private func drawLabel(_ text: String, sub: String?, at c: CGPoint, emphasized: Bool) {
        let title = labelAttributedString(text, sub: sub)
        let s = title.size()
        let rect = CGRect(x: c.x - s.width / 2 - 10, y: c.y - s.height / 2 - 6, width: s.width + 20, height: s.height + 12)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(emphasized ? 0.75 : 0.55).setFill()
        bg.fill()
        title.draw(in: CGRect(x: rect.minX + 10, y: rect.minY + 6, width: s.width, height: s.height))
    }

    /// Small "z N" pill in the card's top-left corner of a region that overlaps others.
    private func drawZBadge(_ z: Int, in r: CGRect, emphasized: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95)]
        let text = NSAttributedString(string: "z \(z)", attributes: attrs)
        let size = text.size()
        let pill = CGRect(x: r.minX + 8, y: r.maxY - 8 - size.height - 4, width: size.width + 12, height: size.height + 4)
        guard pill.maxX < r.maxX - 4, pill.minY > r.minY + 4 else { return }
        (emphasized ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.55)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2))
    }

    private func drawHint(_ text: String, color: NSColor = .systemYellow, line: Int = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color]
        NSAttributedString(string: text, attributes: attrs)
            .draw(at: CGPoint(x: visible.minX + 16, y: visible.maxY - 30 - CGFloat(line) * 18))
    }

    private func drawHelp() {
        let lines = [
            "Drag on empty space: new region   ·   ⌘-drag: new region on top of others   ·   Drag region: move   ·   Drag edge/corner: resize",
            "Card buttons: ✕ delete · ✎ rename · ⊕ paint hit zone (⌥-drag also works; H toggles)   ·   ⌫ delete   ·   ⏎ rename   ·   Arrows nudge",
            "⌘↑ / ⌘↓ raise or lower a stacked region   ·   Tab: next layout   ·   ⌘Z undo   ·   ⌘S save   ·   ⌘. / Esc close   ·   ? toggles this help   ·   drag the ⋮⋮ panel to move it",
            "Widgets: drag one to move it, or Add Widget in the panel; they snap to the saved grid and change at once (Save, Cancel and ⌘Z leave them)",
        ]
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineSpacing = 3
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para]
        let s = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs)
        let size = s.size()
        let rect = CGRect(x: visible.midX - size.width / 2 - 16, y: visible.maxY - 60 - size.height, width: size.width + 32, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        s.draw(in: rect.insetBy(dx: 16, dy: 8))
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
