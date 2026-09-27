import AppKit
import HUDKit

/// "Preview Loadout": draws, on every display, where each slot of a loadout would go and
/// what apply would do to get it there, coloured by action. The regions on the desktops
/// that are showing can be dragged and resized in place (snapping to the layout grid);
/// Apply saves those edits into the loadout's layout first. Slots bound to other desktops
/// are shown small in a mini-map beside the controls. Apply / Cancel (Return / Esc),
/// Edit Layout… for the full editor. Nothing moves until Apply.
@MainActor
final class LoadoutPreview {
    static let shared = LoadoutPreview()

    /// A region moved or resized in the preview, as the fraction of its display it now covers.
    struct RegionEdit: Equatable {
        var regionID: String
        var screen: String
        var rect: FractionRect
    }

    private var windows: [NSWindow] = []
    private var views: [PreviewView] = []
    private var onApply: (([RegionEdit]) -> Void)?
    private var onEdit: (() -> Void)?
    private var keyMonitor: Any?
    private(set) var loadoutName: String?

    var isVisible: Bool { !windows.isEmpty }

    static func color(for action: PlacementPlan.Action) -> NSColor {
        switch action {
        case .stay, .resize, .move: return .systemGreen
        case .launch: return .systemBlue
        case .switchSpace: return .systemOrange
        case .leave: return .systemGray
        case .cannot: return .systemRed
        }
    }

    static func label(for action: PlacementPlan.Action) -> String {
        switch action {
        case .stay: return "in place"
        case .resize: return "resize"
        case .move: return "move here"
        case .launch: return "launch"
        case .switchSpace: return "switch desktop"
        case .leave: return "left where it is"
        case .cannot: return "cannot place"
        }
    }

