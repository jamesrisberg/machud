import AppKit
import HUDKit

/// Applies loadouts: finds or launches each occupant's window and places it in
/// its region; optionally clears everything else first. Also captures the
/// current arrangement into a loadout and reports what currently sits where.
@MainActor
final class LoadoutEngine {
    /// What became of a per-display assignment whose display is not attached.
    struct Redirect {
        /// Index into the loadout's `screens`.
        var assignment: Int
        /// The display the assignment asks for.
        var screen: String
        /// The display it was sent to instead, and the desktop there.
        var toScreen: String?
        var toSpace: Int?
        /// "redirected", "screenMissing" or "needsDesktops".
        var reason: String
        var needsDesktops: Int?

        var json: [String: Any] {
            var d: [String: Any] = ["screen": screen, "reason": reason]
            if let toScreen { d["toScreen"] = toScreen }
            if let toSpace { d["toSpace"] = toSpace }
            if let needsDesktops { d["needsDesktops"] = needsDesktops }
            return d
        }

        /// One line for the apply toast.
        var summary: String {
            switch reason {
            case "redirected":
                return "\(screen) → \(toScreen ?? "?") desktop \(toSpace ?? 1)"
            case "needsDesktops":
                return "\(screen) is missing: add \(needsDesktops ?? 1) desktops on "
                    + "\(toScreen ?? "the main display") in Mission Control, or set a fallback"
            default:
                return "\(screen) is missing: skipped"
            }
        }
    }

    struct ApplyReport {
        var loadout: String
        var placed: [String] = []            // region ids placed
        var failed: [String: String] = [:]   // region id -> reason
        var cleared: Int = 0                 // windows minimized/closed by clear
        /// Assignments whose display was missing, and where they went instead.
        var redirected: [Redirect] = []
        /// What the planner decided for each slot, in apply order (see `PlacementPlan`).
        var steps: [PlacementPlan.Step] = []
        /// Where placed windows really ended up, by region id, when that is not their region
        /// (the app kept a minimum or maximum size).
        var actual: [String: CGRect] = [:]
        /// What became of the loadout's `hud` part, if it has one.
        var hud: HUDLoadoutEngine.Report?
        /// Why the loadout was not applied at all, nothing having moved: it spans desktops or
        /// displays while that is off (`ExperimentalLoadouts`), or another apply is still running.
        var refused: String?

        var json: [String: Any] {
            if let refused { return ["ok": false, "loadout": loadout, "error": refused] }
            let hudOK = hud?.apps.values.allSatisfy { $0 == "applied" } ?? true
            var d: [String: Any] = ["ok": failed.isEmpty && hudOK, "loadout": loadout, "placed": placed,
                                    "failed": failed, "cleared": cleared]
            if !redirected.isEmpty { d["redirected"] = redirected.map(\.json) }
            if !steps.isEmpty { d["slots"] = slotsJSON }
            if let hud { d["hud"] = hud.json }
            return d
        }
    }

    /// A window currently on screen, as seen from the window server.
    struct WindowInfo {
        var windowNumber: Int
        var pid: pid_t
        var bundleID: String?
        var appName: String
        var title: String
        var frame: CGRect        // Cocoa screen coordinates (bottom-left origin)
        /// Set when the window belongs to MacHUD or was opened by it.
        var owned: Owned?

        enum Owned: Equatable {
            case panel(id: String)
            case web(url: String)
            case browser(url: String, host: WebHost)
        }

        var json: [String: Any] {
            var d: [String: Any] = ["window": windowNumber, "pid": Int(pid), "bundleID": bundleID ?? "",
                                    "app": appName, "title": title,
                                    "x": Int(frame.minX), "y": Int(frame.minY),
                                    "w": Int(frame.width), "h": Int(frame.height)]
            switch owned {
            case .panel(let id): d["panel"] = id
            case .web(let url): d["web"] = url
            case .browser(let url, let host): d["browser"] = url; d["host"] = host.rawValue
            case nil: break
            }
            return d
        }
    }

    struct RegionStatus {
        var regionID: String
        var regionName: String
        var frame: CGRect
        var occupant: Occupant?        // from the loadout, if one is active
        var window: WindowInfo?        // best-matching window currently in the region
        var iou: Double = 0            // how well that window fills the region
        var screen: String?            // display the region rect was computed on
        var space: Int?                // desktop showing on that display, 1-based

        var json: [String: Any] {
            var d: [String: Any] = ["region": regionID, "name": regionName,
                                    "x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)]
            if let screen { d["screen"] = screen }
            if let space { d["space"] = space }
            if let occupant, let data = try? JSONEncoder().encode(occupant),
               let obj = try? JSONSerialization.jsonObject(with: data) { d["occupant"] = obj }
            if let window {
                d["window"] = window.json
                d["iou"] = (iou * 1000).rounded() / 1000
                d["fits"] = fits
            }
            return d
        }

        /// True when the window sits in the region to within a couple of points.
        var fits: Bool {
            guard let window else { return false }
            return Geometry.matches(window.frame, frame, tolerance: 2)
        }
    }

    let store: LayoutStore
    let panels: PanelRegistry
    /// Name of the most recently applied loadout.
    private(set) var activeLoadout: String?
    /// The loadout being applied now. One apply runs at a time: two would each record the desktop
    /// showing and switch back to it, and whichever finished last would win.
    private(set) var applying: String?
    /// Redirections the most recent apply made, so `status` can report them.
    var redirects: [Redirect] = []
    /// The loadout those redirections belong to.
    var redirectLoadout: String?

