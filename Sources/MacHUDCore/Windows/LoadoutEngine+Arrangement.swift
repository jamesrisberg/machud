import AppKit

extension LoadoutEngine {
    /// One display (and desktop) worth of a captured arrangement.
    struct ScreenCapture {
        var ref: ScreenRef
        var screenName: String
        var space: Int?
        var layout: Layout
        var slots: [Slot]

        var json: [String: Any] {
            var d: [String: Any] = ["screen": screenName, "layout": layout.name,
                                    "regions": layout.regions.count, "slots": slots.count]
            if let space { d["space"] = space }
            return d
        }
    }

    struct ArrangementCapture {
        var name: String
        var screens: [ScreenCapture]
        var hotkey: HotKey?

        var layouts: [Layout] { screens.map(\.layout) }
        var regionCount: Int { screens.reduce(0) { $0 + $1.layout.regions.count } }
        var slotCount: Int { screens.reduce(0) { $0 + $1.slots.count } }

        /// One display on whatever desktop it is showing stays the one-screen
        /// form, so a plain capture reads exactly as it always did.
        var loadout: Loadout {
            var loadout = Loadout(name: name, layout: screens.first?.layout.name ?? name, slots: [], hotkey: hotkey)
            if screens.count == 1, screens[0].space == nil {
                loadout.slots = screens[0].slots
            } else {
                loadout.screens = screens.map {
                    ScreenAssignment(screen: $0.ref, layout: $0.layout.name, slots: $0.slots, space: $0.space)
                }
            }
            return loadout
        }

        var json: [String: Any] {
            var d: [String: Any] = ["layout": screens.first?.layout.name ?? name,
                                    "regions": regionCount, "slots": slotCount,
                                    "screen": screens.first?.screenName ?? "",
                                    "screens": screens.map(\.json)]
            if let data = try? JSONEncoder().encode(loadout),
               let obj = try? JSONSerialization.jsonObject(with: data) { d["loadout"] = obj }
            return d
        }
    }

    /// The windows read on one display while one desktop was showing.
    struct CapturePass {
        var screen: NSScreen
        var space: Int?
        var windows: [WindowInfo]
    }

    /// Capture the windows on `screen` as a layout named `name` (one region per
    /// window, snapped to the grid) and a loadout of the same name that fills it.
    /// Regions of an existing layout with that name are reused where they still
    /// match, so tweaks made in the editor survive a recapture. Returns nil when
    /// no user window is on that screen.
    func captureArrangement(name: String, screen: NSScreen? = nil) -> ArrangementCapture? {
        guard let target = self.screen(screen) else { return nil }
        return build(name: name, layoutName: name, passes: [read(screen: target, space: nil)])
    }

    /// Capture several displays at once, optionally walking desktops on each:
    /// every (display, desktop) pass becomes its own layout and assignment, and
    /// the desktops that were showing before are restored at the end.
    func captureArrangement(name: String, layoutName: String? = nil, screens targets: [NSScreen], walk: DesktopWalk?,
                            completion: @escaping (ArrangementCapture?) -> Void) {
        let layoutName = layoutName ?? name
        let descriptors = NSScreen.screens.map(\.descriptor)
        var queue: [(screen: NSScreen, space: Int?)] = []
        for target in targets {
            let index = NSScreen.screens.firstIndex(of: target) ?? 0
            let count = Spaces.monitor(for: target)?.count ?? 1
            let wanted = (walk?.desktops(for: descriptors, index: index) ?? []).filter { $0 <= count }
            if wanted.isEmpty {
                queue.append((target, nil))
            } else {
                for desktop in wanted { queue.append((target, desktop)) }
            }
        }

        var passes: [CapturePass] = []
        var origins: [(screen: NSScreen, index: Int)] = []
        var index = 0

        func restore() {
            guard let origin = origins.popLast() else {
                completion(build(name: name, layoutName: layoutName, passes: passes))
                return
            }
            Spaces.switchTo(origin.index, on: origin.screen) { _ in restore() }
        }

        func step() {
            guard index < queue.count else { restore(); return }
            let item = queue[index]
            index += 1
            func read() {
                passes.append(self.read(screen: item.screen, space: item.space))
                step()
            }
            guard let space = item.space, let monitor = Spaces.monitor(for: item.screen) else { read(); return }
            guard monitor.currentIndex != space else { read(); return }
            if let current = monitor.currentIndex, !origins.contains(where: { $0.screen == item.screen }) {
                origins.append((item.screen, current))
            }
            Spaces.switchTo(space, on: item.screen) { result in
                switch result {
                case .success:
                    read()
                case .failure(let error):
                    NSLog("MacHUD: capture skipped desktop %d on %@: %@", space, item.screen.localizedName, error.reason)
                    step()
                }
            }
        }
        step()
    }

    /// The user windows on a display right now.
    func read(screen: NSScreen, space: Int?) -> CapturePass {
        let wins = windows().filter {
            screen.frame.intersects($0.frame) && $0.frame.width > 40 && $0.frame.height > 40
        }
        return CapturePass(screen: screen, space: space, windows: wins)
    }

