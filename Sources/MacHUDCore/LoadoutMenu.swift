import AppKit

/// Wires loadouts into the UI: the hold-to-show radial wheel, the status-bar
/// section, per-loadout hotkeys and the `radial` / `menu` / `preview` control commands.
/// Every list offers `ExperimentalLoadouts.offered` and a capture takes the display under the
/// pointer, unless multi-desktop loadouts (experimental) are on; each reads the config when
/// it is built, so turning the setting on or off needs no relaunch.
@MainActor
final class LoadoutMenu {
    private let store: LayoutStore
    /// Opens the visual editor (wired by the app so the empty-capture alert can offer it).
    var openEditor: (() -> Void)?
    /// Opens the editor on a fresh, empty layout (the capture wedge's outer ring, the menu's Draw a New Layout…).
    var openNewLayout: (() -> Void)?
    /// Opens the editor on a loadout's layout with that loadout selected.
    var editLoadout: ((String) -> Void)?
    /// Deletes loadouts and sets the startup one, as the settings tab and `loadouts` verb do.
    var library: LoadoutLibrary?
    private let engine: LoadoutEngine
    private let radial = RadialMenu()
    private var hotkeyIDs: [UInt32] = []
    private var registered: (menu: HotKey?, loadouts: [String: HotKey])?
    private var registrationDeferred = false
    private var lastApply: [String: Any]?

    /// Retained for the lifetime of the app so `main.swift` needs no new property.
    private(set) static var shared: LoadoutMenu?

    /// Says why a loadout or action was refused (multi-desktop loadouts are off): a toast, or
    /// a recorder in tests.
    var showRefusal: (_ title: String, _ detail: String) -> Void = { title, detail in
        Toast.show(title, detail: detail, seconds: 6)
    }

    @discardableResult
    static func install(store: LayoutStore, engine: LoadoutEngine, statusMenu: StatusMenu,
                        control: ControlServer? = nil) -> LoadoutMenu {
        let menu = LoadoutMenu(store: store, engine: engine)
        shared = menu
        statusMenu.primarySection = {
            var items: [NSMenuItem] = []
            MainActor.assumeIsolated { items = menu.menuItems() }
            return items
        }
        // DragMonitor already owns onChange; chain instead of replacing it.
        let previous = store.onChange
        store.onChange = { [weak menu] in
            previous?()
            MainActor.assumeIsolated { menu?.registerHotkeys() }
        }
        menu.registerHotkeys()
        if let control { menu.registerControl(control) }
        return menu
    }

    init(store: LayoutStore, engine: LoadoutEngine) {
        self.store = store
        self.engine = engine
        parkTargets = { [weak engine] in
            guard let engine else { return .init() }
            return .init(focused: engine.focusedWindowLabel(), parked: engine.parking.parked.map(\.record.label))
        }
        radial.onCommit = { [weak self] outcome in self?.handle(outcome) }
        radial.onDismiss = { [weak self] in
            guard let self, self.registrationDeferred else { return }
            self.registrationDeferred = false
            self.registerHotkeys()
        }
    }

    // MARK: Wedges

    /// What the widgets are doing (revealed, being edited), read as the wheel opens; nil while
    /// no app serves widgets, when the wheel has no Widgets wedge. `onWidgets` is what its rings
    /// do: toggle revealing (false) or editing (true).
    var widgetsState: (() -> RadialMenu.Wedge.WidgetsState?)?
    var onWidgets: ((Bool) -> Void)?

    /// What the park wedge acts on, read as the wheel opens: the focused window and the parked ones.
    var parkTargets: () -> RadialMenu.Wedge.ParkTargets

    func wedges() -> [RadialMenu.Wedge] {
        func symbol(_ name: String) -> [NSImage] {
            [NSImage(systemSymbolName: name, accessibilityDescription: nil)].compactMap { $0 }
        }
        var tools = [
            RadialMenu.Wedge(name: "Capture", icons: symbol("camera.viewfinder"),
                             kind: .capture(offersAllScreens: store.config.multiDesktopLoadouts)),
            RadialMenu.Wedge(name: "Park", icons: symbol("rectangle.portrait.and.arrow.right"), kind: .park(parkTargets())),
        ]
        if let state = widgetsState?() {
            tools.append(RadialMenu.Wedge(name: "Widgets", icons: symbol("square.grid.2x2"), kind: .widgets(state)))
        }
        return offered.map {
            RadialMenu.Wedge(name: $0.name, icons: RadialMenu.icons(for: $0, panels: engine.panels),
                             kind: .loadout($0.name), hotkey: $0.hotkey)
        } + tools
    }