    /// Browser windows MacHUD opened, so `clear` and `capture` know them.
    let browsers = BrowserWindows()
    /// Builtin web windows MacHUD opened, by url.
    private var webPanels: [String: WebPanel] = [:]
    /// Parked windows and their orbs.
    let parking: ParkingController

    init(store: LayoutStore, panels: PanelRegistry) {
        self.store = store
        self.panels = panels
        parking = ParkingController(panels: panels, stateURL: ParkingStore.defaultURL)
        Self.wireCooperativeParking(parking, panels: panels)
    }

    /// A parked `panel` slot whose panel belongs to a listening HUDKit app parks over
    /// that app's socket; the orb reveals it with `panel mode full`.
    static func wireCooperativeParking(_ parking: ParkingController, panels: PanelRegistry) {
        parking.cooperativeResolver = { [weak panels] id in panels?.cooperativeParkingTarget(id) }
    }

    // MARK: - Geometry

    /// A region's rect on a screen, with the configured gap — the same maths the
    /// drag monitor snaps with.
    func regionRect(_ region: Region, on screen: NSScreen) -> CGRect {
        Self.regionRect(region, visible: screen.visibleFrame, gap: store.gap)
    }

    /// The same, for a display's visible frame given directly (the settings preview).
    nonisolated static func regionRect(_ region: Region, visible: CGRect, gap: CGFloat) -> CGRect {
        var r = region.frame.cocoaRect(in: visible.insetBy(dx: gap / 2, dy: gap / 2))
        r = r.insetBy(dx: gap / 2, dy: gap / 2)
        return r.integral
    }

    func screen(_ preferred: NSScreen?) -> NSScreen? {
        preferred ?? ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
    }

    // MARK: - Windows

    /// All on-screen, user-facing windows.
    func windows() -> [WindowInfo] {
        let ownPanels = ownPanelWindows()
        let entries = WindowList.onScreen()
        var titlesByPID: [pid_t: [(CGRect, String)]] = [:]
        var infos: [WindowInfo] = []
        for entry in entries {
            if entry.pid == getpid(), ownPanels[entry.number] == nil { continue }
            let app = NSRunningApplication(processIdentifier: entry.pid)
            var title = entry.title
            if title.isEmpty {
                // kCGWindowName needs screen-recording rights; accessibility gives us the title anyway.
                let known = titlesByPID[entry.pid] ?? AXWindow.all(pid: entry.pid).compactMap { w in
                    w.cocoaFrame.map { ($0, w.title) }
                }
                titlesByPID[entry.pid] = known
                title = known.first { Geometry.matches($0.0, entry.frame, tolerance: 3) }?.1 ?? ""
            }
            var info = WindowInfo(windowNumber: entry.number, pid: entry.pid,
                                  bundleID: app?.bundleIdentifier,
                                  appName: app?.localizedName ?? entry.owner,
                                  title: title, frame: entry.frame)
            if let panelID = ownPanels[entry.number] {
                info.owned = (panels.panel(id: panelID) as? WebPanel).map { .web(url: $0.url) } ?? .panel(id: panelID)
            } else if let opened = browsers.entry(number: entry.number) {
                info.owned = .browser(url: opened.url, host: opened.host)
            }
            infos.append(info)
        }
        return infos
    }

    private func ownPanelWindows() -> [Int: String] {
        var map: [Int: String] = [:]
        for panel in panels.panels {
            if let w = panel.window, w.isVisible { map[w.windowNumber] = panel.id }
        }
        return map
    }

    /// Follow a renamed or deleted loadout, which the engine remembers by name.
    func loadoutEdited(_ edit: LoadoutEdit, _ result: LoadoutEditResult) {
        switch edit {
        case .rename(let old, _):
            if activeLoadout == old { activeLoadout = result.loadout }
            if redirectLoadout == old { redirectLoadout = result.loadout }
        case .delete(let name):
            if activeLoadout == name { activeLoadout = nil }
            if redirectLoadout == name { redirectLoadout = nil; redirects = [] }
        case .duplicate, .startup:
            break
        }
    }

    // MARK: - Apply

