import AppKit

/// Wires loadouts into the UI: the hold-to-show radial wheel, the status-bar
/// section, per-loadout hotkeys and the `radial` / `menu` control commands.
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

    private init(store: LayoutStore, engine: LoadoutEngine) {
        self.store = store
        self.engine = engine
        radial.onCommit = { [weak self] outcome in self?.handle(outcome) }
        radial.onDismiss = { [weak self] in
            guard let self, self.registrationDeferred else { return }
            self.registrationDeferred = false
            self.registerHotkeys()
        }
    }

    // MARK: Wedges

    func wedges() -> [RadialMenu.Wedge] {
        let loadouts = store.loadouts
        let capture = RadialMenu.Wedge(
            title: "Capture…",
            icons: [NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)].compactMap { $0 },
            kind: .capture)
        let parked = engine.parking.parked.count
        var parkSubtitle = engine.focusedWindowLabel() ?? "nothing in front to park"
        if parked > 0 { parkSubtitle += " · \(parked) parked" }
        let park = RadialMenu.Wedge(
            title: "Park", subtitle: parkSubtitle,
            icons: [NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)]
                .compactMap { $0 },
            kind: .park)
        return loadouts.map {
            let n = $0.allSlots.count
            var subtitle = "\(n) window\(n == 1 ? "" : "s")"
            let desktops = Set($0.allSlots.compactMap(\.space)).count
            if desktops > 1 { subtitle += " · \(desktops) desktops" }
            if $0.hud != nil { subtitle += " · HUD" }
            return RadialMenu.Wedge(title: $0.name, subtitle: subtitle,
                                    icons: RadialMenu.icons(for: $0, panels: engine.panels),
                                    kind: .loadout($0.name), hotkey: $0.hotkey)
        } + [capture, park]
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
            guard let name = name ?? engine.activeLoadout ?? store.loadouts.first?.name,
                  let loadout = store.loadout(named: name) else { return }
            // Out of the hotkey callback first, like capture.
            DispatchQueue.main.async { self.preview(loadout) }
        }
    }

    // MARK: Actions

    /// Draw what applying `loadout` would do on every display; Apply runs it.
    func preview(_ loadout: Loadout) {
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

    /// The prompt runs a modal, so never start it from inside the Carbon hotkey
    /// callback that dismissed the wheel: give the run loop a turn first.
    /// `allScreens` nil = decide from how many displays have windows (menu bar);
    /// the wheel passes the ring choice explicitly.
    func captureCurrent(allScreens: Bool? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation)
            let busy = self.engine.screensWithWindows()
            let everywhere = allScreens ?? (busy.count > 1)
            let targets = everywhere ? NSScreen.screens : [screen ?? NSScreen.main].compactMap { $0 }
            let counts = NSScreen.screens.map { Spaces.monitor(for: $0)?.count ?? 1 }
            let desktops = targets.compactMap { NSScreen.screens.firstIndex(of: $0) }.map { counts[$0] }.max() ?? 1
            let place = everywhere ? "all \(targets.count) displays" : (screen?.localizedName ?? "this screen")
            guard let answer = self.prompt(title: "Capture the windows on \(place) as a loadout",
                                           value: self.suggestedName(),
                                           desktops: desktops > 1 ? desktops : nil),
                  !answer.name.isEmpty else {
                NSLog("MacHUD: capture cancelled")
                return
            }
            let name = answer.name
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
                    if let apps = hud?.apps?.count { detail += "\nTool dock + \(apps) app\(apps == 1 ? "" : "s") saved with it" }
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

    /// Name field, plus a "walk the desktops" checkbox when the displays being
    /// captured have more than one desktop between them.
    struct CaptureAnswer {
        var name: String
        /// nil: the layout is kept for the loadout only, not offered for ⇧-drag or other loadouts.
        var layoutName: String?
        var walkDesktops: Bool
        /// Save the tool dock and the siblings' panels into the same loadout.
        var includeHUD: Bool
    }

    /// The capture sheet: the loadout's name; whether its layout is also kept as one to snap
    /// into and to build other loadouts on, and under what name; whether the HUD (tool dock
    /// and panels) is saved with it; and, when the displays have more than one desktop,
    /// whether to walk them.
    private func prompt(title: String, value: String, desktops: Int?) -> CaptureAnswer? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The windows become a layout (one region each) and a loadout that fills it."
        alert.addButton(withTitle: "Capture")
        alert.addButton(withTitle: "Cancel")
        let width: CGFloat = 340
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = value
        field.placeholderString = "Loadout name"
        let keepLayout = NSButton(checkboxWithTitle: "Also keep the layout on its own, for ⇧-drag and other loadouts", target: nil, action: nil)
        keepLayout.state = .on
        let layoutField = NSTextField(frame: CGRect(x: 0, y: 0, width: width, height: 24))
        layoutField.stringValue = value
        layoutField.placeholderString = "Layout name"
        let sync = FieldSync(from: field, to: layoutField)
        keepLayout.target = sync
        keepLayout.action = #selector(FieldSync.toggled(_:))
        let hud = NSButton(checkboxWithTitle: "Include the tool dock and the apps' panels (the HUD)", target: nil, action: nil)
        hud.state = .on
        var views: [NSView] = [field, keepLayout, layoutField, hud]
        var walk: NSButton?
        if let desktops {
            let box = NSButton(checkboxWithTitle: "Also walk desktops 1…\(desktops)", target: nil, action: nil)
            box.state = .off
            walk = box
            views.append(box)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(views.count) * 30)
        for v in views { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        withExtendedLifetime(sync) {}
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let layoutName = layoutField.stringValue.trimmingCharacters(in: .whitespaces)
        return CaptureAnswer(name: name,
                             layoutName: keepLayout.state == .on ? (layoutName.isEmpty ? name : layoutName) : nil,
                             walkDesktops: walk?.state == .on, includeHUD: hud.state == .on)
    }

    // MARK: Hotkeys

    /// Carbon delivers the release event only to a still-registered hotkey, so
    /// re-register only when the keys actually changed, and never while the wheel
    /// is being held open.
    func registerHotkeys() {
        let menuKey = Env.noHotkeys ? nil : store.hotkeys.loadoutMenu
        let perLoadout: [String: HotKey] = Env.noHotkeys ? [:]
            : store.loadouts.reduce(into: [:]) { out, l in if let hk = l.hotkey { out[l.name] = hk } }
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

    // MARK: Status menu

    /// The status menu's **Loadouts** submenu. A loadout owns its layout, so everything
    /// starts from a loadout: apply it, preview it, edit its layout; then capture a new one,
    /// save the HUD, draw a layout from scratch, pick the snap layout, undo a clear.
    func menuItems() -> [NSMenuItem] {
        let parent = NSMenuItem(title: "Loadouts", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in loadoutItems() { menu.addItem(item) }
        parent.submenu = menu
        return [parent]
    }

    private func loadoutItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if store.loadouts.isEmpty {
            let empty = NSMenuItem(title: "No loadouts yet: arrange windows, then Capture Windows…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            items.append(empty)
        }
        for loadout in store.loadouts {
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

        items.append(.separator())
        items.append(action("Capture Windows as Loadout…", "", #selector(captureItem)))
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
    /// and every running sibling's panels into that loadout.
    func saveCurrentHUD() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Save the current HUD as a loadout"
            alert.informativeText = "The tool dock's position and each running MacHUD app's panels: shown or hidden, mode, frame, and where its own dock sits."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = self.store.config.startupLoadout ?? "My HUD"
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
                response.merge(RadialMenu.json(wedges: wedges, geometry: RadialGeometry(count: wedges.count, ringCounts: wedges.map { RadialMenu.ringCount(for: $0.kind) }))) { a, _ in a }
                response["visible"] = false
            }
            if let last = self.lastApply { response["lastApply"] = last }
            done(response)
        }
        control.register("preview") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "gone"]); return }
            switch args["action"] ?? "show" {
            case "show":
                guard let name = args["loadout"] ?? self.engine.activeLoadout ?? self.store.loadouts.first?.name,
                      let loadout = self.store.loadout(named: name) else {
                    done(["ok": false, "error": "no such loadout"]); return
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