    /// Show `steps` for `loadout`; `problems` are lines with no region to draw in (a missing
    /// display, a missing layout). `grid` and `gap` are the layout's, for snapping edits.
    func show(loadout: String, steps: [PlacementPlan.Step], problems: [String],
              grid: GridSize = .default, gap: CGFloat = 0,
              onEdit: (() -> Void)? = nil, onApply: @escaping ([RegionEdit]) -> Void) {
        hide()
        loadoutName = loadout
        self.onApply = onApply
        self.onEdit = onEdit
        let mouseScreen = ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        let monitors = Spaces.monitors()
        // Steps on a desktop that is not showing go to the mini-map, not the display.
        var elsewhere: [(screen: NSScreen, space: Int, steps: [PlacementPlan.Step])] = []
        for screen in NSScreen.screens {
            let current = Spaces.monitor(for: screen, in: monitors)?.currentIndex
            let mine = steps.filter { $0.to.screen == screen.localizedName }
            let here = mine.filter { $0.to.space == nil || $0.to.space == current }
            let other = Dictionary(grouping: mine.filter { $0.to.space != nil && $0.to.space != current }) { $0.to.space! }
            for (space, group) in other.sorted(by: { $0.key < $1.key }) { elsewhere.append((screen, space, group)) }
            let view = PreviewView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.origin = screen.frame.origin
            view.screenName = screen.localizedName
            view.visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            view.grid = grid
            view.gap = gap
            view.steps = here
            view.fromSteps = steps.filter { $0.from?.screen == screen.localizedName && $0.to.screen != screen.localizedName }
            view.resetEdits()
            let w = PreviewWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.contentView = view
            w.orderFrontRegardless()
            windows.append(w)
            views.append(view)
        }
        if let host = views.first(where: { NSScreen.screens[views.firstIndex(of: $0)!] == mouseScreen }) ?? views.first {
            host.addSubview(controls(loadout: loadout, steps: steps, problems: problems, visible: host.visible))
            if !elsewhere.isEmpty { host.addSubview(minimap(elsewhere, visible: host.visible)) }
        }
        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screen == mouseScreen } ?? windows.first)?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            switch event.keyCode {
            case 53: self.cancel(); return nil          // Esc
            case 36, 76: self.apply(); return nil       // Return, Enter
            default: return event
            }
        }
    }

    func hide() {
        for w in windows { w.orderOut(nil) }
        windows = []
        views = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        loadoutName = nil
    }

    /// The regions changed in the preview so far.
    var edits: [RegionEdit] { views.flatMap(\.edits) }

    @objc func cancel() {
        hide()
        onApply = nil
        onEdit = nil
    }

    @objc func apply() {
        let action = onApply
        let edits = self.edits
        onApply = nil
        onEdit = nil
        hide()
        action?(edits)
    }

    @objc func edit() {
        let action = onEdit
        onApply = nil
        onEdit = nil
        hide()
        action?()
    }

    private func controls(loadout: String, steps: [PlacementPlan.Step], problems: [String], visible: CGRect) -> NSView {
        let title = NSTextField(labelWithString: "Preview · \(loadout)")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        var counts: [PlacementPlan.Action: Int] = [:]
        for step in steps { counts[step.action, default: 0] += 1 }
        let order: [PlacementPlan.Action] = [.stay, .resize, .move, .launch, .switchSpace, .leave, .cannot]
        let legend = NSStackView(views: order.compactMap { action -> NSView? in
            guard let n = counts[action] else { return nil }
            let dot = NSTextField(labelWithString: "● \(n) \(Self.label(for: action))")
            dot.font = .systemFont(ofSize: 12, weight: .medium)
            dot.textColor = Self.color(for: action)
            return dot
        })
        legend.spacing = 12
        var rows: [NSView] = [title, legend]
        let offscreen = steps.filter { $0.to.screen == nil } .map { "\($0.occupant): \($0.reason)" }
        for line in (problems + offscreen).prefix(6) {
            let l = NSTextField(labelWithString: line)
            l.font = .systemFont(ofSize: 12)
            l.textColor = NSColor.white.withAlphaComponent(0.85)
            rows.append(l)
        }
        let hint = NSTextField(labelWithString: "Drag a region to move it, its edges to resize; Apply keeps the changes")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.6)
        rows.append(hint)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let edit = NSButton(title: "Edit Layout…", target: self, action: #selector(edit))
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        apply.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [cancel, edit, apply])
        buttons.spacing = 10
        rows.append(buttons)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        let glass = Self.glassPanel(around: stack)
        let size = glass.frame.size
        glass.frame = CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 24,
                             width: size.width, height: size.height)
        return glass
    }

    /// Small pictures of the desktops that are not showing: one per (display, desktop),
    /// with that desktop's regions coloured by action.
    private func minimap(_ groups: [(screen: NSScreen, space: Int, steps: [PlacementPlan.Step])], visible: CGRect) -> NSView {
        let title = NSTextField(labelWithString: "Other desktops")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        var rows: [NSView] = [title]
        for group in groups.prefix(6) {
            let map = MiniMapView(screen: group.screen, steps: group.steps, width: 180)
            let caption = NSTextField(labelWithString: "\(group.screen.localizedName) · desktop \(group.space)")
            caption.font = .systemFont(ofSize: 11)
            caption.textColor = NSColor.white.withAlphaComponent(0.85)
            rows.append(map)
            rows.append(caption)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let glass = Self.glassPanel(around: stack)
        let size = glass.frame.size
        glass.frame = CGRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24,
                             width: size.width, height: size.height)
        return glass
    }

    private static func glassPanel(around stack: NSStackView) -> HUDGlassView {
        let glass = HUDGlassView(style: .panel)
        glass.appearance = NSAppearance(named: .darkAqua)
        // A dark tint under the text keeps it legible over any backdrop.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        tint.layer?.cornerRadius = 20
        for view in [tint, stack] {
            glass.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor), tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            tint.topAnchor.constraint(equalTo: glass.topAnchor), tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -14),
        ])
        var size = stack.fittingSize
        size.width += 44
        size.height += 28
        glass.frame = CGRect(origin: .zero, size: size)
        return glass
    }
}

private final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// One display's preview: the steps for the desktop it is showing, editable in place.
private final class PreviewView: NSView {
    var origin: CGPoint = .zero
    var screenName = ""
    /// The display's visible frame in view coordinates.
    var visible: CGRect = .zero
    var grid: GridSize = .default
    var gap: CGFloat = 0
    var steps: [PlacementPlan.Step] = []
    /// Slots whose window leaves this display: their current frame is outlined.
    var fromSteps: [PlacementPlan.Step] = []

    /// Region frames as drawn (view coordinates), by region id; edits change these.
    private var frames: [String: CGRect] = [:]
    private var originals: [String: CGRect] = [:]

    private enum Grip { case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
    private var drag: (regionID: String, grip: Grip, start: CGPoint, frame: CGRect)?

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