    /// Apply `loadout` on `screen` (default: screen under the mouse).
    /// `clear`: minimize every other window (and close MacHUD-owned web windows) first.
    /// A loadout's `hud` part (tool dock and sibling panels) goes after its windows, so it
    /// has the last word on a sibling panel that is in both. Refused before anything moves
    /// (`ApplyReport.refused`): a loadout that spans desktops or displays while that is off, and
    /// any apply while another is still running (never queued).
    func apply(_ loadout: Loadout, clear: Bool, screen: NSScreen? = nil, completion: @escaping (ApplyReport) -> Void) {
        let refusal = ExperimentalLoadouts.refusal(for: loadout, in: store.config)
            ?? applying.map { "\($0) is still being applied" }
        if let refusal {
            NSLog("MacHUD: not applying '%@': %@", loadout.name, refusal)
            var report = ApplyReport(loadout: loadout.name)
            report.refused = refusal
            completion(report)
            return
        }
        applying = loadout.name
        activeLoadout = loadout.name
        let completion: (ApplyReport) -> Void = { [weak self] report in
            self?.applying = nil
            completion(report)
            self?.onApplied?(report)
        }
        if clear { minimizedByClear = [] }
        guard let hud = loadout.hud, let hudEngine else {
            applyAcrossScreens(loadout, clear: clear, screen: screen, completion: completion)
            return
        }
        // A sibling that never starts listening would hold its commands, and this apply (with
        // every later one), for good: the HUD part gets `hudTimeLimit`.
        let applyHUD: (ApplyReport) -> Void = { [hudTimeLimit] report in
            let finish = Once<HUDLoadoutEngine.Report> { hudReport in
                var report = report
                report.hud = hudReport
                completion(report)
            }
            hudEngine.apply(hud) { finish.give($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + hudTimeLimit) {
                MainActor.assumeIsolated {
                    var late = HUDLoadoutEngine.Report(dock: hud.dock?.position.rawValue)
                    for id in (hud.apps ?? [:]).keys { late.apps[id] = "no answer in time" }
                    finish.give(late)
                }
            }
        }
        if loadout.allSlots.isEmpty && !clear {
            applyHUD(ApplyReport(loadout: loadout.name))
        } else {
            applyAcrossScreens(loadout, clear: clear, screen: screen, completion: applyHUD)
        }
    }

    /// How long a group's slots may take to be placed once their windows are asked for.
    var placementTimeLimit: TimeInterval = 15
    /// How long the sibling apps of a loadout's HUD part may take to answer.
    var hudTimeLimit: TimeInterval = 30

    /// Passes on the first value only.
    @MainActor
    final class Once<Value> {
        private var body: ((Value) -> Void)?
        init(_ body: @escaping (Value) -> Void) { self.body = body }
        func give(_ value: Value) {
            guard let body else { return }
            self.body = nil
            body(value)
        }
    }

    /// Called after every apply finishes, however it was started (wheel, menu, socket,
    /// startup, a display change): the onboarding's radial practice waits for it.
    var onApplied: ((ApplyReport) -> Void)?

    /// Says what an automatic apply did: a toast, or a recorder in tests.
    var notify: (_ title: String, _ detail: String?, _ seconds: TimeInterval) -> Void = { title, detail, seconds in
        Toast.show(title, detail: detail, seconds: seconds)
    }

    /// An apply nobody asked for just now.
    enum AutomaticApply {
        /// `startupLoadout`, about two seconds after launch.
        case startup
        /// The active loadout again, after the set of displays changed.
        case displaysChanged
    }

    /// Apply `loadout` without `clear` because of `why`, and say so: a refused loadout (one that
    /// spans desktops or displays while that is off) in one toast, the engine having logged it.
    func applyAutomatically(_ loadout: Loadout, _ why: AutomaticApply) {
        if why == .startup { NSLog("MacHUD: applying startup loadout '%@'", loadout.name) }
        apply(loadout, clear: false) { [weak self] report in
            guard let self else { return }
            switch why {
            case .startup:
                if let refused = report.refused {
                    self.notify("Startup loadout not applied", refused, 8)
                } else {
                    NSLog("MacHUD: startup loadout '%@': %@", loadout.name, "\(report.json)")
                }
            case .displaysChanged:
                if let refused = report.refused {
                    self.notify("Displays changed", "Did not re-apply \(loadout.name). \(refused)", 8)
                } else {
                    NSLog("MacHUD: displays changed, re-applied %@: %d placed, %d failed",
                          loadout.name, report.placed.count, report.failed.count)
                    self.notify("Displays changed", "Re-applied \(loadout.name)", 2.5)
                }
            }
        }
    }

    /// The `apply` verb (see docs/API.md).
    func handleApply(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard let name = args["loadout"], let loadout = store.loadout(named: name) else {
            done(["ok": false, "error": "no such loadout"]); return
        }
        let yes = ["1", "true", "yes"]
        let ref = args["screen"].flatMap { ScreenRef.parse($0) }
        let screen = ref?.resolve()
        if let ref, screen == nil {
            done(["ok": false, "error": "no screen matching \(ref.label)"]); return
        }
        if yes.contains((args["plan"] ?? "0").lowercased()) {
            done(planJSON(loadout, screen: screen)); return
        }
        apply(loadout, clear: yes.contains((args["clear"] ?? "0").lowercased()), screen: screen) { report in done(report.json) }
    }

    /// Why `edit loadout=<name>` may not open the editor, as the verb's reply; nil when it may.
    func editRefusal(loadout name: String) -> [String: Any]? {
        guard let loadout = store.loadout(named: name) else { return ["ok": false, "error": "no such loadout"] }
        return ExperimentalLoadouts.refusal(for: loadout, in: store.config).map { ["ok": false, "error": $0] }
    }

    /// Captures and applies loadouts' `hud` part; set by the app once the tool dock exists.
    var hudEngine: HUDLoadoutEngine?

    /// Adds the current HUD (tool dock and siblings) to the loadout `name`, creating a
    /// HUD-only one (no layout, no slots) if there is none. Calls back with it once saved.
    func captureHUD(into name: String, completion: @escaping (Loadout?) -> Void) {
        guard let hudEngine else { completion(nil); return }
        hudEngine.capture { [weak self] hud in
            guard let self else { completion(nil); return }
            var loadout = self.store.loadout(named: name) ?? Loadout(name: name, layout: "", slots: [], hotkey: nil)
            loadout.hud = hud
            self.store.upsert(loadout)
            completion(loadout)
        }
    }

    final class SlotJob {
        let regionID: String
        let occupant: Occupant
        let rect: CGRect
        /// Desktop this slot wants, and that desktop's id on its display.
        var space: Int?
        var spaceID: UInt64?
        /// Set once the private API has been asked to drag the window over.
        var movedForSpace = false
        var launched = false
        var askedForWindow = false
        var activated = false
        /// Window-server numbers the browser owned before this slot asked for a window.
        var baseline: Set<Int> = []
        var done = false
        /// App that was frontmost before we had to activate one to reach its menus.
        var previousFront: NSRunningApplication?
        /// The slot this job places: stacking and parking come from it.
        var slot: Slot?
        /// The window once it has been placed, so it can be raised in stacking order.
        var placed: Placeable?
        /// What the planner decided for this slot.
        var step: PlacementPlan.Step?
        /// Window-server number of the window the plan chose; resolve uses it when it can.
        var preferredWindow: Int?
        /// Open a new window without activating the app, leaving the existing one where it is.
        var newWindowOnly = false
        /// When the new window was asked for.
        var askedAt: Date?
        /// Why the slot is still waiting, given at the deadline instead of "timed out".
        var stalled: String?
        /// When the app's menus were last walked for a New Window item.
        private var lastMenuWalk: Date?

        /// Whether the app's menus may be walked now: at most once a second, since a walk is many
        /// Accessibility calls and the slot is polled every 100 ms.
        func mayWalkMenu(at now: Date) -> Bool {
            if let last = lastMenuWalk, now.timeIntervalSince(last) < 1 { return false }
            lastMenuWalk = now
            return true
        }

        var z: Int { slot?.stackOrder ?? 0 }

        init(regionID: String, occupant: Occupant, rect: CGRect) {
            self.regionID = regionID
            self.occupant = occupant
            self.rect = rect
        }

        func restoreFocus() {
            guard let app = previousFront, !app.isTerminated else { return }
            previousFront = nil
            app.activate()
        }
    }

    @MainActor
    enum Placeable {
        case ax(AXWindow)
        case own(NSWindow)
        /// A cooperative app's panel: placed with `panel frame` over its socket.
        case external(ExternalPanel)

        func place(in rect: CGRect) {
            switch self {
            case .ax(let w):
                if w.isMinimized { w.isMinimized = false }
                // A hidden (⌘H) app's window shows again; unhiding does not bring the app forward.
                if let app = NSRunningApplication(processIdentifier: w.pid), app.isHidden { app.unhide() }
                w.setCocoaFrame(rect)
            case .own(let w):
                w.setFrame(rect, display: true)
            case .external(let panel):
                panel.place(in: rect)
            }
        }

        func raise() {
            switch self {
            case .ax(let w): w.raise()
            case .own(let w): w.orderFrontRegardless()
            case .external(let panel): panel.show()  // the app owns its window order; show brings it forward
            }
        }
    }

    enum Resolution {
        case ready(Placeable)
        case waiting
        case failed(String)
    }

    /// Poll every 100 ms so every slot makes progress at once: launches overlap and
    /// each window is placed on the main thread as soon as it shows up.
    func run(_ jobs: [SlotJob], report: ApplyReport, completion: @escaping (ApplyReport) -> Void) {
        var report = report
        let deadline = Date().addingTimeInterval(placementTimeLimit)

        func finish() {
            browsers.finishOpening()
            raiseInStackingOrder(jobs)
            verifyPlacement(jobs, report: report, completion: completion)
        }

        func step() {
            for job in jobs where !job.done {
                if let issue = spaceIssue(before: job) {
                    job.done = true
                    report.failed[job.regionID] = issue
                    continue
                }
                if let issue = applyMenuBar(job) {
                    job.done = true
                    if issue.isEmpty { report.placed.append(job.regionID) } else { report.failed[job.regionID] = issue }
                    continue
                }
                if applyToolDock(job) {
                    job.done = true
                    report.placed.append(job.regionID)
                    continue
                }
                if parkCooperatively(job) {
                    job.done = true
                    report.placed.append(job.regionID)
                    continue
                }
                switch resolve(job) {
                case .ready(let placeable):
                    job.done = true
                    job.restoreFocus()
                    if let issue = spaceIssue(placeable, job: job) {
                        report.failed[job.regionID] = issue
                        break
                    }
                    report.placed.append(job.regionID)
                    job.placed = placeable
                    parking.release(placeable)
                    placeable.place(in: job.rect)
                    // Some apps clamp position against their old size; do it once more.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MainActor.assumeIsolated {
                            placeable.place(in: job.rect)
                            if let slot = job.slot, slot.isParked { self.park(placeable, job: job, slot: slot) }
                        }
                    }
                case .failed(let reason):
                    job.done = true
                    job.restoreFocus()
                    report.failed[job.regionID] = reason
                case .waiting:
                    break
                }
            }
            if jobs.allSatisfy(\.done) { finish(); return }
            if Date() >= deadline {
                for job in jobs where !job.done {
                    job.restoreFocus()
                    report.giveUp(job.regionID, stalled: job.stalled)
                }
                finish()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { step() } }
        }
        step()
    }

