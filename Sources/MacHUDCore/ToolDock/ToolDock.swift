import AppKit
import Combine
import HUDKit

/// A display as the tool dock sees it (Cocoa coordinates).
struct ToolDockScreen: Equatable {
    var name: String
    var frame: CGRect
    /// Minus the menu bar and the system Dock.
    var visible: CGRect
}

/// MacHUD's dock: one button per sibling app, hover apps first then windowed ones, on a
/// glass strip at one of eight positions (an edge: a row or column; a corner: an L).
/// Hover buttons drop their panel out of the dock while the pointer is on them (see
/// `ToolDockHover`); windowed buttons summon and dismiss their panel, which comes back
/// where it was. Buttons of apps that take files accept file drops. Registered as the
/// `tooldock` panel, so loadouts can place it; its frames go to `HUDDockRegistry` so
/// sibling strips (Sift's dock mode) can sit next to it.
@MainActor
final class ToolDock: NSObject, Panel {
    let id = "tooldock"
    let title = "Tool Dock"
    let symbol = "dock.rectangle"

    let registry: PanelRegistry
    let externals: ExternalPanels
    weak var host: MacHUDPanelHost?
    weak var parking: ParkingController?
    /// The `toolDock` block of layouts.json, and how to write it back.
    var config: () -> ToolDockConfig
    var saveConfig: (ToolDockConfig) -> Void
    /// Regions of the active layout, for "Place in Region".
    var regions: () -> [(name: String, frame: FractionRect)] = { [] }
    /// Opens the settings window on a tab (app bundle id or `machud`).
    var openSettings: ((String) -> Void)?
    var screens: () -> [ToolDockScreen] = { ToolDock.systemScreens() }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Where the dock's frames are published for sibling strips; nil publishes nothing.
    var dockRegistry: HUDDockRegistry?
    /// The key the dock publishes under: MacHUD's bundle id.
    var registryID = Bundle.main.bundleIdentifier ?? "com.jrisberg.machud"
    /// false in tests: no windows and no timer; `step` drives the hover logic.
    let ui: Bool
    /// `tooldock pointer x= y=`: where the hover logic takes the pointer to be instead of
    /// the real one, for scripted checks. nil follows the mouse.
    var pointerOverride: CGPoint?

    private let store: ToolDockStore
    private(set) var memory: ToolDockState
    private(set) var items: [ToolDockItem] = []
    private(set) var hover = ToolDockHover()
    private var autoHide = HoverReveal(hoverDelay: 0.05, leaveDelay: HoverReveal.leaveDelay)
    /// Where each shown hover button's panel was put (screen coordinates).
    private(set) var hoverFrames: [String: CGRect] = [:]
    /// The auto-hidden dock is waiting past its edge.
    private(set) var tucked = false
    /// Other strips in the registry, as last seen by the watch.
    private(set) var neighbors: [String: HUDDockRegistry.Entry] = [:]
    private var published: HUDDockRegistry.Entry?
    private var registryWatch: AnyCancellable?

    private var dockWindow: ToolDockWindow?
    private var view: HUDDockStripView?
    private var timer: Timer?
    private var ticks = 0
    private var programmaticMoves = 0
    /// The strip is being dragged (a press on it moved past `HUDDockStripView.dragThreshold`;
    /// it reports the end). Hover panels are closed and stay closed until it ends.
    private(set) var isDragging = false
    private var menuOpen = false
    private var shownConfig: ToolDockConfig?
    /// Set while a click or summon drives the hover machine, so the hover panel it shows
    /// reports not reaching the screen; a passing hover only records it.
    private var showsLoudly = false

    init(registry: PanelRegistry, externals: ExternalPanels, config: @escaping () -> ToolDockConfig,
         saveConfig: @escaping (ToolDockConfig) -> Void, stateURL: URL = ToolDockStore.defaultURL, ui: Bool = true) {
        self.registry = registry
        self.externals = externals
        self.config = config
        self.saveConfig = saveConfig
        self.ui = ui
        store = ToolDockStore(url: stateURL)
        memory = store.load()
        super.init()
    }

    static func systemScreens() -> [ToolDockScreen] {
        // The first screen is the one with the menu bar.
        NSScreen.screens.map { ToolDockScreen(name: $0.localizedName, frame: $0.frame, visible: $0.visibleFrame) }
    }