    func showRadial(at point: CGPoint? = nil) {
        guard !radial.isVisible else { return }
        let hk = store.hotkeys.loadoutMenu
        radial.shiftSelectsOuter = !(hk?.modifiers.contains { $0.lowercased() == "shift" } ?? false)
        radial.show(wedges: wedges(), at: point)
    }

    private func handle(_ outcome: RadialMenu.Outcome) {
        switch outcome {
        case .cancelled:
            NSLog("MacHUD: loadout wheel cancelled")
        case .capture(let allScreens):
            captureCurrent(allScreens: allScreens)
        case .drawLayout:
            DispatchQueue.main.async { self.openNewLayout?() }
        case .widgets(let edit):
            DispatchQueue.main.async { self.onWidgets?(edit) }
        case .park(let restore):
            guard requireAccessibility(for: "park windows") else { return }
            if restore {
                let count = engine.parking.restoreAll(animated: true)
                Toast.show(count == 0 ? "Nothing is parked" : "Restored \(count) parked", seconds: 2)
            } else if let error = engine.parkFocusedWindow() {
                NSLog("MacHUD: park wedge: %@", error)
                Toast.show("Could not park", detail: error, seconds: 3)
            }
        case .apply(let name, let clear):
            guard let loadout = store.loadout(named: name) else { return }
            apply(loadout, clear: clear)
        case .preview(let name):
            guard let name = name ?? defaultLoadoutName, let loadout = store.loadout(named: name) else { return }
            // Out of the hotkey callback first, like capture.
            DispatchQueue.main.async { self.preview(loadout) }
        }
    }

    // MARK: Offered loadouts

    /// The loadouts the menu, the wheel and the hotkeys offer: all of them while multi-desktop
    /// loadouts are on, else the one-screen ones.
    private var offered: [Loadout] { ExperimentalLoadouts.offered(in: store.config) }

    /// The loadout a preview without a name shows: the one applied last if it is offered, else
    /// the first offered.
    var defaultLoadoutName: String? {
        let names = offered.map(\.name)
        if let active = engine.activeLoadout, names.contains(active) { return active }
        return names.first
    }

    /// Says why `loadout` cannot be used now and returns the reason; nil when it can.
    @discardableResult
    private func refuse(_ loadout: Loadout, _ verb: String) -> String? {
        guard let reason = ExperimentalLoadouts.refusal(for: loadout, in: store.config) else { return nil }
        NSLog("MacHUD: refused to %@ '%@': %@", verb, loadout.name, reason)
        showRefusal("Could not \(verb) \(loadout.name)", reason)
        return reason
    }

    // MARK: Actions

    /// Draw what applying `loadout` would do on every display; Apply runs it.
    func preview(_ loadout: Loadout) {
        guard refuse(loadout, "preview") == nil else { return }
        if !loadout.allSlots.isEmpty { requireAccessibility(for: "see where windows are") }
        let (steps, report) = engine.plan(loadout)
        var problems = report.redirected.map(\.summary)
        let covered = Set(steps.map(\.regionID)) .union(report.redirected.map { "screen:\($0.screen)" })
        problems += report.failed.filter { !covered.contains($0.key) }.map { "\($0.key): \($0.value)" }.sorted()
        LoadoutPreview.shared.show(loadout: loadout.name, steps: steps, problems: problems,
                                   grid: store.grid, gap: store.gap,
                                   onEdit: { [weak self] in self?.editLoadout?(loadout.name) }) { [weak self] edits in
            guard let self else { return }
            self.saveRegionEdits(edits, for: loadout)
            self.apply(loadout, clear: false)
        }
    }

