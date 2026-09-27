import AppKit

/// Where the windows are right now, on every display and desktop: what the planner
/// reads. Built once per plan so the window server is asked once.
@MainActor
struct WindowLocator {
    let screens: [NSScreen]
    let monitors: [Spaces.Monitor]
    let entries: [AllSpacesWindows.Entry]

    init() {
        screens = NSScreen.screens
        monitors = Spaces.monitors()
        entries = AllSpacesWindows.list()
    }

    var planScreens: [PlacementPlan.Screen] {
        screens.map { screen in
            let monitor = Spaces.monitor(for: screen, in: monitors)
            return PlacementPlan.Screen(name: screen.localizedName, frame: screen.frame,
                                        currentSpace: monitor?.currentIndex, spaces: monitor?.count ?? 1)
        }
    }

    func screenIndex(containing frame: CGRect) -> Int? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let i = screens.firstIndex(where: { $0.frame.contains(center) }) { return i }
        func overlap(_ i: Int) -> CGFloat {
            let r = screens[i].frame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        return screens.indices.max { overlap($0) < overlap($1) }
    }

    /// The display and desktop a window is on. A window on every desktop reports no desktop.
    func location(number: Int, frame: CGRect, onScreen: Bool) -> (screen: Int?, space: Int?) {
        let ids = AllSpacesWindows.spaceIDs(number) ?? []
        if ids.count == 1 {
            for (i, screen) in screens.enumerated() {
                if let monitor = Spaces.monitor(for: screen, in: monitors),
                   let index = monitor.spaceIDs.firstIndex(of: ids[0]) {
                    return (i, index + 1)
                }
            }
        }
        let screen = screenIndex(containing: frame)
        guard ids.count <= 1, onScreen, let screen else { return (screen, nil) }
        return (screen, Spaces.monitor(for: screens[screen], in: monitors)?.currentIndex)
    }

    /// An app's usable windows on every desktop, front to back, as the planner sees them.
    /// Uses the same rules as `WindowMatch.choose`: placeable, standard ones preferred,
    /// `titleMatch` honoured.
    func candidates(pids: [pid_t], titleMatch: String?) -> [PlacementPlan.Candidate] {
        var out: [(order: Int, candidate: PlacementPlan.Candidate, standard: Bool)] = []
        for pid in pids {
            let mine = entries.enumerated().filter { $0.element.pid == pid }
            let wanted = Set(mine.map(\.element.number))
            for (window, number) in AllSpacesWindows.axWindows(pid: pid, wanted: wanted) {
                guard window.isPlaceable else { continue }
                let title = window.title
                if let pattern = titleMatch, !pattern.isEmpty, !WindowMatch.titleMatches(title, pattern: pattern) { continue }
                let entry = mine.first { $0.element.number == number }
                guard let frame = entry?.element.frame ?? window.cocoaFrame else { continue }
                let minimized = window.isMinimized
                // A window accessibility lists without a number is on this desktop.
                let visible = !minimized && (entry?.element.onScreen ?? true)
                let place: (screen: Int?, space: Int?) = number.map { location(number: $0, frame: frame, onScreen: visible) }
                    ?? (screenIndex(containing: frame), nil)
                out.append((entry?.offset ?? Int.max,
                            PlacementPlan.Candidate(number: number ?? 0, title: title, frame: frame,
                                                    screen: place.screen, space: place.space,
                                                    visible: visible, minimized: minimized),
                            window.isStandard))
            }
        }
        if out.contains(where: \.standard) { out = out.filter(\.standard) }
        return out.sorted { $0.order < $1.order }.map(\.candidate)
    }
}

extension LoadoutEngine {
    // MARK: - Planning

    /// Decide every slot of `groups` (see `PlacementPlan`), store the step on its job and
    /// return the steps in apply order. Reads windows, never moves one.
    @discardableResult
    func attachPlan(to groups: [ResolvedGroup]) -> [PlacementPlan.Step] {
        let locator = WindowLocator()
        let screens = locator.planScreens
        let policy = store.spacesPolicy
        var claimed: Set<Int> = []
        var steps: [PlacementPlan.Step] = []
        for group in groups {
            let screenIndex = locator.screens.firstIndex(of: group.screen) ?? 0
            for job in group.jobs {
                var input = slotInput(job, screen: screenIndex, space: group.space, locator: locator)
                input.candidates.removeAll { $0.number != 0 && claimed.contains($0.number) }
                let step = PlacementPlan.step(for: input, screens: screens, policy: policy)
                if let n = step.window, n != 0 { claimed.insert(n) }
                job.step = step
                steps.append(step)
            }
        }
        return steps
    }