    /// Raise the placed windows of a stacked group in ascending z, after the settle
    /// placement, so the highest z ends up in front. Unstacked groups are left alone.
    private func raiseInStackingOrder(_ jobs: [SlotJob]) {
        let stacked = jobs.filter { $0.placed != nil && $0.slot?.isParked != true }
        let zs = stacked.map(\.z)
        guard ZOrder.isStacked(zs) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                for i in ZOrder.raiseOrder(zs) { stacked[i].placed?.raise() }
            }
        }
    }

    private func park(_ placeable: Placeable, job: SlotJob, slot: Slot) {
        let target: ParkingController.Target
        switch placeable {
        case .ax(let w): target = .ax(w)
        case .own(let w): target = .own(w)
        case .external(let p): target = .cooperative(HUDSocketClient(path: p.app.socketPath), panelID: p.panelID)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(job.rect) }
        parking.park(target, id: job.regionID, label: job.occupant.label, rest: job.rect,
                     edge: slot.parkEdge, peek: slot.parkPeek, screen: screen)
    }

    /// A `menubar` panel slot has no window: a parked slot collapses the menu bar, any
    /// other expands it. nil when the slot is not the menu bar, "" when applied, else why not.
    private func applyMenuBar(_ job: SlotJob) -> String? {
        guard case .panel(let id) = job.occupant, let panel = panels.panel(id: id) as? MenuBarPanel else { return nil }
        do {
            try panel.setMode(job.slot?.isParked == true ? .compact : .full)
            return ""
        } catch {
            return "\(error)"
        }
    }

    /// A `tooldock` panel slot: the dock moves to the edge the region stands for, its
    /// centre along that edge at the region's. True when the slot was the tool dock.
    private func applyToolDock(_ job: SlotJob) -> Bool {
        guard case .panel(let id) = job.occupant, let dock = panels.panel(id: id) as? ToolDock else { return false }
        dock.place(inRegion: job.rect)
        return true
    }

    /// A parked `panel` slot whose panel belongs to a HUDKit app: the app parks
    /// itself when asked over its socket. True when the slot was handled that way.
    private func parkCooperatively(_ job: SlotJob) -> Bool {
        guard let slot = job.slot, slot.isParked, case .panel(let id) = job.occupant,
              let target = parking.cooperativeTarget(id) else { return false }
        let screen = NSScreen.screens.first { $0.frame.intersects(job.rect) }
        parking.park(target, id: job.regionID, label: panels.panel(id: id)?.title ?? id, rest: job.rect,
                     edge: slot.parkEdge, peek: slot.parkPeek, screen: screen)
        return true
    }

    private func resolve(_ job: SlotJob) -> Resolution {
        switch job.occupant {
        case .app(let bundleID, let titleMatch):
            return resolveApp(job, bundleID: bundleID, titleMatch: titleMatch)
        case .web(let url, .builtin):
            return resolveBuiltinWeb(url: url)
        case .web(let url, let host):
            return resolveWeb(job, url: url, host: host)
        case .panel(let id):
            // A web panel's id carries its url, so it can be placed by id alone.
            if id.hasPrefix("web:"), panels.panel(id: id) == nil {
                return resolveBuiltinWeb(url: String(id.dropFirst(4)))
            }
            guard let panel = panels.panel(id: id) else { return .failed("no panel \(id)") }
            if let external = panel as? ExternalPanel { return resolveExternal(job, external) }
            panel.show()
            guard let window = panel.window else { return .waiting }
            return .ready(.own(window))
        }
    }

    private func resolveApp(_ job: SlotJob, bundleID: String, titleMatch: String?) -> Resolution {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        if job.newWindowOnly { return resolveNewWindow(job, bundleID: bundleID, running: running) }
        if let chosen = preferredWindow(job, running: running) { return .ready(.ax(chosen)) }
        for app in running {
            let wins = AXWindow.all(pid: app.processIdentifier).filter { $0.exists }
            if let i = WindowMatch.choose(wins.map(\.candidate), titleMatch: titleMatch) {
                return .ready(.ax(wins[i]))
            }
        }
        if !job.launched {
            job.launched = true
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return .failed("\(bundleID) is not installed")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                if let error { NSLog("MacHUD: launch %@ failed: %@", bundleID, "\(error)") }
            }
            return .waiting
        }
        // Running but window-less: the launch above asked it to reopen, which shows a document
        // app's window (TextEdit); ask by its New Window item too, every poll. ⌘N is never
        // pressed (in Notes or Mail it makes a note or a message). See `windowlessMove` for
        // when it is unhidden or brought forward instead.
        if !job.askedForWindow, let app = running.first, job.mayWalkMenu(at: Date()) {
            let pid = app.processIdentifier
            if !app.isHidden {
                job.askedForWindow = NewWindowMenu.press(pid: pid)
                if job.askedForWindow { return .waiting }
            }
            let windows = app.isHidden || job.activated ? [] : AllSpacesWindows.list().filter { $0.pid == pid }
            switch Self.windowlessMove(label: job.occupant.label, hidden: app.isHidden, activated: job.activated,
                                       multiDesktop: store.config.multiDesktopLoadouts,
                                       windowsOnScreen: windows.map(\.onScreen)) {
            case .unhide:
                app.unhide()
            case .wait(let reason):
                if let reason { job.stalled = reason }
            case .activate:
                job.activated = true
                job.previousFront = NSWorkspace.shared.frontmostApplication
                // A freshly launched app can sit there with neither window nor menu
                // bar until something talks to it; an activate event wakes it up.
                AppleEvents.activate(pid: app.processIdentifier)
                app.activate()
            }
        }
        return .waiting
    }

    /// What to do next for a running app that showed no window to place and would not open one
    /// from its menu. A hidden (⌘H) app is unhidden: its windows are here, and unhiding does not
    /// bring it forward. Otherwise it is brought forward once, so its menus answer, except, with
    /// multi-desktop loadouts off, when all its windows are on desktops that are not showing:
    /// that would show one of them, so its menu is asked again each poll and the slot gives
    /// `wait`'s reason at the deadline.
    enum WindowlessMove: Equatable {
        case unhide
        case activate
        case wait(String?)
    }

    nonisolated static func windowlessMove(label: String, hidden: Bool, activated: Bool, multiDesktop: Bool,
                                           windowsOnScreen: [Bool]) -> WindowlessMove {
        if hidden { return .unhide }
        if activated { return .wait(nil) }
        if !multiDesktop, !windowsOnScreen.isEmpty, !windowsOnScreen.contains(true) {
            return .wait("\(label) has windows only on another desktop and would not open one here without coming forward")
        }
        return .activate
    }

    private func resolveBuiltinWeb(url: String) -> Resolution {
        let panel = webPanel(for: url)
        panel.show()
        guard let window = panel.window else { return .waiting }
        return .ready(.own(window))
    }

    private func webPanel(for url: String) -> WebPanel {
        if let existing = webPanels[url] { return existing }
        let panel = WebPanel(url: url)
        panel.onClose = { [weak self] in self?.webPanels[url] = nil }
        webPanels[url] = panel
        panels.register(panel)
        return panel
    }

    /// A web page in a browser window. Re-applying a loadout reuses the window MacHUD already
    /// opened for that url, unless the plan asked for a new one here and that window is on
    /// another desktop: a new one is opened then.
    private func resolveWeb(_ job: SlotJob, url: String, host: WebHost) -> Resolution {
        browsers.prune()
        let onScreen = job.newWindowOnly ? Set(WindowList.onScreen().map(\.number)) : []
        if let existing = browsers.reusable(url: url, newWindowOnly: job.newWindowOnly, onScreen: onScreen) {
            return .ready(.ax(existing.window))
        }
        if let reason = browsers.takeFailure(job.regionID) { return .failed(reason) }
        if let kind = BrowserWindow.Kind(host: host) { return resolveBrowserWindow(job, url: url, kind: kind) }
        // `.chromeApp` with Arc or Safari configured as the browser: they have no
        // app mode, so open an ordinary window in them instead.
        if let fallback = WebHost.chromeAppFallback(configuredBrowser: store.config.browser),
           let kind = BrowserWindow.Kind(host: fallback) {
            return resolveBrowserWindow(job, url: url, kind: kind)
        }
        guard let browser = ChromeApp.resolve(preferred: store.config.browser) else {
            return resolveBuiltinWeb(url: url)
        }
        if !job.launched {
            guard browsers.claimOpening(job.regionID, bundleID: browser.bundleID) else { return .waiting }
            job.baseline = NewWindow.baseline(bundleID: browser.bundleID)
            job.launched = true
            guard ChromeApp.open(url: url, browser: browser) else {
                browsers.finishOpening(bundleID: browser.bundleID)
                return .failed("could not run \(browser.bundleID)")
            }
            return .waiting
        }
        guard browsers.isOpening(job.regionID, bundleID: browser.bundleID) else { return .waiting }
        return adopt(job, url: url, host: .chromeApp, bundleID: browser.bundleID,
                     browserName: browser.bundleID)
    }

    /// Arc and Safari: launch if needed, then ask by Apple event for a window and
    /// find it by diffing the browser's window list.
    private func resolveBrowserWindow(_ job: SlotJob, url: String, kind: BrowserWindow.Kind) -> Resolution {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) else {
            return .failed("\(kind.scriptName) is not installed")
        }
        guard BrowserWindow.runningApps(kind).contains(where: \.isFinishedLaunching) else {
            if !job.launched {
                job.launched = true
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                    if let error { NSLog("MacHUD: launch %@ failed: %@", kind.bundleID, "\(error)") }
                }
            }
            return .waiting
        }
        guard browsers.claimOpening(job.regionID, bundleID: kind.bundleID) else { return .waiting }
        if !job.askedForWindow {
            job.baseline = NewWindow.baseline(bundleID: kind.bundleID)
            job.askedForWindow = true
            let regionID = job.regionID
            BrowserWindow.open(url: url, kind: kind) { [weak self] failure in
                guard let failure else { return }
                self?.browsers.fail(regionID, failure.reason)
            }
            return .waiting
        }
        return adopt(job, url: url, host: kind.host, bundleID: kind.bundleID, browserName: kind.scriptName)
    }

    /// The window the browser opened since this slot asked for one, once the browser
    /// has stopped moving it about.
    private func adopt(_ job: SlotJob, url: String, host: WebHost, bundleID: String,
                       browserName: String) -> Resolution {
        guard let new = NewWindow.since(job.baseline, bundleID: bundleID), let frame = new.window.cocoaFrame,
              browsers.hasSettled(job.regionID, frame: frame) else {
            // Hand the lock on rather than making every other web slot time out too.
            guard browsers.hasTimedOut(regionID: job.regionID, bundleID: bundleID) else { return .waiting }
            browsers.finishOpening(bundleID: bundleID)
            if NewWindow.isOnAnotherDesktop(job.baseline, bundleID: bundleID) {
                return .failed("\(browserName) opened \(url) on another desktop; it was left there")
            }
            return .failed("\(browserName) opened no window for \(url)")
        }
        browsers.add(url: url, host: host, window: new.window, number: new.number, bundleID: bundleID)
        browsers.finishOpening(bundleID: bundleID)
        return .ready(.ax(new.window))
    }

    // MARK: - Clear

    /// Minimize every user-facing window that is not about to be placed and is not
    /// MacHUD's own; close web windows MacHUD opened that this loadout does not
    /// want. Returns how many windows were minimized or closed.
    @discardableResult
    func clearAll() -> Int {
        minimizedByClear = []
        return clearOthers(keeping: [])
    }

    /// The same for the windows showing on the display with `frame` (what `apply … clear=1`
    /// clears for a screen).
    @discardableResult
    func clear(on frame: CGRect) -> Int {
        minimizedByClear = []
        return clearOthers(keeping: [], on: frame)
    }

    /// What a standalone `clear` covers.
    enum ClearScope: Equatable {
        /// Every window on every desktop (multi-desktop loadouts on, no screen named).
        case everyDesktop
        /// The windows showing on the display with this frame.
        case screen(CGRect)
        /// One screen was called for and there is none to name: nothing is cleared.
        case noScreen
    }

    /// Multi-desktop loadouts off, a loadout is one screen and so is a clear: the display under
    /// the pointer, on the desktop showing. On, it reaches every desktop. A screen the caller
    /// names (`screen=`) is the one cleared either way.
    nonisolated static func clearScope(multiDesktop: Bool, named: CGRect?, pointer: CGRect?) -> ClearScope {
        if let named { return .screen(named) }
        if multiDesktop { return .everyDesktop }
        return pointer.map(ClearScope.screen) ?? .noScreen
    }

    /// The `clear` verb (see docs/API.md).
    func handleClear(_ args: [String: String]) -> [String: Any] {
        var named: NSScreen?
        if let text = args["screen"] {
            let ref = ScreenRef.parse(text)
            guard let found = ref?.resolve() else {
                return ["ok": false, "error": "no screen matching \(ref?.label ?? text)"]
            }
            named = found
        }
        let pointer = screen(nil)
        switch Self.clearScope(multiDesktop: store.config.multiDesktopLoadouts, named: named?.frame, pointer: pointer?.frame) {
        case .everyDesktop:
            return ["ok": true, "cleared": clearAll()]
        case .screen(let frame):
            let target = named ?? pointer
            return ["ok": true, "screen": target?.localizedName ?? "", "cleared": clear(on: frame)]
        case .noScreen:
            return ["ok": false, "error": "no screen to clear"]
        }
    }

    /// Windows the most recent clear minimized, so `restore` can undo it.
    private(set) var minimizedByClear: [AXWindow] = []
    var hasClearedWindows: Bool { minimizedByClear.contains { $0.exists && $0.isMinimized } }

    /// Un-minimize everything the last clear minimized. Returns how many were restored.
    @discardableResult
    func restore() -> Int {
        var count = 0
        for window in minimizedByClear where window.exists && window.isMinimized {
            window.isMinimized = false
            count += 1
        }
        minimizedByClear = []
        return count
    }

    /// Called once per visited (screen, space) group during an apply, so it only
    /// appends to `minimizedByClear`; `apply`/`clearAll` reset it. With `screen` it clears
    /// only the windows showing on that display now (the apply has already switched to the
    /// group's desktop), so an apply clears the screens the loadout covers and nothing else;
    /// without it (`clearAll`, the standalone clear with multi-desktop loadouts on) it reaches
    /// every window on every desktop. MacHUD's own
    /// windows, the windows of MacHUD sibling apps (external panels) and hidden apps are
    /// left alone.
    func clearOthers(keeping jobs: [SlotJob], on screen: CGRect? = nil) -> Int {
        let exempt = clearExemptPIDs()
        let targets = AllSpacesWindows.clearTargets(
            AllSpacesWindows.list(), exempt: exempt,
            hidden: Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier)),
            on: screen)
        var axByPID: [pid_t: [(window: AXWindow, number: Int?)]] = [:]
        func axWindows(_ pid: pid_t) -> [(window: AXWindow, number: Int?)] {
            if let known = axByPID[pid] { return known }
            let found = AllSpacesWindows.axWindows(pid: pid, wanted: Set((targets[pid] ?? []).map(\.number)))
            axByPID[pid] = found
            return found
        }

        var keepURLs: Set<String> = []
        var keepAX: [AXWindow] = []
        for job in jobs {
            switch job.occupant {
            case .web(let url, _): keepURLs.insert(url)
            case .app(let bundleID, let titleMatch):
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    let wins = axWindows(app.processIdentifier).map(\.window).filter { $0.exists }
                    if let i = WindowMatch.choose(wins.map(\.candidate), titleMatch: titleMatch) { keepAX.append(wins[i]) }
                }
            case .panel: break
            }
        }

        var count = 0
        for (url, panel) in webPanels where !keepURLs.contains(url) {
            if panel.window != nil { count += 1 }
            panel.close()
            webPanels[url] = nil
        }
        count += browsers.close(keeping: keepURLs)
        keepAX.append(contentsOf: browsers.windows(keeping: keepURLs))
        let keepNumbers = Set(keepAX.compactMap(\.windowNumber))

        for (pid, entries) in targets {
            let numbers = Set(entries.map(\.number))
            for (window, number) in axWindows(pid) {
                guard !window.isMinimized, window.isPlaceable else { continue }
                if let number {
                    guard numbers.contains(number), !keepNumbers.contains(number) else { continue }
                } else {
                    // No window number (private call unavailable): match by frame, as before.
                    guard let frame = window.cocoaFrame,
                          entries.contains(where: { Geometry.matches($0.frame, frame, tolerance: 3) }) else { continue }
                }
                guard !keepAX.contains(where: { $0.isSame(as: window) }) else { continue }
                window.isMinimized = true
                minimizedByClear.append(window)
                count += 1
            }
        }
        return count
    }

    /// MacHUD itself and every running MacHUD sibling whose panels are registered.
    func clearExemptPIDs() -> Set<pid_t> {
        var pids: Set<pid_t> = [getpid()]
        for bundleID in panels.externalAppIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                pids.insert(app.processIdentifier)
            }
        }
        return pids
    }

    // MARK: - Capture

    /// Snapshot what is currently in each region of `layout` as a new loadout.
    func capture(name: String, layout: Layout, screen: NSScreen? = nil) -> Loadout {
        guard let target = self.screen(screen) else {
            return Loadout(name: name, layout: layout.name, slots: [], hotkey: nil)
        }
        let wins = windows()
        var windowsPerApp: [String: Int] = [:]
        for w in wins { if let id = w.bundleID { windowsPerApp[id, default: 0] += 1 } }

        let tabs = BrowserTabs()
        var slots: [Slot] = []
        var windowIndex: [Int] = []
        for region in layout.regions {
            guard let id = region.id else { continue }
            let rect = regionRect(region, on: target)
            guard let hit = WindowMatch.best(frames: wins.map(\.frame), in: rect, minimum: 0.6) else { continue }
            let window = wins[hit.index]
            guard let occupant = WindowMatch.captureOccupant(captureInput(for: window, windowsPerApp: windowsPerApp, tabs: tabs)) else { continue }
            slots.append(Slot(regionID: id, occupant: occupant))
            windowIndex.append(hit.index)
        }
        // Stacking among the captured windows, in window-server (front to back) order.
        let order = windowIndex.indices.sorted { windowIndex[$0] < windowIndex[$1] }
        let zs = ZOrder.captured(frontToBack: order.map { wins[windowIndex[$0]].frame })
        for (rank, slotIndex) in order.enumerated() where zs[rank] != 0 { slots[slotIndex].z = zs[rank] }
        return Loadout(name: name, layout: layout.name, slots: slots, hotkey: store.loadout(named: name)?.hotkey)
    }

    func captureInput(for window: WindowInfo, windowsPerApp: [String: Int],
                              tabs: BrowserTabs) -> WindowMatch.CaptureInput {
        var input = WindowMatch.CaptureInput(bundleID: window.bundleID, title: window.title)
        input.appWindowCount = window.bundleID.flatMap { windowsPerApp[$0] } ?? 1
        switch window.owned {
        case .web(let url): input.builtinWebURL = url
        case .browser(let url, let host): input.browserURL = url; input.browserHost = host
        case .panel(let id): input.panelID = id
        case nil:
            // A browser window MacHUD did not open: ask the browser what page it
            // is on, and fall back to an app slot when it will not say.
            if let kind = BrowserWindow.Kind(bundleID: window.bundleID),
               let url = tabs.url(forWindowOf: kind, title: window.title) {
                input.browserURL = url
                input.browserHost = kind.host
            }
        }
        return input
    }

    // MARK: - Status

    /// What currently sits in each region of the active layout.
    func status(screen: NSScreen? = nil) -> [RegionStatus] {
        guard let target = self.screen(screen) else { return [] }
        let loadout = activeLoadout.flatMap { store.loadout(named: $0) }
        let view = screenView(of: loadout, on: target)
        guard let layout = view.layout ?? store.activeLayout else { return [] }
        let slots = view.slots
        let space = Spaces.monitor(for: target)?.currentIndex
        let wins = windows()
        return layout.regions.enumerated().map { index, region in
            let id = region.id ?? ""
            let rect = regionRect(region, on: target)
            var status = RegionStatus(regionID: id, regionName: region.name ?? "Region \(index + 1)",
                                      frame: rect, occupant: slots.first { $0.regionID == id }?.occupant)
            status.screen = target.localizedName
            status.space = space
            if let hit = WindowMatch.best(frames: wins.map(\.frame), in: rect, minimum: 0.2) {
                status.window = wins[hit.index]
                status.iou = hit.iou
            }
            return status
        }
    }

    // MARK: - Single window

    enum PlaceResult {
        case placed(CGRect)
        case failed(String)
    }

    /// Move one window (by window-server number) into a region of the active layout.
    func place(windowNumber: Int, regionID: String, screen: NSScreen? = nil) -> PlaceResult {
        guard let layout = store.activeLayout else { return .failed("no active layout") }
        guard let region = layout.region(id: regionID) else { return .failed("no region \(regionID)") }
        guard let info = windows().first(where: { $0.windowNumber == windowNumber }) else {
            return .failed("no window \(windowNumber)")
        }
        let target = self.screen(screen) ?? ScreenCoords.screen(containing: CGPoint(x: info.frame.midX, y: info.frame.midY))
        guard let target else { return .failed("no screen") }
        let rect = regionRect(region, on: target)
        if info.pid == getpid() {
            guard let panel = panels.panels.first(where: { $0.window?.windowNumber == windowNumber }),
                  let window = panel.window else { return .failed("window is not placeable") }
            parking.release(.own(window))
            window.setFrame(rect, display: true)
            return .placed(rect)
        }
        guard let window = axWindow(for: info) else { return .failed("window is not placeable") }
        parking.release(.ax(window))
        if window.isMinimized { window.isMinimized = false }
        window.setCocoaFrame(rect)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { window.setCocoaFrame(rect) }
        return .placed(rect)
    }

    /// The accessibility element for a window-server window, matched by frame then title.
    func axWindow(for info: WindowInfo) -> AXWindow? {
        let candidates = AXWindow.all(pid: info.pid).filter { $0.isPlaceable }
        if let byFrame = candidates.first(where: { $0.cocoaFrame.map { Geometry.matches($0, info.frame, tolerance: 3) } == true }) {
            return byFrame
        }
        return candidates.first { !info.title.isEmpty && $0.title == info.title }
    }
}

enum Geometry {
    /// Same rect to within `tolerance` points on every edge.
    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

extension BrowserWindows {
    /// The window MacHUD opened for `url` that a slot reuses: the newest, and, when the slot was
    /// planned a new window here, only one on a desktop showing (`onScreen`, window numbers).
    func reusable(url: String, newWindowOnly: Bool, onScreen: Set<Int>) -> Entry? {
        entries.last { $0.url == url && (!newWindowOnly || onScreen.contains($0.number)) }
    }
}