    /// Regions moved or resized in the preview go into the layout the loadout uses on that
    /// display (the per-display assignment's layout, else the loadout's own).
    func saveRegionEdits(_ edits: [LoadoutPreview.RegionEdit], for loadout: Loadout) {
        guard !edits.isEmpty else { return }
        let descriptors = NSScreen.screens.map(\.descriptor)
        var config = store.config
        var changed = 0
        for edit in edits {
            guard let screen = NSScreen.screens.first(where: { $0.localizedName == edit.screen }),
                  let position = NSScreen.screens.firstIndex(of: screen) else { continue }
            let layoutName = (loadout.screens ?? []).first { $0.screen.index(in: descriptors) == position }?.layout
                ?? loadout.layout
            guard let li = config.layouts.firstIndex(where: { $0.name == layoutName }),
                  let ri = config.layouts[li].regionIndex(id: edit.regionID) else { continue }
            var region = config.layouts[li].regions[ri]
            if region.hit == region.frame { region.hit = nil }
            region.x = edit.rect.x; region.y = edit.rect.y; region.w = edit.rect.w; region.h = edit.rect.h
            config.layouts[li].regions[ri] = region
            changed += 1
        }
        guard changed > 0 else { return }
        store.save(config)
        NSLog("MacHUD: preview edited %d region(s) of '%@'", changed, loadout.name)
    }

    /// Without Accessibility MacHUD cannot see other apps' windows, let alone move them:
    /// every slot would plan as "launch" and time out. Say so instead.
    @discardableResult
    private func requireAccessibility(for what: String) -> Bool {
        guard !Accessibility.isTrusted else { return true }
        Toast.ask("MacHUD cannot \(what): Accessibility access is off",
                  button: "Open Settings", seconds: 8) { Accessibility.openSettings() }
        return false
    }