    private func regionName(_ regionID: String) -> String {
        for layout in store.layouts {
            if let i = layout.regionIndex(id: regionID) { return layout.regions[i].name ?? "Region \(i + 1)" }
        }
        return regionID
    }

    private func slotInput(_ job: SlotJob, screen: Int, space: Int?, locator: WindowLocator) -> PlacementPlan.SlotInput {
        var input = PlacementPlan.SlotInput(regionID: job.regionID, regionName: regionName(job.regionID),
                                            occupant: job.occupant.label, screen: screen, space: space, rect: job.rect)
        switch job.occupant {
        case .app(let bundleID, let titleMatch):
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
            input.running = !running.isEmpty
            input.installed = input.running || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            input.candidates = locator.candidates(pids: running.map(\.processIdentifier), titleMatch: titleMatch)
            // Only worth the menu walk when the window is out of reach.
            let menu = running.first.map { app in
                input.candidates.contains { $0.visible || $0.minimized } ? true
                    : AXWindow.newWindowItem(pid: app.processIdentifier) != nil
            } ?? false
            input.newWindow = NewWindowClass.of(bundleID: bundleID, hasNewWindowMenu: menu)
        case .web(let url, let host):
            input.kind = .web
            input.running = true
            input.newWindow = .browser
            let window: AXWindow? = host == .builtin ? nil : browsers.window(url: url)
            if let window, let frame = window.cocoaFrame {
                let number = window.windowNumber ?? 0
                let visible = WindowList.onScreen().contains { $0.number == number }
                let place = locator.location(number: number, frame: frame, onScreen: visible)
                input.candidates = [PlacementPlan.Candidate(number: number, title: window.title, frame: frame,
                                                            screen: place.screen, space: place.space,
                                                            visible: visible, minimized: window.isMinimized)]
            }
        case .panel(let id):
            input.kind = .panel
            input.running = true
            input.newWindow = .single
            if let panel = panels.panel(id: id), panel.isVisible, let window = panel.window {
                input.candidates = [PlacementPlan.Candidate(number: window.windowNumber, title: panel.title,
                                                            frame: window.frame,
                                                            screen: locator.screenIndex(containing: window.frame),
                                                            space: nil, visible: true)]
            } else if panels.panel(id: id) == nil, !id.hasPrefix("web:") {
                input.blocked = "no panel \(id)"
            }
        }
        return input
    }

    /// `apply loadout=X plan=1`: what apply would do, slot by slot, without doing it.
    func planJSON(_ loadout: Loadout, screen: NSScreen? = nil) -> [String: Any] {
        let (steps, report) = plan(loadout, screen: screen)
        var d: [String: Any] = ["ok": true, "loadout": loadout.name, "policy": store.spacesPolicy.rawValue,
                                "plan": steps.map(\.json)]
        if loadout.hud != nil { d["hud"] = true }
        if !report.failed.isEmpty { d["failed"] = report.failed }
        if !report.redirected.isEmpty { d["redirected"] = report.redirected.map(\.json) }
        return d
    }

    /// The same plan as values, for the preview overlay.
    func plan(_ loadout: Loadout, screen: NSScreen? = nil) -> (steps: [PlacementPlan.Step], report: ApplyReport) {
        var report = ApplyReport(loadout: loadout.name)
        // A HUD-only loadout has no layout and no windows to place.
        guard !loadout.allSlots.isEmpty || loadout.hud == nil else { return ([], report) }
        let groups = resolveGroups(loadout, screen: screen, report: &report)
        return (attachPlan(to: groups), report)
    }

    // MARK: - Carrying out the plan

    /// Before a group's slots are resolved: fail the slots the plan leaves out, pin the
    /// chosen windows, and fetch windows from hidden desktops one at a time.
    func prepare(_ group: ResolvedGroup, report: ApplyReport, completion: @escaping (ApplyReport) -> Void) {
        var report = report
        var fetches: [SlotJob] = []
        for job in group.jobs where !job.done {
            guard let step = job.step else { continue }
            switch step.action {
            case .leave, .cannot:
                job.done = true
                report.failed[job.regionID] = "\(step.action.rawValue): \(step.reason)"
            default:
                job.preferredWindow = step.window
                job.newWindowOnly = step.newWindow
                if step.bring != nil { fetches.append(job) }
            }
        }
        func next() {
            guard !fetches.isEmpty else { completion(report); return }
            let job = fetches.removeFirst()
            bring(job, into: group.screen) { failure in
                MainActor.assumeIsolated {
                    if let failure { self.bringFailed(job, failure, report: &report) }
                    next()
                }
            }
        }
        next()
    }