    func resetEdits() {
        frames = [:]
        for step in steps { if let f = step.to.frame { frames[step.regionID] = local(f) } }
        originals = frames
        needsDisplay = true
    }

    /// The regions moved or resized, as fractions of the visible frame (the inverse of
    /// `LoadoutEngine.regionRect`: the gap is taken off the outside first).
    var edits: [LoadoutPreview.RegionEdit] {
        let area = visible.insetBy(dx: gap / 2, dy: gap / 2)
        guard area.width > 0, area.height > 0 else { return [] }
        return frames.compactMap { id, frame in
            guard frame != originals[id] else { return nil }
            let r = frame.insetBy(dx: -gap / 2, dy: -gap / 2)
            let rect = FractionRect(x: (r.minX - area.minX) / area.width, y: (area.maxY - r.maxY) / area.height,
                                    w: r.width / area.width, h: r.height / area.height)
            return LoadoutPreview.RegionEdit(regionID: id, screen: screenName, rect: rect)
        }
    }

    // MARK: Editing

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private static let gripWidth: CGFloat = 12

    private func grip(at p: CGPoint) -> (String, Grip)? {
        // Front-most drawn region last, so hit-test in reverse.
        for step in steps.reversed() {
            guard let f = frames[step.regionID], f.insetBy(dx: -Self.gripWidth / 2, dy: -Self.gripWidth / 2).contains(p) else { continue }
            let w = Self.gripWidth
            let left = abs(p.x - f.minX) <= w, right = abs(p.x - f.maxX) <= w
            let bottom = abs(p.y - f.minY) <= w, top = abs(p.y - f.maxY) <= w
            let grip: Grip
            switch (left, right, top, bottom) {
            case (true, _, true, _): grip = .topLeft
            case (_, true, true, _): grip = .topRight
            case (true, _, _, true): grip = .bottomLeft
            case (_, true, _, true): grip = .bottomRight
            case (true, _, _, _): grip = .left
            case (_, true, _, _): grip = .right
            case (_, _, true, _): grip = .top
            case (_, _, _, true): grip = .bottom
            default: grip = .move
            }
            return (step.regionID, grip)
        }
        return nil
    }