    /// `MACHUD_DOCKS_FILE`, else `docks.json` beside an isolated
    /// instance's `MACHUD_CONFIG`, else the shared `HUDDockRegistry.defaultURL`.
    static var registryURL: URL {
        if let path = Env.value("DOCKS_FILE"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let config = Env.configURL { return config.deletingLastPathComponent().appendingPathComponent("docks.json") }
        return HUDDockRegistry.defaultURL
    }

    // MARK: - Panel

    var window: NSWindow? { dockWindow }
    var isVisible: Bool { config().isEnabled && (!ui || dockWindow?.isVisible == true) }
    func show() { setEnabled(true) }
    func hide() { setEnabled(false) }

    func setEnabled(_ on: Bool) {
        var c = config()
        guard c.isEnabled != on else { refresh(); return }
        c.enabled = on
        saveConfig(c)
        refresh()
    }

    // MARK: - Geometry

    struct Geometry {
        var layout: ToolDockLayout
        /// The dock when showing, screen coordinates.
        var placement: ToolDockLayout.Placement
        /// The dock's window when auto-hidden.
        var hidden: CGRect
        var screen: ToolDockScreen

        var frame: CGRect { placement.frame }
    }

    func geometry() -> Geometry? {
        let list = screens()
        guard let first = list.first else { return nil }
        let c = config()
        let screen = list.first { $0.name == c.screen } ?? first
        let groups = ToolDockModel.groups(items)
        let layout = ToolDockLayout(position: c.dockPosition, iconSize: CGFloat(c.icon))
            .fitted(groups: groups, visible: screen.visible)
        let placement = layout.place(groups: groups, visible: screen.visible)
        return Geometry(layout: layout, placement: placement,
                        hidden: layout.hiddenFrame(placement.frame, screen: screen.frame), screen: screen)
    }

    /// A button's icon on screen (where it is when the dock shows).
    func buttonFrame(_ itemID: String, in g: Geometry? = nil) -> CGRect? {
        guard let g = g ?? geometry(), let i = items.firstIndex(where: { $0.id == itemID }),
              g.placement.items.indices.contains(i) else { return nil }
        return g.placement.items[i]
    }

    /// A button's hit area and the edge its panel slides out of.
    func slot(_ itemID: String, in g: Geometry? = nil) -> (frame: CGRect, edge: HUDEdge)? {
        guard let g = g ?? geometry(), let i = items.firstIndex(where: { $0.id == itemID }),
              let frame = g.placement.slot(i) else { return nil }
        return (frame, g.placement.itemEdges[i])
    }

    // MARK: - Refresh

    /// Brings buttons, indicators, the window and the published frames in line with the
    /// config, the discovered apps and the parked windows. Cheap when nothing changed.
    func refresh() {
        let c = config()
        parking?.orbsHiddenByDefault = c.isEnabled
        let hasParked = (parking?.orbsHidden ?? false) && !(parking?.parked.isEmpty ?? true)
        let next = ToolDockModel.items(apps: externals.apps, hasParked: hasParked, hidden: externals.config().hiddenFromDock)
        if next != items {
            items = next
            perform(hover.retain(Set(items.filter(\.isHover).map(\.id))))
        }
        watchRegistry()
        guard c.isEnabled, let g = geometry() else {
            unpublish()
            guard ui else { return }
            stopTimer()
            if let w = dockWindow, w.isVisible { HUDAnimation.fadeOut(w) }
            shownConfig = nil
            return
        }
        publish(g)
        guard ui else { return }
        let window = dockWindow ?? makeWindow()
        if let view {
            view.style = g.layout.style
            view.magnify = c.isMagnified
            view.apply(items: items.map { $0.stripItem(indicator: indicator(for: $0)) }, placement: g.placement.local)
        }
        if !c.isAutoHide {
            tucked = false
            _ = autoHide.conceal()
        } else if shownConfig?.isAutoHide != true {
            // Just turned on: start hidden.
            tucked = true
            _ = autoHide.conceal()
        }
        let target = tucked ? g.hidden : g.frame
        if !isDragging {
            if !window.isVisible {
                setFrame(target, animated: false)
                HUDAnimation.fadeIn(window)
            } else if window.frame != target {
                setFrame(target, animated: true)
            }
        }
        shownConfig = c
        startTimer()
    }

    // MARK: - Dock registry

    private func publish(_ g: Geometry) {
        guard let dockRegistry else { return }
        let entry = HUDDockRegistry.Entry(position: g.layout.position, frames: g.placement.segments, pid: getpid())
        guard published?.position != entry.position || published?.frames != entry.frames else { return }
        do {
            try dockRegistry.publish(appID: registryID, position: entry.position, frames: entry.frames)
            published = entry
        } catch {
            NSLog("MacHUD: could not publish the tool dock to %@: %@", dockRegistry.url.path, "\(error)")
        }
    }

    private func unpublish() {
        guard let dockRegistry, published != nil else { return }
        try? dockRegistry.remove(appID: registryID)
        published = nil
    }

    /// Follows the other strips (for `tooldock state`'s `neighbors`); the dock itself does
    /// not move for them.
    private func watchRegistry() {
        guard let dockRegistry, registryWatch == nil else { return }
        neighbors = dockRegistry.others(than: registryID)
        let id = registryID
        registryWatch = dockRegistry.watch { [weak self] entries in
            MainActor.assumeIsolated {
                self?.neighbors = entries.filter { $0.key != id && $0.value.isLive }
            }
        }
    }

    /// Stops publishing (the app is quitting).
    func withdraw() {
        unpublish()
        registryWatch = nil
    }

    private func makeWindow() -> ToolDockWindow {
        let w = ToolDockWindow.make()
        let v = HUDDockStripView(frame: CGRect(origin: .zero, size: w.frame.size))
        v.autoresizingMask = [.width, .height]
        v.delegate = self
        w.contentView = v
        dockWindow = w
        view = v
        return w
    }

    private func setFrame(_ frame: CGRect, animated: Bool) {
        guard let w = dockWindow else { return }
        programmaticMoves += 1
        if animated {
            HUDAnimation.animate(w, to: frame, duration: HUDAnimation.revealDuration, timing: HUDAnimation.revealTiming) {
                [weak self] in self?.programmaticMoves -= 1
            }
        } else {
            w.setFrame(frame, display: true)
            programmaticMoves -= 1
        }
    }

    // MARK: - Indicators

    func indicator(for item: ToolDockItem) -> HUDDockIndicator {
        if hover.isShown(item.id) { return .visible }
        switch item.source {
        case .app(let appID):
            if item.panelIDs.contains(where: { registry.panel(id: $0)?.isVisible == true }) { return .visible }
            let health = externals.supervisor.record(appID)?.health
            let running = health == .running || health == .socketUnreachable || health == .launching
                || !externals.supervisor.livePIDs(appID).isEmpty
            return running ? .running : .none
        case .parked:
            return .running
        }
    }

    private func updateIndicators() {
        guard let view else { return }
        view.setIndicators(Dictionary(items.map { ($0.id, indicator(for: $0)) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: - Hover

    private func startTimer() {
        guard ui, timer == nil else { return }
        // 60 Hz: the 60 ms show delay and 120 ms grace want a fine clock.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        ticks += 1
        if ticks % 30 == 0 { updateIndicators() }
        guard dockWindow?.isVisible == true, !isDragging else { return }
        step(mouse: pointerOverride ?? NSEvent.mouseLocation, now: now())
    }

    /// Where a shown hover panel is: the frame its app reports in `state`, else the one
    /// the dock gave it.
    func panelFrame(of itemID: String) -> CGRect? {
        if let item = items.first(where: { $0.id == itemID }), case .app(let appID) = item.source,
           let panelID = item.panelIDs.first.flatMap({ registry.panel(id: $0) as? ExternalPanel })?.panelID,
           let reported = externals.supervisor.record(appID)?.frames[panelID] {
            return reported
        }
        return hoverFrames[itemID]
    }

    /// Where the pointer may go while `itemID`'s panel shows: the dock bar, the panel and
    /// the rectangle between the button and the panel.
    func hoverRegion(_ itemID: String, in g: Geometry) -> [CGRect] {
        var out = g.placement.segments.map { $0.insetBy(dx: -2, dy: -2) }
        if let panel = panelFrame(of: itemID) {
            out.append(panel.insetBy(dx: -2, dy: -2))
            if let slot = slot(itemID, in: g)?.frame { out.append(Self.bridge(from: slot, to: panel)) }
        }
        return out
    }

    /// The rectangle between a button's hit area and its panel: across the panel's extent
    /// (and the button's), spanning the gap between them.
    static func bridge(from slot: CGRect, to panel: CGRect) -> CGRect {
        let horizontalGap = panel.minX >= slot.maxX || panel.maxX <= slot.minX
        let verticalGap = panel.minY >= slot.maxY || panel.maxY <= slot.minY
        if verticalGap && !horizontalGap {
            let minX = min(slot.minX, panel.minX), maxX = max(slot.maxX, panel.maxX)
            let minY = min(slot.maxY, panel.maxY), maxY = max(slot.minY, panel.minY)
            return CGRect(x: minX, y: min(minY, maxY), width: maxX - minX, height: abs(maxY - minY))
        }
        if horizontalGap && !verticalGap {
            let minY = min(slot.minY, panel.minY), maxY = max(slot.maxY, panel.maxY)
            let minX = min(slot.maxX, panel.maxX), maxX = max(slot.minX, panel.minX)
            return CGRect(x: min(minX, maxX), y: minY, width: abs(maxX - minX), height: maxY - minY)
        }
        return slot.union(panel)
    }

    /// One poll of the pointer: hover buttons and auto-hide. Public for tests.
    func step(mouse: CGPoint, now: TimeInterval) {
        guard !isDragging, let g = geometry() else { return }
        var buttons: [String: CGRect] = [:]
        if !tucked {
            for item in items where item.isHover {
                if let s = slot(item.id, in: g) { buttons[item.id] = s.frame }
            }
        }
        let region = hover.active.map { hoverRegion($0, in: g) } ?? []
        perform(hover.update(mouse: mouse, buttons: buttons, region: region, now: now))

        guard config().isAutoHide else { return }
        let overPanels = hover.shown.compactMap { panelFrame(of: $0) }.contains { $0.insetBy(dx: -4, dy: -4).contains(mouse) }
        let inside = g.placement.contains(mouse) || overPanels || menuOpen || !hover.shown.isEmpty
        let trigger = tucked ? g.layout.revealZone(g.frame, screen: g.screen.frame).contains(mouse) : inside
        switch autoHide.update(onTrigger: trigger, inside: inside, now: now) {
        case .reveal?:
            tucked = false
            setFrame(g.frame, animated: ui)
        case .conceal?:
            tucked = true
            if ui, let w = dockWindow {
                programmaticMoves += 1
                HUDAnimation.conceal(w, to: g.hidden, fade: false) { [weak self] in self?.programmaticMoves -= 1 }
            }
        case nil:
            break
        }
    }

    /// How long a cross-fade's hide waits for the new panel's app to take its show.
    static let crossFadeLimit: TimeInterval = 0.15

    /// Runs the hover machine's events. A show followed by hides is a cross-fade: the new
    /// panel's `panel show` goes out first and the old ones' `panel hide` as soon as its
    /// app has taken it (at most `crossFadeLimit` later, and at once if that app is not
    /// listening yet), so the new panel is on its way in before the old one starts out.
    private func perform(_ events: [ToolDockHover.Event]) {
        guard events.count > 1, case .show(let new) = events[0] else {
            for event in events {
                switch event {
                case .show(let id): showHover(id)
                case .hide(let id): hideHover(id)
                }
            }
            updateIndicators()
            return
        }
        let hides = events.dropFirst().compactMap { e -> String? in if case .hide(let id) = e { return id }; return nil }
        var done = false
        let hideOld: () -> Void = { [weak self] in
            guard !done, let self else { return }
            done = true
            for id in hides { self.hideHover(id) }
            self.updateIndicators()
        }
        showHover(new, then: hideOld)
        if !done {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.crossFadeLimit) { MainActor.assumeIsolated { hideOld() } }
        }
        updateIndicators()
    }

    /// A hover button's panel, sliding out of the button (launching its app if needed).
    /// `then` runs once its app has answered the show (or at once when it is not listening).
    private func showHover(_ itemID: String, then: (() -> Void)? = nil) {
        guard let item = items.first(where: { $0.id == itemID }), let g = geometry(),
              let slot = slot(itemID, in: g) else { then?(); return }
        if item.source == .parked {
            _ = parking?.reveal(edge: nil, pin: false)
            hoverFrames[itemID] = (parking?.parked ?? []).reduce(CGRect.null) { $0.union($1.record.rest) }
            then?()
            return
        }
        guard let panelID = item.panelIDs.first, let panel = registry.panel(id: panelID) as? ExternalPanel else {
            then?()
            return
        }
        let size = memory.frames[panel.id]?.size ?? panel.descriptor.defaultSize?.cgSize ?? CGSize(width: 420, height: 480)
        let frame = ToolDockLayout.panelFrame(size: size, slot: slot.frame, edge: slot.edge,
                                               dock: g.placement.segments, visible: g.screen.visible)
        hoverFrames[itemID] = frame
        let listening = panel.health == .running
        panel.requestFrame(frame)
        panel.show(HUDPanelTransition(from: slot.edge, anchor: slot.frame, reason: .hover), loud: showsLoudly) { _ in
            if listening { then?() }
        }
        if !listening { then?() }
    }

    private func hideHover(_ itemID: String) {
        let slot = self.slot(itemID)
        hoverFrames[itemID] = nil
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        if item.source == .parked {
            _ = parking?.conceal(edge: nil)
            return
        }
        guard let panelID = item.panelIDs.first, let panel = registry.panel(id: panelID) as? ExternalPanel else { return }
        // A panel the user resized keeps that size next time.
        if panel.health == .running,
           let now = externals.supervisor.record(panel.app.id)?.frames[panel.panelID] ?? panel.currentFrame {
            remember(now, for: panel.id)
        }
        panel.hide(HUDPanelTransition(to: slot?.edge, anchor: slot?.frame, reason: .hover))
    }

    // MARK: - Clicks

    func click(_ item: ToolDockItem, anchor: NSView?) {
        switch item.behaviour {
        case .hover:
            loudly { perform(hover.click(item.id)) }
        case .windowed:
            guard let id = item.panelIDs.first, let panel = registry.panel(id: id) else { return }
            toggle(panel, reason: .click)
        case .menu:
            let menu = NSMenu()
            for id in item.panelIDs {
                guard let panel = registry.panel(id: id) else { continue }
                menu.addItem(ClosureMenuItem(title: panel.title, state: panel.isVisible) { [weak self] in
                    self?.toggle(panel, reason: .click)
                })
            }
            popUp(menu, anchor: anchor, event: nil)
        }
        updateIndicators()
    }

    private func loudly(_ body: () -> Void) {
        showsLoudly = true
        defer { showsLoudly = false }
        body()
    }

    /// Summons a hidden (or parked) panel, dismisses a showing one.
    func toggle(_ panel: Panel, reason: HUDPanelTransition.Reason = .summon) {
        if panel.isVisible, host?.mode(of: panel) != .parked {
            // A windowed sibling that is visible but covered, or on another Space, is not
            // "showing" from the user's point of view: a click brings it forward instead.
            if reason == .click, let external = panel as? ExternalPanel, hoverItem(for: panel) == nil,
               !Self.isFrontmost(bundleID: external.app.id) {
                summon(panel, reason: reason)
                return
            }
            dismiss(panel, reason: reason)
        } else {
            summon(panel, reason: reason)
        }
    }

    static func isFrontmost(bundleID: String) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// Hands keyboard focus to a sibling before asking it to show. macOS 14+ refuses an
    /// app's own `activate` while another app is active unless the active app yields.
    static func yieldFocus(to bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        if #available(macOS 14, *) {
            _ = app.activate(from: .current, options: [])
        } else {
            _ = app.activate(options: [])
        }
    }

    /// The button a panel belongs to.
    private func item(for panel: Panel) -> ToolDockItem? {
        items.first { $0.panelIDs.contains(panel.id) }
    }

    /// Puts the panel back where it was last dismissed (a hover panel: next to its button,
    /// pinned), sliding out of its button. Returns the frame it was sent to, if any.
    @discardableResult
    func summon(_ panel: Panel, reason: HUDPanelTransition.Reason = .summon) -> CGRect? {
        if let item = hoverItem(for: panel) {
            loudly { perform(hover.open(item.id, pin: true)) }
            return hoverFrames[item.id]
        }
        if let host, host.mode(of: panel) == .parked {
            try? host.setPanelMode(panel.id, mode: .full, options: HUDPanelModeOptions())
            return nil
        }
        let frame = memory.frame(for: panel.id, screens: screens().map(\.frame))
        if let external = panel as? ExternalPanel {
            if let frame { external.requestFrame(frame) }
            let slot = item(for: panel).flatMap { self.slot($0.id) }
            if reason != .hover { Self.yieldFocus(to: external.app.id) }
            external.show(HUDPanelTransition(from: slot?.edge, anchor: slot?.frame, reason: reason))
        } else {
            panel.show()
            if let frame, let w = panel.window { w.setFrame(frame, display: true) }
        }
        registry.noteChange()
        return frame
    }

    /// Hides the panel, remembering where it was. Returns that frame, if known.
    @discardableResult
    func dismiss(_ panel: Panel, reason: HUDPanelTransition.Reason = .summon) -> CGRect? {
        if let item = hoverItem(for: panel) {
            let frame = hoverFrames[item.id]
            perform(hover.close(item.id))
            return frame
        }
        var frame: CGRect?
        if let external = panel as? ExternalPanel {
            // Nothing to hide, and hiding would launch it.
            guard external.health != .notRunning, external.health != .notInstalled else { return nil }
            frame = externals.supervisor.record(external.app.id)?.frames[external.panelID] ?? external.currentFrame
            if let frame { remember(frame, for: panel.id) }
            let slot = item(for: panel).flatMap { self.slot($0.id) }
            external.hide(HUDPanelTransition(to: slot?.edge, anchor: slot?.frame, reason: reason))
        } else {
            if let w = panel.window, w.isVisible { frame = w.frame }
            if let frame { remember(frame, for: panel.id) }
            panel.hide()
        }
        registry.noteChange()
        return frame
    }

    private func remember(_ frame: CGRect, for panelID: String) {
        memory.remember(frame, for: panelID)
        store.save(memory)
    }

    private func hoverItem(for panel: Panel) -> ToolDockItem? {
        items.first { $0.isHover && $0.panelIDs.contains(panel.id) }
    }

    // MARK: - File drops

    /// Files dropped on a button: `action drop paths=…` to the panel that takes them,
    /// launching its app first if needed. False when the button takes no files.
    @discardableResult
    func drop(_ urls: [URL], on itemID: String) -> Bool {
        guard !urls.isEmpty, let item = items.first(where: { $0.id == itemID }), let panelID = item.dropPanelID,
              let panel = registry.panel(id: panelID) as? ExternalPanel else { return false }
        let title = item.title
        panel.drop(urls) { result in
            switch result {
            case .success(let reply) where reply["ok"] as? Bool == false:
                Toast.show("\(title) did not take the files", detail: "\(reply["error"] ?? "")")
            case .failure(let error):
                Toast.show("Could not hand the files to \(title)", detail: "\(error)")
            default:
                break
            }
        }
        return true
    }

    /// A file drag rested on a button: open its panel so the files can go straight in.
    func springLoad(_ itemID: String) {
        guard let item = items.first(where: { $0.id == itemID }), item.acceptsDrop else { return }
        if item.isHover {
            perform(hover.open(item.id, pin: false))
        } else if let id = item.dropPanelID ?? item.panelIDs.first, let panel = registry.panel(id: id), !panel.isVisible {
            summon(panel, reason: .click)
        }
    }

    // MARK: - Placement

    /// A loadout region (or `panel frame`) holding the tool dock: the position nearest its
    /// centre (an edge, or a corner for a region in one).
    func place(inRegion rect: CGRect) {
        let list = screens()
        guard let screen = list.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area })
            ?? list.first else { return }
        var c = config()
        c.enabled = true
        c.position = HUDDockPosition.nearest(to: CGPoint(x: rect.midX, y: rect.midY), in: screen.visible)
        c.screen = screen.name == list.first?.name ? nil : screen.name
        saveConfig(c)
        refresh()
    }

    /// Moves the dock (nil keeps what it has).
    func position(_ position: HUDDockPosition?, screen: String? = nil, iconSize: Double? = nil) {
        var c = config()
        if let position { c.position = position }
        if let screen { c.screen = screen.isEmpty ? nil : screen }
        if let iconSize { c.iconSize = iconSize }
        saveConfig(c)
        refresh()
    }

    func setAutoHide(_ on: Bool) {
        var c = config()
        c.autoHide = on
        saveConfig(c)
        refresh()
    }

    func setMagnify(_ on: Bool) {
        var c = config()
        c.magnify = on
        saveConfig(c)
        refresh()
    }

    /// The strip started moving: every hover panel goes (pinned ones too, sliding into their
    /// buttons), and none opens until the drag ends. Windowed panels are windows and stay.
    func beginDrag() {
        isDragging = true
        perform(hover.shown.flatMap { hover.close($0) })
    }

    /// A drag released at `point`: the nearest of the eight positions on that display.
    func finishDrag(at point: CGPoint) {
        let list = screens()
        guard let screen = list.first(where: { $0.frame.contains(point) }) ?? list.first else { return }
        var c = config()
        c.position = HUDDockPosition.nearest(to: point, in: screen.visible)
        c.screen = screen.name == list.first?.name ? nil : screen.name
        saveConfig(c)
        refresh()
        // Same position: put the window back.
        if ui, let g = geometry(), let w = dockWindow, w.frame != g.frame, !tucked { setFrame(g.frame, animated: true) }
    }

    // MARK: - Menus

    private func popUp(_ menu: NSMenu, anchor: NSView?, event: NSEvent?) {
        menuOpen = true
        defer { menuOpen = false }
        if let event, let anchor {
            NSMenu.popUpContextMenu(menu, with: event, for: anchor)
        } else if let anchor {
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: anchor.bounds.maxY + 6), in: anchor)
        }
    }

    private func showContextMenu(for item: ToolDockItem, anchor: NSView, event: NSEvent) {
        popUp(contextMenu(for: item), anchor: anchor, event: event)
    }

    /// Show, Hide, Park at Edge, Place in Region per panel; Quit and Settings for the app;
    /// then the dock's own options, as the Dock's menu has.
    func contextMenu(for item: ToolDockItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let panels = item.panelIDs.compactMap { registry.panel(id: $0) }
        for panel in panels {
            let target: NSMenu
            if panels.count > 1 {
                let sub = NSMenu()
                let holder = NSMenuItem(title: panel.title, action: nil, keyEquivalent: "")
                holder.submenu = sub
                menu.addItem(holder)
                target = sub
            } else {
                target = menu
            }
            for mi in panelItems(panel) { target.addItem(mi) }
        }
        if item.source == .parked {
            menu.addItem(ClosureMenuItem(title: "Reveal Parked Windows") { [weak self] in
                _ = self?.parking?.reveal(edge: nil, pin: true)
            })
            menu.addItem(ClosureMenuItem(title: "Unpark All") { [weak self] in _ = self?.parking?.unpark(id: nil) })
        }
        if case .app(let appID) = item.source, let app = externals.app(matching: appID) {
            menu.addItem(.separator())
            let health = externals.supervisor.record(appID)?.health ?? .notRunning
            if health == .notRunning || health == .notInstalled {
                menu.addItem(ClosureMenuItem(title: "Launch \(app.name)") { [weak self] in
                    _ = self?.externals.launch(app, manual: true)
                })
            } else {
                menu.addItem(ClosureMenuItem(title: "Quit \(app.name)") { [weak self] in
                    self?.externals.supervisor.quit(app.id) { _ in }
                })
            }
            menu.addItem(ClosureMenuItem(title: "\(app.name) Settings…") { [weak self] in self?.openSettings?(app.id) })
        } else {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "MacHUD Settings…") { [weak self] in self?.openSettings?("machud") })
        }
        menu.addItem(.separator())
        for mi in dockOptionItems() { menu.addItem(mi) }
        return menu
    }

    private func panelItems(_ panel: Panel) -> [NSMenuItem] {
        var out: [NSMenuItem] = [
            ClosureMenuItem(title: "Show", enabled: !panel.isVisible || host?.mode(of: panel) == .parked) { [weak self] in
                self?.summon(panel)
            },
            ClosureMenuItem(title: "Hide", enabled: panel.isVisible) { [weak self] in self?.dismiss(panel) },
        ]
        let park = NSMenuItem(title: "Park at Edge", action: nil, keyEquivalent: "")
        let edges = NSMenu()
        for edge in HUDEdge.allCases {
            edges.addItem(ClosureMenuItem(title: edge.rawValue.capitalized) { [weak self] in
                do {
                    try self?.host?.setPanelMode(panel.id, mode: .parked, options: HUDPanelModeOptions(edge: edge))
                } catch {
                    Toast.show("Could not park \(panel.title)", detail: "\(error)")
                }
            })
        }
        park.submenu = edges
        out.append(park)
        let regions = self.regions()
        let place = NSMenuItem(title: "Place in Region", action: nil, keyEquivalent: "")
        let list = NSMenu()
        for region in regions {
            list.addItem(ClosureMenuItem(title: region.name) { [weak self] in self?.place(panel, in: region.frame) })
        }
        place.submenu = list
        place.isEnabled = !regions.isEmpty
        out.append(place)
        return out
    }

    /// Places a panel in a region of the active layout, on the dock's screen.
    private func place(_ panel: Panel, in region: FractionRect) {
        guard let g = geometry() else { return }
        let rect = region.cocoaRect(in: g.screen.visible)
        do {
            try host?.setPanelFrame(panel.id, frame: rect)
        } catch {
            Toast.show("Could not place \(panel.title)", detail: "\(error)")
        }
    }

    /// Position, Auto-hide, Magnification: shared by the right-click and status menus.
    func dockOptionItems() -> [NSMenuItem] {
        let c = config()
        let position = NSMenuItem(title: "Position on Screen", action: nil, keyEquivalent: "")
        let edges = NSMenu()
        for (i, p) in Self.menuPositions.enumerated() {
            if i == 4 { edges.addItem(.separator()) }
            edges.addItem(ClosureMenuItem(title: Self.title(of: p), state: c.dockPosition == p) { [weak self] in
                self?.position(p)
            })
        }
        position.submenu = edges
        return [
            position,
            ClosureMenuItem(title: "Auto-hide", state: c.isAutoHide) { [weak self] in self?.setAutoHide(!c.isAutoHide) },
            ClosureMenuItem(title: "Magnification", state: c.isMagnified) { [weak self] in self?.setMagnify(!c.isMagnified) },
        ]
    }

    /// The status menu's "Tool Dock" submenu.
    func statusMenuItems() -> [NSMenuItem] {
        let c = config()
        let item = NSMenuItem(title: "Tool Dock", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu()
        sub.addItem(ClosureMenuItem(title: "Show Tool Dock", state: c.isEnabled) { [weak self] in
            self?.setEnabled(!c.isEnabled)
        })
        for mi in dockOptionItems() { sub.addItem(mi) }
        item.submenu = sub
        return [item]
    }

    // MARK: - State

    static let menuPositions: [HUDDockPosition] = [.bottom, .left, .right, .top,
                                                   .bottomLeft, .bottomRight, .topLeft, .topRight]

    /// `topLeft` → "Top Left".
    static func title(of position: HUDDockPosition) -> String {
        position.rawValue.reduce(into: "") { out, ch in
            if ch.isUppercase { out += " " }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
    }

    var json: [String: Any] {
        let c = config()
        var d: [String: Any] = ["enabled": c.isEnabled, "position": c.dockPosition.rawValue,
                                "autoHide": c.isAutoHide, "iconSize": c.icon, "magnify": c.isMagnified,
                                "visible": isVisible, "tucked": tucked]
        if let screen = c.screen { d["screen"] = screen }
        let g = geometry()
        if let g {
            d["frame"] = Self.rect(g.frame)
            d["segments"] = g.placement.segments.map(Self.rect)
            d["dividers"] = g.placement.dividers.map(Self.rect)
            d["screenName"] = g.screen.name
        }
        d["buttons"] = items.enumerated().map { i, item -> [String: Any] in
            var b: [String: Any] = ["id": item.id, "title": item.title, "panels": item.panelIDs,
                                    "group": item.group == 0 ? "hover" : "windowed",
                                    "kind": { switch item.behaviour { case .hover: return "hover"
                                                                      case .windowed: return "windowed"
                                                                      case .menu: return "menu" } }(),
                                    "acceptsDrop": item.acceptsDrop,
                                    "indicator": { switch indicator(for: item) { case .none: return "none"
                                                                                 case .running: return "running"
                                                                                 case .visible: return "visible" } }()]
            if let label = item.stripLabel { b["label"] = label }
            if item.isHover {
                b["revealed"] = hover.isShown(item.id)
                b["pinned"] = hover.isPinned(item.id)
                if let f = hoverFrames[item.id] { b["panelFrame"] = Self.rect(f) }
            }
            if let g, g.placement.items.indices.contains(i) {
                b["frame"] = Self.rect(g.placement.items[i])
                b["edge"] = g.placement.itemEdges[i].rawValue
            }
            return b
        }
        d["neighbors"] = neighbors.mapValues { e -> [String: Any] in
            ["position": e.position.rawValue, "frames": e.frames.map(Self.rect)]
        }
        d["remembered"] = memory.frames.mapValues(Self.rect)
        if let p = pointerOverride { d["pointer"] = ["x": Double(p.x), "y": Double(p.y)] }
        d["dragging"] = isDragging
        if let shown = view?.shownLabel { d["labelShown"] = shown }
        return d
    }

    static func rect(_ f: CGRect) -> [String: Int] {
        ["x": Int(f.minX.rounded()), "y": Int(f.minY.rounded()), "w": Int(f.width.rounded()), "h": Int(f.height.rounded())]
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, state on: Bool? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let on { state = on ? .on : .off }
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { run() }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// MARK: - The strip's events

extension ToolDock: HUDDockStripDelegate {
    private func item(_ stripItem: HUDDockItem) -> ToolDockItem? { items.first { $0.id == stripItem.id } }

    func dockStrip(_ strip: HUDDockStripView, didClick item: HUDDockItem, tile: HUDDockTile) {
        guard let item = self.item(item) else { return }
        click(item, anchor: tile)
    }

    func dockStrip(_ strip: HUDDockStripView, didRightClick item: HUDDockItem, tile: HUDDockTile, event: NSEvent) {
        guard let item = self.item(item) else { return }
        showContextMenu(for: item, anchor: tile, event: event)
    }

    func dockStrip(_ strip: HUDDockStripView, didDrop urls: [URL], on item: HUDDockItem, copy: Bool) {
        _ = drop(urls, on: item.id)
    }

    func dockStrip(_ strip: HUDDockStripView, springLoad item: HUDDockItem) { springLoad(item.id) }

    func dockStripDidBeginDrag(_ strip: HUDDockStripView) { beginDrag() }

    func dockStrip(_ strip: HUDDockStripView, didDragTo position: HUDDockPosition, at point: CGPoint, on screen: NSScreen?) {
        isDragging = false
        finishDrag(at: point)
    }

    func dockStripDidEndDrag(_ strip: HUDDockStripView) { isDragging = false }

    /// `tooldock mouse`: a synthesized pointer event at `point` (screen coordinates) for
    /// scripted checks. The hover logic takes the pointer to be there (`pointerOverride`);
    /// `move` enters and leaves tiles as their tracking areas would; `down`/`drag`/`up` go
    /// through the dock window like real presses. Returns an error, or nil.
    func simulateMouse(_ phase: String, at point: CGPoint) -> String? {
        guard ui, let w = dockWindow, let view else { return "no dock window" }
        pointerOverride = point
        let local = w.convertPoint(fromScreen: point)
        let types: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged, "up": .leftMouseUp]
        if phase == "move" {
            let crossing = { (type: NSEvent.EventType) in
                NSEvent.enterExitEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                                       userData: nil)!
            }
            for tile in view.tiles where !tile.isHidden {
                let inside = tile.frame.contains(view.convert(local, from: nil))
                if inside != tile.isHovering {
                    if inside { tile.mouseEntered(with: crossing(.mouseEntered)) } else { tile.mouseExited(with: crossing(.mouseExited)) }
                }
            }
            if !w.frame.contains(point) { view.mouseExited(with: crossing(.mouseExited)) }
            return nil
        }
        guard let type = types[phase] else { return "phase must be move, down, drag or up" }
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return "could not make the event" }
        w.sendEvent(event)
        return nil
    }

    /// `tooldock snapshot path=`: the strip as a PNG (glass drawn as a dark stand-in).
    func writeSnapshot(to url: URL) -> Bool { view?.writeSnapshot(to: url) ?? false }
}