    /// Turn the passes into one layout each plus the loadout that fills them. A
    /// window seen on several passes (an "all desktops" app, or one straddling
    /// two displays) belongs to the first pass that saw it. Layouts are named from
    /// `layoutName` (per display and desktop when there are several passes). Windows
    /// MacHUD has parked are captured at their rest frame as parked slots.
    func build(name: String, layoutName base: String, passes: [CapturePass]) -> ArrangementCapture? {
        let parkedRecords = parking.parked.map(\.record).filter { $0.kind == .ax }
        let parkedNumbers = Set(parkedRecords.compactMap(\.windowNumber))
        let lists = Arrangement.firstSeen(passes.map { $0.windows.filter { !parkedNumbers.contains($0.windowNumber) } }) { $0.windowNumber }
        let qualify = passes.count > 1
        let tabs = BrowserTabs()
        var screens: [ScreenCapture] = []
        for (index, pass) in passes.enumerated() {
            var wins = lists[index]
            // Parked windows belong to the desktop that is showing on their display.
            var parkedByIndex: [Int: ParkedRecord] = [:]
            if pass.space == nil || pass.space == Spaces.monitor(for: pass.screen)?.currentIndex {
                for (i, record) in parkedRecords.enumerated() where pass.screen.frame.intersects(record.rest) {
                    let app = record.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                    parkedByIndex[wins.count] = record
                    wins.append(WindowInfo(windowNumber: record.windowNumber ?? -(i + 1), pid: record.pid ?? 0,
                                           bundleID: record.bundleID ?? app?.bundleIdentifier,
                                           appName: app?.localizedName ?? record.label, title: record.title ?? "",
                                           frame: record.rest, owned: nil))
                }
            }
            guard !wins.isEmpty else { continue }
            let layoutName = Arrangement.layoutName(base, screen: qualify ? pass.screen.localizedName : nil,
                                                    desktop: pass.space)
            let existing = store.layout(named: layoutName)?.regions ?? []
            let placed = Arrangement.regions(
                for: wins.map { Arrangement.Input(frame: $0.frame, name: $0.appName) },
                visible: pass.screen.visibleFrame, gap: store.gap, grid: store.grid, existing: existing)

            var windowsPerApp: [String: Int] = [:]
            for w in wins { if let id = w.bundleID { windowsPerApp[id, default: 0] += 1 } }

            // `wins` is in window-server order, front to back.
            let zs = ZOrder.captured(frontToBack: wins.map(\.frame))
            var regions: [Region] = []
            var slots: [Slot] = []
            for p in placed {
                let window = wins[p.inputIndex]
                guard let occupant = WindowMatch.captureOccupant(
                        captureInput(for: window, windowsPerApp: windowsPerApp, tabs: tabs)),
                      let id = p.region.id else { continue }
                regions.append(p.region)
                var slot = Slot(regionID: id, occupant: occupant)
                if zs[p.inputIndex] != 0 { slot.z = zs[p.inputIndex] }
                if let record = parkedByIndex[p.inputIndex] {
                    slot.mode = .parked
                    slot.edge = record.edge
                    if record.peek > 0 { slot.peek = record.peek }
                }
                slots.append(slot)
            }
            guard !regions.isEmpty else { continue }
            screens.append(ScreenCapture(ref: pass.screen.ref, screenName: pass.screen.localizedName,
                                         space: pass.space, layout: Layout(name: layoutName, regions: regions),
                                         slots: slots))
        }
        guard !screens.isEmpty else { return nil }
        return ArrangementCapture(name: name, screens: screens, hotkey: store.loadout(named: name)?.hotkey)
    }

    /// Persist a capture: replace or add every layout, upsert the loadout, make
    /// the first layout active so snapping and `status` use it. `hideLayouts` keeps the
    /// layouts for this loadout only (not offered for ⇧-drag or in the menus).
    func commit(_ capture: ArrangementCapture, hideLayouts: Bool = false) {
        var c = store.config
        for var layout in capture.layouts {
            layout.hidden = hideLayouts ? true : nil
            if let i = c.layouts.firstIndex(where: { $0.name == layout.name }) {
                c.layouts[i] = layout
            } else {
                c.layouts.append(layout)
            }
        }
        var loadouts = c.loadouts ?? []
        var loadout = capture.loadout
        // Re-capturing the windows keeps the HUD part.
        loadout.hud = loadouts.first { $0.name == loadout.name }?.hud
        if let i = loadouts.firstIndex(where: { $0.name == loadout.name }) {
            loadouts[i] = loadout
        } else {
            loadouts.append(loadout)
        }
        c.loadouts = loadouts
        store.save(c)
        if !hideLayouts, let first = capture.layouts.first,
           let i = store.layouts.firstIndex(where: { $0.name == first.name }) { store.select(index: i) }
    }

    /// Displays that have at least one user window on them right now.
    func screensWithWindows() -> [NSScreen] {
        let wins = windows().filter { $0.frame.width > 40 && $0.frame.height > 40 }
        return NSScreen.screens.filter { screen in wins.contains { screen.frame.intersects($0.frame) } }
    }
}