    private func cursor(for grip: Grip?) -> NSCursor {
        switch grip {
        case nil: return .arrow
        case .move: return .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight, .topRight, .bottomLeft: return .crosshair
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard drag == nil else { return }
        cursor(for: grip(at: convert(event.locationInWindow, from: nil))?.1).set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (id, grip) = grip(at: p), let frame = frames[id] else { return }
        drag = (id, grip, p, frame)
        if grip == .move { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - drag.start.x, dy = p.y - drag.start.y
        var f = drag.frame
        switch drag.grip {
        case .move: f.origin.x += dx; f.origin.y += dy
        case .left: f.origin.x += dx; f.size.width -= dx
        case .right: f.size.width += dx
        case .bottom: f.origin.y += dy; f.size.height -= dy
        case .top: f.size.height += dy
        case .topLeft: f.origin.x += dx; f.size.width -= dx; f.size.height += dy
        case .topRight: f.size.width += dx; f.size.height += dy
        case .bottomLeft: f.origin.x += dx; f.size.width -= dx; f.origin.y += dy; f.size.height -= dy
        case .bottomRight: f.size.width += dx; f.origin.y += dy; f.size.height -= dy
        }
        frames[drag.regionID] = snapped(f, moving: drag.grip == .move)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        cursor(for: grip(at: convert(event.locationInWindow, from: nil))?.1).set()
    }

    /// Snap a frame's edges to the layout grid over the visible area (minus the gap), and
    /// keep it at least one cell big and on the display.
    private func snapped(_ f: CGRect, moving: Bool) -> CGRect {
        let area = visible.insetBy(dx: gap / 2, dy: gap / 2)
        let cw = area.width / CGFloat(max(grid.cols, 1)), ch = area.height / CGFloat(max(grid.rows, 1))
        func sx(_ x: CGFloat) -> CGFloat { area.minX + ((x - area.minX) / cw).rounded() * cw }
        func sy(_ y: CGFloat) -> CGFloat { area.minY + ((y - area.minY) / ch).rounded() * ch }
        // Work with the gap-less cell rect, then put the gap back.
        let outer = f.insetBy(dx: -gap / 2, dy: -gap / 2)
        var r: CGRect
        if moving {
            let w = max(cw, (outer.width / cw).rounded() * cw), h = max(ch, (outer.height / ch).rounded() * ch)
            r = CGRect(x: sx(outer.minX), y: sy(outer.minY), width: w, height: h)
        } else {
            let x0 = sx(outer.minX), x1 = sx(outer.maxX), y0 = sy(outer.minY), y1 = sy(outer.maxY)
            r = CGRect(x: min(x0, x1), y: min(y0, y1), width: max(cw, abs(x1 - x0)), height: max(ch, abs(y1 - y0)))
        }
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        return r.insetBy(dx: gap / 2, dy: gap / 2)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        for step in fromSteps {
            guard let frame = step.from?.frame else { continue }
            let path = NSBezierPath(roundedRect: local(frame).insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.lineWidth = 2
            NSColor.white.withAlphaComponent(0.6).setStroke()
            path.stroke()
            label("\(step.occupant) leaves for \(step.to.screen ?? "?")", sub: nil, in: local(frame), color: .white)
        }
        for step in steps {
            guard let frame = frames[step.regionID] else { continue }
            let edited = frame != originals[step.regionID]
            let r = frame.insetBy(dx: 3, dy: 3)
            let color = LoadoutPreview.color(for: step.action)
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            color.withAlphaComponent(0.22).setFill()
            path.fill()
            (edited ? NSColor.white : color.withAlphaComponent(0.95)).setStroke()
            path.lineWidth = 3
            path.stroke()
            // Where the window is now, when it is on this display too.
            if let from = step.from?.frame, step.from?.screen == step.to.screen, step.action != .stay {
                let old = NSBezierPath(roundedRect: local(from).insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
                old.setLineDash([5, 4], count: 2, phase: 0)
                old.lineWidth = 1.5
                color.withAlphaComponent(0.6).setStroke()
                old.stroke()
            }
            var sub = edited ? "region changed · Apply saves it" : "\(LoadoutPreview.label(for: step.action)) — \(step.reason)"
            if !edited, let space = step.to.space, step.action == .switchSpace { sub += " · desktop \(space)" }
            label(step.occupant, sub: sub, in: r, color: edited ? .white : color)
        }
    }

    private func label(_ title: String, sub: String?, in r: CGRect, color: NSColor) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let s = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
        if let sub {
            s.append(NSAttributedString(string: "\n" + sub, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para]))
        }
        let width = max(min(r.width - 24, 520), 60)
        let size = s.boundingRect(with: CGSize(width: width, height: r.height), options: [.usesLineFragmentOrigin]).size
        let box = CGRect(x: r.midX - size.width / 2 - 12, y: r.midY - size.height / 2 - 8,
                         width: size.width + 24, height: size.height + 16)
        let bg = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.55).setFill()
        bg.fill()
        color.withAlphaComponent(0.8).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        s.draw(with: box.insetBy(dx: 12, dy: 8), options: [.usesLineFragmentOrigin])
    }
}

/// A display at thumbnail size with one desktop's regions coloured by action.
private final class MiniMapView: NSView {
    private let screenFrame: CGRect
    private let steps: [PlacementPlan.Step]

    init(screen: NSScreen, steps: [PlacementPlan.Step], width: CGFloat) {
        screenFrame = screen.frame
        self.steps = steps
        let height = (width * screen.frame.height / max(screen.frame.width, 1)).rounded()
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: height))
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let scale = bounds.width / max(screenFrame.width, 1)
        let box = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.08).setFill()
        box.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        box.lineWidth = 1
        box.stroke()
        for step in steps {
            guard let frame = step.to.frame else { continue }
            let r = CGRect(x: (frame.minX - screenFrame.minX) * scale, y: (frame.minY - screenFrame.minY) * scale,
                           width: frame.width * scale, height: frame.height * scale).insetBy(dx: 1, dy: 1)
            let color = LoadoutPreview.color(for: step.action)
            let path = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            color.withAlphaComponent(0.35).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1
            path.stroke()
            let name = NSAttributedString(string: step.occupant, attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .medium), .foregroundColor: NSColor.white])
            if name.size().width < r.width - 4 {
                name.draw(at: CGPoint(x: r.midX - name.size().width / 2, y: r.midY - name.size().height / 2))
            }
        }
    }
}