    /// Fetching failed: open a new window instead when the app can, else report it.
    private func bringFailed(_ job: SlotJob, _ failure: String, report: inout ApplyReport) {
        NSLog("MacHUD: could not bring %@: %@", job.occupant.label, failure)
        var canOpen = false
        if case .app(let bundleID, _) = job.occupant,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            canOpen = NewWindowClass.of(bundleID: bundleID,
                                        hasNewWindowMenu: AXWindow.newWindowItem(pid: app.processIdentifier) != nil).canOpenAnother
        }
        let index = report.steps.firstIndex { $0.regionID == job.regionID }
        if canOpen {
            job.preferredWindow = nil
            job.newWindowOnly = true
            if let index {
                report.steps[index].action = .launch
                report.steps[index].reason = "could not bring it (\(failure)); opened a new window here"
            }
        } else {
            job.done = true
            report.failed[job.regionID] = "cannot: could not bring it from its desktop (\(failure))"
            if let index {
                report.steps[index].action = .cannot
                report.steps[index].reason = "could not bring it from its desktop (\(failure))"
            }
        }
    }

    /// Fetch a window from a desktop that is not showing. On another display: show its
    /// desktop there, move it into the region (it joins the target display's showing
    /// desktop), switch that display back. On the target display itself: the same, but
    /// parked on another display while this one switches back, then moved home. macOS 26
    /// ignores the private move-to-space call, so a display is the only way across.
    func bring(_ job: SlotJob, into target: NSScreen, completion: @escaping (String?) -> Void) {
        guard let number = job.preferredWindow, number != 0 else { completion("no window number"); return }
        let locator = WindowLocator()
        guard let entry = locator.entries.first(where: { $0.number == number }) else {
            completion("window \(number) is gone"); return
        }
        if entry.onScreen { completion(nil); return }
        let place = locator.location(number: number, frame: entry.frame, onScreen: false)
        guard let from = place.screen, let space = place.space else { completion("its desktop is unknown"); return }
        let home = locator.screens[from]
        let via = home == target ? locator.screens.first { $0 != target } : nil
        if home == target, via == nil { completion("only one display"); return }
        let origin = Spaces.monitor(for: home, in: locator.monitors)?.currentIndex
        let pid = entry.pid
        let rect = job.rect

        func ax() -> AXWindow? {
            AllSpacesWindows.axWindows(pid: pid, wanted: [number]).first { $0.number == number }?.window
        }
        func after(_ seconds: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
        }
        func finish() {
            after(0.3) {
                let shown = WindowList.onScreen().contains { $0.number == number }
                completion(shown ? nil : "it stayed on desktop \(space)")
            }
        }

        Spaces.switchTo(space, on: home) { result in
            if case .failure(let error) = result { completion(error.reason); return }
            guard let window = ax() else { completion("accessibility cannot reach it"); return }
            if window.isMinimized { window.isMinimized = false }
            if let via {
                let size = CGSize(width: min(rect.width, via.visibleFrame.width), height: min(rect.height, via.visibleFrame.height))
                window.setCocoaFrame(CGRect(x: via.visibleFrame.midX - size.width / 2, y: via.visibleFrame.midY - size.height / 2,
                                            width: size.width, height: size.height))
            } else {
                window.setCocoaFrame(rect)
            }
            after(0.3) {
                guard let origin else { finish(); return }
                Spaces.switchTo(origin, on: home) { _ in
                    if via != nil { ax()?.setCocoaFrame(rect) }
                    finish()
                }
            }
        }
    }

    /// The window the plan chose, when accessibility can reach it here.
    func preferredWindow(_ job: SlotJob, running: [NSRunningApplication]) -> AXWindow? {
        guard let number = job.preferredWindow, number != 0 else { return nil }
        for app in running {
            if let window = AXWindow.all(pid: app.processIdentifier).first(where: { $0.windowNumber == number && $0.exists }) {
                return window
            }
        }
        return nil
    }

    /// `launchNew`: ask the running app for another window without activating it (a browser
    /// by Apple event, anything else through its ⌘N menu item) and adopt the window it opens.
    func resolveNewWindow(_ job: SlotJob, bundleID: String, running: [NSRunningApplication]) -> Resolution {
        guard let app = running.first else { return .failed("\(job.occupant.label) is not running") }
        if !job.askedForWindow {
            job.askedForWindow = true
            job.baseline = NewWindow.baseline(bundleID: bundleID)
            job.askedAt = Date()
            let asked: Bool
            if NewWindowClass.browsers.contains(bundleID), bundleID != "org.mozilla.firefox" {
                let verb = bundleID == "com.apple.Safari" ? "make new document" : "make new window"
                asked = (try? AppleScriptRunner.run("tell application id \(AppleScriptRunner.quote(bundleID)) to \(verb)",
                                                    timeout: 4).get()) != nil
            } else {
                asked = AXWindow.openNewWindow(pid: app.processIdentifier)
            }
            return asked ? .waiting : .failed("cannot: \(job.occupant.label) would not open a new window without coming forward")
        }
        if let new = NewWindow.since(job.baseline, bundleID: bundleID) { return .ready(.ax(new.window)) }
        if Date().timeIntervalSince(job.askedAt ?? Date()) > 3,
           NewWindow.isOnAnotherDesktop(job.baseline, bundleID: bundleID) {
            return .failed("\(job.occupant.label) opened its new window on another desktop")
        }
        return .waiting
    }

    // MARK: - Checking the result

    /// Read back where each placed window ended up. A window that is not in its region gets
    /// one more try, size first (moving across displays, macOS clamps the size against the
    /// display the window came from); what it then keeps is reported in `actual`.
    func verifyPlacement(_ jobs: [SlotJob], report: ApplyReport, completion: @escaping (ApplyReport) -> Void) {
        let placed = jobs.filter { $0.slot?.isParked != true }.compactMap { job -> (SlotJob, AXWindow)? in
            guard case .ax(let window)? = job.placed else { return nil }
            return (job, window)
        }
        guard !placed.isEmpty else { completion(report); return }
        var report = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            MainActor.assumeIsolated {
                var retried = false
                for (job, window) in placed {
                    guard let frame = window.cocoaFrame, !Geometry.matches(frame, job.rect, tolerance: 2) else { continue }
                    window.setCocoaFrameSizeFirst(job.rect)
                    retried = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (retried ? 0.25 : 0)) {
                    MainActor.assumeIsolated {
                        for (job, window) in placed {
                            guard let frame = window.cocoaFrame, !Geometry.matches(frame, job.rect, tolerance: 2) else { continue }
                            report.actual[job.regionID] = frame
                        }
                        completion(report)
                    }
                }
            }
        }
    }
}