    func apply(_ loadout: Loadout, clear: Bool) {
        NSLog("MacHUD: applying loadout '%@' (%@)", loadout.name, clear ? "clear + load" : "load")
        lastApply = ["loadout": loadout.name, "clear": clear, "at": Date().timeIntervalSince1970]
        // A hidden loadout can still arrive here: a hotkey pressed as the setting changed, or a
        // loadout opened from somewhere else.
        if let reason = refuse(loadout, "apply") {
            lastApply?["report"] = ["ok": false, "error": reason]
            return
        }
        guard loadout.allSlots.isEmpty || requireAccessibility(for: "see or move windows") else {
            lastApply?["report"] = ["ok": false, "error": "accessibility access is off"]
            return
        }
        guard !loadout.allSlots.isEmpty || loadout.hud != nil else {
            Toast.show("\(loadout.name) has nothing to place",
                       detail: "Capture the current arrangement into it, or assign windows in the editor.", seconds: 4)
            return
        }
        let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation)
        engine.apply(loadout, clear: clear) { [weak self] report in
            NSLog("MacHUD: loadout '%@' placed %d, failed %d", report.loadout, report.placed.count, report.failed.count)
            var entry = self?.lastApply ?? [:]
            entry["report"] = report.json
            self?.lastApply = entry
            Toast.show(Self.summary(of: report, clear: clear), detail: Self.detail(of: report, loadout: loadout),
                       on: screen, seconds: report.failed.isEmpty && report.redirected.isEmpty ? 2.5 : 6)
        }
    }

    static func summary(of report: LoadoutEngine.ApplyReport, clear: Bool) -> String {
        var parts = ["\(report.loadout): placed \(report.placed.count)"]
        if clear { parts.append("cleared \(report.cleared)") }
        if !report.failed.isEmpty { parts.append("failed \(report.failed.count)") }
        return parts.joined(separator: " · ")
    }

    /// Where missing displays went, then per slot: what moved, switched desktops or
    /// launched, and whatever failed and why.
    static func detail(of report: LoadoutEngine.ApplyReport, loadout: Loadout) -> String? {
        var lines = report.redirected.map(\.summary)
        lines += report.detailLines { key in
            loadout.allSlots.first { $0.regionID == key }?.occupant.label ?? key
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Captures the windows on the display under the pointer, on the desktop showing, as a
    /// loadout. With multi-desktop loadouts on, `allScreens` true captures every display and nil
    /// decides from how many displays have windows (the menu bar), and the sheet offers to walk
    /// the desktops; with them off, `allScreens` true is refused.
    /// The prompt runs a modal, so never start it from inside the Carbon hotkey
    /// callback that dismissed the wheel: give the run loop a turn first.
    func captureCurrent(allScreens: Bool? = nil) {
        if allScreens == true, let reason = ExperimentalLoadouts.refusal(forAction: "Capturing every screen", in: store.config) {
            NSLog("MacHUD: refused to capture every screen: %@", reason)
            showRefusal("Could not capture every screen", reason)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let multiDesktop = self.store.config.multiDesktopLoadouts
            let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation)
            let everywhere = Self.capturesEveryScreen(
                allScreens: allScreens, screensWithWindows: multiDesktop ? self.engine.screensWithWindows().count : 1,
                multiDesktop: multiDesktop)
            let targets = everywhere ? NSScreen.screens : [screen ?? NSScreen.main].compactMap { $0 }
            // Desktops are counted, and offered for a walk, only with multi-desktop loadouts on.
            let counts = multiDesktop ? NSScreen.screens.map { Spaces.monitor(for: $0)?.count ?? 1 } : []
            let desktops = targets.compactMap { NSScreen.screens.firstIndex(of: $0) }
                .compactMap { counts.indices.contains($0) ? counts[$0] : nil }.max() ?? 1
            let place = everywhere ? "all \(targets.count) displays" : (screen?.localizedName ?? "this screen")
            guard let answer = self.prompt(title: "Capture the windows on \(place) as a loadout",
                                           value: self.suggestedName(),
                                           desktops: desktops > 1 ? desktops : nil),
                  !answer.name.isEmpty else {
                NSLog("MacHUD: capture cancelled")
                return
            }
            let name = answer.name
            if let reason = ExperimentalLoadouts.refusal(forName: name, in: self.store.config) {
                NSLog("MacHUD: refused to capture over hidden loadout '%@'", name)
                self.showRefusal("Could not capture \(name): a hidden loadout has that name", reason)
                return
            }
            let walk = answer.walkDesktops ? DesktopWalk.all(counts: counts) : nil
            self.engine.captureArrangement(name: name, layoutName: answer.layoutName ?? name,
                                           screens: targets, walk: walk) { capture in
                guard let capture else {
                    let alert = NSAlert()
                    alert.messageText = "Nothing to capture"
                    alert.informativeText = "No app window is on \(place) right now (MacHUD's own overlays don't count)."
                    alert.runModal()
                    return
                }
                self.engine.commit(capture, hideLayouts: answer.layoutName == nil)
                NSLog("MacHUD: captured '%@': %d regions, %d slots across %d screens",
                      name, capture.regionCount, capture.slotCount, capture.screens.count)
                let finish = { (hud: HUDLoadout?) in
                    var detail = Self.captureDetail(of: capture)
                    if let apps = hud?.apps?.count {
                        let widgets = hud?.widgets?.count ?? 0
                        detail += "\nTool dock + \(apps) app\(apps == 1 ? "" : "s")"
                            + (widgets > 0 ? " + \(widgets) widget\(widgets == 1 ? "" : "s")" : "") + " saved with it"
                    }
                    Toast.show("Captured \(name)", detail: detail, on: screen, seconds: 3.5)
                }
                if answer.includeHUD {
                    self.engine.captureHUD(into: name) { loadout in finish(loadout?.hud) }
                } else {
                    finish(nil)
                }
            }
        }
    }

    /// Whether a capture covers every display rather than the one under the pointer: only with
    /// multi-desktop loadouts on, when asked (the wheel's ring) or, when not asked (the menu
    /// bar), when more than one display has windows.
    nonisolated static func capturesEveryScreen(allScreens: Bool?, screensWithWindows: Int, multiDesktop: Bool) -> Bool {
        multiDesktop && (allScreens ?? (screensWithWindows > 1))
    }

    static func captureDetail(of capture: LoadoutEngine.ArrangementCapture) -> String {
        if capture.screens.count == 1 {
            return capture.screens[0].slots.map { $0.occupant.label }.joined(separator: " · ")
                + "\nRegions match the windows exactly · refine them in the editor"
        }
        return capture.screens.map { screen in
            let desktop = screen.space.map { " · Desktop \($0)" } ?? ""
            return "\(screen.screenName)\(desktop): \(screen.slots.count) window\(screen.slots.count == 1 ? "" : "s")"
        }.joined(separator: "\n")
    }

    private func suggestedName() -> String {
        let taken = Set(store.loadouts.map { $0.name } + store.layouts.map { $0.name })
        var n = 1
        while taken.contains("Loadout \(n)") { n += 1 }
        return "Loadout \(n)"
    }

    /// What the capture sheet asked for.
    struct CaptureAnswer: Equatable {
        var name: String
        /// nil: the layout is kept for the loadout only, not offered for ⇧-drag or other loadouts.
        var layoutName: String?
        var walkDesktops: Bool
        /// Save the tool dock and the siblings' panels into the same loadout.
        var includeHUD: Bool
    }

    /// The capture sheet's controls: the loadout's name; whether its layout is also kept as one
    /// to snap into and to build other loadouts on, and under what name; whether the HUD (tool
    /// dock and panels) is saved with it, off until ticked; and, when `desktops` is given
    /// (multi-desktop loadouts on, more than one desktop), whether to walk them.
    @MainActor
    struct CaptureSheet {
        static let width: CGFloat = 340
        let name: NSTextField
        let keepLayout: NSButton
        let layoutName: NSTextField
        let hud: NSButton
        let walk: NSButton?
        let view: NSStackView
        /// Keeps the layout name following the loadout name; lives as long as the sheet.
        private let sync: FieldSync

        var boxes: [NSButton] { [keepLayout, hud] + (walk.map { [$0] } ?? []) }

        init(name value: String, desktops: Int?) {
            name = NSTextField(frame: CGRect(x: 0, y: 0, width: Self.width, height: 24))
            name.stringValue = value
            name.placeholderString = "Loadout name"
            keepLayout = NSButton(checkboxWithTitle: "Also keep the layout on its own, for ⇧-drag and other loadouts",
                                  target: nil, action: nil)
            keepLayout.state = .on
            layoutName = NSTextField(frame: CGRect(x: 0, y: 0, width: Self.width, height: 24))
            layoutName.stringValue = value
            layoutName.placeholderString = "Layout name"
            sync = FieldSync(from: name, to: layoutName)
            keepLayout.target = sync
            keepLayout.action = #selector(FieldSync.toggled(_:))
            hud = NSButton(checkboxWithTitle: "Include the tool dock and the apps' panels (the HUD)", target: nil, action: nil)
            hud.state = .off
            walk = desktops.map { NSButton(checkboxWithTitle: "Also walk desktops 1…\($0)", target: nil, action: nil) }
            walk?.state = .off
            let views: [NSView] = [name, keepLayout, layoutName, hud] + (walk.map { [$0] } ?? [])
            view = NSStackView(views: views)
            view.orientation = .vertical
            view.alignment = .leading
            view.spacing = 8
            view.frame = CGRect(x: 0, y: 0, width: Self.width, height: CGFloat(views.count) * 30)
            for v in views { v.widthAnchor.constraint(equalToConstant: Self.width).isActive = true }
        }

        var answer: CaptureAnswer {
            let name = name.stringValue.trimmingCharacters(in: .whitespaces)
            let layout = layoutName.stringValue.trimmingCharacters(in: .whitespaces)
            return CaptureAnswer(name: name, layoutName: keepLayout.state == .on ? (layout.isEmpty ? name : layout) : nil,
                                 walkDesktops: walk?.state == .on, includeHUD: hud.state == .on)
        }
    }

    /// Runs the capture sheet; nil when cancelled.
    private func prompt(title: String, value: String, desktops: Int?) -> CaptureAnswer? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The windows become a layout (one region each) and a loadout that fills it."
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        let sheet = CaptureSheet(name: value, desktops: desktops)
        alert.accessoryView = sheet.view
        alert.window.initialFirstResponder = sheet.name
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return sheet.answer
    }

    // MARK: Hotkeys

    /// Carbon delivers the release event only to a still-registered hotkey, so
    /// re-register only when the keys actually changed, and never while the wheel
    /// is being held open.
    func registerHotkeys() {
        let menuKey = Env.noHotkeys ? nil : store.hotkeys.loadoutMenu
        let perLoadout = Env.noHotkeys ? [:] : Self.loadoutHotkeys(in: store.config)
        if let registered, registered.menu == menuKey, registered.loadouts == perLoadout { return }
        if radial.isVisible {
            registrationDeferred = true
            return
        }
        for id in hotkeyIDs { HotKeyCenter.shared.unregister(id) }
        hotkeyIDs.removeAll()
        registered = (menuKey, perLoadout)
        if let hk = menuKey,
           let id = HotKeyCenter.shared.register(hk, onPress: { [weak self] in
               MainActor.assumeIsolated { self?.showRadial() }
           }, onRelease: { [weak self] in
               MainActor.assumeIsolated { self?.radial.commit() }
           }) {
            hotkeyIDs.append(id)
        }
        for (name, hk) in perLoadout.sorted(by: { $0.key < $1.key }) {
            if let id = HotKeyCenter.shared.register(hk, onPress: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let l = self.store.loadout(named: name) else { return }
                    self.apply(l, clear: NSEvent.modifierFlags.contains(.shift))
                }
            }) {
                hotkeyIDs.append(id)
            }
        }
    }

    /// The hotkeys of the loadouts offered (`ExperimentalLoadouts.offered`), by loadout name: a
    /// hidden loadout's hotkey is free until multi-desktop loadouts are turned on.
    nonisolated static func loadoutHotkeys(in config: Config) -> [String: HotKey] {
        ExperimentalLoadouts.offered(in: config).reduce(into: [:]) { out, l in if let hk = l.hotkey { out[l.name] = hk } }
    }

    // MARK: Status menu

    /// The status menu's **Loadouts** submenu. A loadout owns its layout, so everything
    /// starts from a loadout: apply it, preview it, edit its layout; then capture a new one,
    /// save the HUD, draw a layout from scratch, pick the snap layout, undo a clear. Built each
    /// time the menu opens, so it follows the multi-desktop setting.
    func menuItems() -> [NSMenuItem] {
        let parent = NSMenuItem(title: "Loadouts", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in loadoutItems() { menu.addItem(item) }
        parent.submenu = menu
        return [parent]
    }

    /// The capture item's title while multi-desktop loadouts are off; the settings tab's
    /// capture button reads the same.
    static let captureThisScreenTitle = "Capture This Screen as Loadout…"

    /// The dimmed line saying how many loadouts are hidden because multi-desktop loadouts are
    /// off; nil when none are.
    nonisolated static func heldBackLine(_ count: Int) -> String? {
        count > 0 ? "\(count) multi-desktop loadout\(count == 1 ? "" : "s") hidden (experimental)" : nil
    }

    private func loadoutItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let config = store.config
        let loadouts = offered
        let heldBack = ExperimentalLoadouts.heldBack(in: config)
        if loadouts.isEmpty && heldBack == 0 {
            let then = config.multiDesktopLoadouts ? "Capture Windows…" : "Capture This Screen…"
            let empty = NSMenuItem(title: "No loadouts yet: arrange windows, then \(then)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        for loadout in loadouts {
            let title = loadout.hotkey.map { "\(loadout.name)  \($0.display)" } ?? loadout.name
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.state = engine.activeLoadout == loadout.name ? .on : .off
            let sub = NSMenu()
            sub.addItem(action("Preview…", loadout.name, #selector(previewItem(_:))))
            sub.addItem(action("Apply", loadout.name, #selector(loadItem(_:))))
            sub.addItem(action("Clear This Screen + Apply", loadout.name, #selector(clearLoadItem(_:))))
            sub.addItem(.separator())
            sub.addItem(action("Edit Layout…", loadout.name, #selector(editItem(_:))))
            sub.addItem(.separator())
            let regions = "\(loadout.slots.count) region\(loadout.slots.count == 1 ? "" : "s")"
            let hudApps = loadout.hud?.apps?.count ?? 0
            let info = NSMenuItem(title: loadout.layout.isEmpty && loadout.allSlots.isEmpty
                                    ? "HUD · \(hudApps) app\(hudApps == 1 ? "" : "s")"
                                    : "\(loadout.layout) · \(regions)" + (loadout.hud == nil ? "" : " + HUD"),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            sub.addItem(.separator())
            let startup = action("Apply at Startup", loadout.name, #selector(startupItem(_:)))
            startup.state = store.config.startupLoadout == loadout.name ? .on : .off
            sub.addItem(startup)
            sub.addItem(action("Delete…", loadout.name, #selector(deleteItem(_:))))
            item.submenu = sub
            items.append(item)
        }
        if let line = Self.heldBackLine(heldBack) {
            let hidden = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            hidden.isEnabled = false
            hidden.toolTip = ExperimentalLoadouts.howToTurnOn
            items.append(hidden)
        }

        items.append(.separator())
        items.append(action(config.multiDesktopLoadouts ? "Capture Windows as Loadout…" : Self.captureThisScreenTitle,
                            "", #selector(captureItem)))
        items.append(action("Save Dock and Panels as HUD Loadout…", "", #selector(saveHUDItem)))
        items.append(action("Draw a New Layout…", "", #selector(newLayoutItem)))
        items.append(.separator())
        items.append(snapLayoutItem())
        let restore = action("Restore Cleared Windows", "", #selector(restoreItem))
        restore.isEnabled = engine.hasClearedWindows
        items.append(restore)
        return items
    }

    /// Which layout ⇧-drag snaps to: loadouts point at layouts, and the active one is what
    /// snapping and the editor use.
    private func snapLayoutItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Snap Layout", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if store.layouts.isEmpty {
            let none = NSMenuItem(title: "No layouts yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for (i, layout) in store.layouts.enumerated() where layout.hidden != true {
            let mi = NSMenuItem(title: layout.name, action: #selector(selectLayoutItem(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = store.activeLayout == layout ? .on : .off
            sub.addItem(mi)
        }
        sub.addItem(.separator())
        sub.addItem(action("Edit Snap Layout…", "", #selector(editSnapLayoutItem)))
        item.submenu = sub
        return item
    }

    @objc private func newLayoutItem() { openNewLayout?() }
    @objc private func editSnapLayoutItem() { openEditor?() }
    @objc private func selectLayoutItem(_ sender: NSMenuItem) { store.select(index: sender.tag) }
    @objc private func restoreItem() {
        let count = engine.restore()
        Toast.show(count == 0 ? "Nothing to restore" : "Restored \(count) window\(count == 1 ? "" : "s")", seconds: 2)
    }

    private func action(_ title: String, _ name: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = name
        return item
    }

    private func loadout(from sender: NSMenuItem) -> Loadout? {
        guard let name = sender.representedObject as? String else { return nil }
        return store.loadout(named: name)
    }

    @objc private func loadItem(_ sender: NSMenuItem) {
        guard let l = loadout(from: sender) else { return }
        apply(l, clear: false)
    }

    @objc private func clearLoadItem(_ sender: NSMenuItem) {
        guard let l = loadout(from: sender) else { return }
        apply(l, clear: true)
    }

    @objc private func previewItem(_ sender: NSMenuItem) {
        guard let l = loadout(from: sender) else { return }
        preview(l)
    }

    @objc private func editItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if let editLoadout { editLoadout(name) } else { openEditor?() }
    }

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        confirmDelete(name)
    }

    /// Asks first, naming the layouts that go with it, then deletes through the library.
    func confirmDelete(_ name: String) {
        // The alert runs a modal: let the menu finish closing first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let question = LoadoutLibrary.deleteQuestion(name, ownedLayouts: self.store.config.ownedLayouts(of: name))
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.detail ?? "It can’t be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { try self.library?.perform(.delete(name)) } catch {
                Toast.show("Could not delete \(name)", detail: "\(error)", seconds: 3)
            }
        }
    }

    @objc private func captureItem() { captureCurrent() }

    @objc private func saveHUDItem() { saveCurrentHUD() }

    @objc private func startupItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = try? library?.perform(.startup(store.config.startupLoadout == name ? nil : name))
    }

    /// Asks for a name (and whether to put it back at startup), then saves the tool dock
    /// and every running sibling's panels into that loadout. A loadout hidden while
    /// multi-desktop loadouts are off is neither suggested nor written.
    func saveCurrentHUD() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Save the current HUD as a loadout"
            alert.informativeText = "The tool dock's position and each running MacHUD app's panels: shown or hidden, mode, frame, and where its own dock sits."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
            let config = self.store.config
            field.stringValue = config.startupLoadout.flatMap { ExperimentalLoadouts.refusal(forName: $0, in: config) == nil ? $0 : nil } ?? "My HUD"
            let box = NSButton(checkboxWithTitle: "Put it back when MacHUD starts", target: nil, action: nil)
            box.state = .on
            let stack = NSStackView(views: [field, box])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = CGRect(x: 0, y: 0, width: 300, height: 56)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            if let reason = ExperimentalLoadouts.refusal(forName: name, in: self.store.config) {
                NSLog("MacHUD: refused to save the HUD into hidden loadout '%@'", name)
                self.showRefusal("Could not save the HUD as \(name): a hidden loadout has that name", reason)
                return
            }
            let atStartup = box.state == .on
            self.engine.captureHUD(into: name) { [weak self] loadout in
                guard let self, let loadout else {
                    Toast.show("Could not save the HUD", seconds: 3)
                    return
                }
                if atStartup {
                    var c = self.store.config
                    c.startupLoadout = name
                    self.store.save(c)
                }
                let apps = loadout.hud?.apps?.count ?? 0
                Toast.show("Saved \(name)", detail: "Tool dock + \(apps) app\(apps == 1 ? "" : "s")"
                           + (atStartup ? " · restored at startup" : ""), seconds: 3)
            }
        }
    }

    // MARK: Control

    func registerControl(_ control: ControlServer) {
        control.register("menu") { [weak self] _, done in
            guard let self else { done(["ok": false, "error": "gone"]); return }
            var response: [String: Any] = ["ok": true]
            if self.radial.isVisible {
                response.merge(self.radial.json) { a, _ in a }
            } else {
                let wedges = self.wedges()
                response.merge(RadialMenu.json(wedges: wedges, layout: RadialLayout(wedges: wedges))) { a, _ in a }
                response["visible"] = false
            }
            if let last = self.lastApply { response["lastApply"] = last }
            done(response)
        }
        control.register("preview") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "gone"]); return }
            switch args["action"] ?? "show" {
            case "show":
                guard let name = args["loadout"] ?? self.defaultLoadoutName, let loadout = self.store.loadout(named: name) else {
                    done(["ok": false, "error": "no such loadout"]); return
                }
                if let reason = ExperimentalLoadouts.refusal(for: loadout, in: self.store.config) {
                    done(["ok": false, "error": reason]); return
                }
                self.preview(loadout)
            case "hide", "cancel":
                LoadoutPreview.shared.cancel()
            case "apply":
                LoadoutPreview.shared.apply()
            case let other:
                done(["ok": false, "error": "unknown action \(other)"]); return
            }
            done(["ok": true, "visible": LoadoutPreview.shared.isVisible,
                  "loadout": LoadoutPreview.shared.loadoutName ?? ""])
        }
        control.register("radial") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "gone"]); return }
            switch args["action"] ?? "show" {
            case "show":
                let point: CGPoint?
                if let x = args["x"].flatMap(Double.init), let y = args["y"].flatMap(Double.init) {
                    point = CGPoint(x: x, y: y)
                } else {
                    point = nil
                }
                self.showRadial(at: point)
            case "hide":
                self.radial.hide()
            case "cancel":
                self.radial.cancel()
            case "select":
                guard let index = args["index"].flatMap(Int.init) else {
                    done(["ok": false, "error": "index required"]); return
                }
                let ring: RadialGeometry.Ring? = args["ring"].flatMap { RadialGeometry.Ring(rawValue: $0.lowercased()) }
                self.radial.select(index: index, ring: ring)
            case "commit", "release":
                self.radial.commit()
            case let other:
                done(["ok": false, "error": "unknown action \(other)"]); return
            }
            var response: [String: Any] = ["ok": true]
            response.merge(self.radial.json) { a, _ in a }
            if let last = self.lastApply { response["lastApply"] = last }
            done(response)
        }
    }
}

/// Keeps the layout name field following the loadout name until the user edits it, and
/// enables it only while the "keep the layout" box is on.
@MainActor
final class FieldSync: NSObject, NSTextFieldDelegate {
    private let from: NSTextField
    private let to: NSTextField
    private var edited = false

    init(from: NSTextField, to: NSTextField) {
        self.from = from
        self.to = to
        super.init()
        from.delegate = self
        to.delegate = self
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field === to { edited = true }
        if field === from, !edited { to.stringValue = from.stringValue }
    }

    @objc func toggled(_ sender: NSButton) { to.isEnabled = sender.state == .on }
}