extension LoadoutEngine.ApplyReport {
    /// Per-slot result: the plan's step plus what happened.
    var slotsJSON: [[String: Any]] {
        steps.map { step in
            var d = step.json
            if placed.contains(step.regionID) {
                d["result"] = "placed"
            } else if let reason = failed[step.regionID] {
                d["result"] = "failed"
                d["error"] = reason
            }
            if let frame = actual[step.regionID] {
                d["actual"] = PlacementPlan.Location(frame: frame).json["frame"]
                d["note"] = "the app kept \(Int(frame.width))×\(Int(frame.height)) (a minimum or maximum size?)"
            }
            return d
        }
    }

    /// Toast lines: every slot that did something other than a plain in-place fit, and
    /// every failure.
    func detailLines(labels: (String) -> String) -> [String] {
        var lines: [String] = []
        var covered = Set<String>()
        for step in steps {
            covered.insert(step.regionID)
            if let reason = failed[step.regionID] {
                lines.append("\(step.occupant): \(reason)")
            } else if [.move, .switchSpace, .launch].contains(step.action) {
                lines.append("\(step.occupant): \(step.reason)")
            }
            if let frame = actual[step.regionID] {
                lines.append("\(step.occupant): kept \(Int(frame.width))×\(Int(frame.height)), not its region's size")
            }
        }
        let screenFailures = Set(redirected.map { "screen:\($0.screen)" })
        for (key, reason) in failed where !covered.contains(key) && !screenFailures.contains(key) {
            lines.append("\(labels(key)): \(reason)")
        }
        return lines
    }
}

extension AXWindow {
    /// Size, position, size: for a window moved across displays of different sizes.
    func setCocoaFrameSizeFirst(_ r: CGRect) {
        let ax = ScreenCoords.axRect(fromCocoa: r)
        AXUIElementSetMessagingTimeout(element, 0.5)
        element.set(kAXSizeAttribute, size: ax.size)
        element.set(kAXPositionAttribute, point: ax.origin)
        element.set(kAXSizeAttribute, size: ax.size)
    }
}
