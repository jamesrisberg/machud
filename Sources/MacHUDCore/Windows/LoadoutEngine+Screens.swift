import AppKit

/// Splitting a loadout into the groups `apply` visits in turn: one per display
/// and desktop. Pure, so the ordering is unit tested.
enum LoadoutPlan {
    struct Group: Equatable {
        /// nil means the one-screen form: the screen under the mouse.
        var screen: ScreenRef?
        var layout: String
        var space: Int?
        var slots: [Slot]
        /// Index into the loadout's `screens`, nil for the one-screen form.
        var assignment: Int? = nil
    }

    static func groups(for loadout: Loadout) -> [Group] {
        let assignments = loadout.screens ?? []
        var out: [Group] = []
        if !loadout.slots.isEmpty || assignments.isEmpty {
            out += split(screen: nil, layout: loadout.layout, slots: loadout.slots, space: nil, assignment: nil)
        }
        for (index, assignment) in assignments.enumerated() {
            out += split(screen: assignment.screen, layout: assignment.layout, slots: assignment.slots,
                         space: assignment.space, assignment: index)
        }
        return out
    }

    /// Slots that name no desktop go first: they need no switching. A slot's own
    /// `space` wins over the desktop the whole assignment was captured on.
    private static func split(screen: ScreenRef?, layout: String, slots: [Slot],
                              space assignmentSpace: Int?, assignment: Int?) -> [Group] {
        guard !slots.isEmpty else {
            return [Group(screen: screen, layout: layout, space: assignmentSpace, slots: [], assignment: assignment)]
        }
        let spaceOf: (Slot) -> Int? = { $0.space ?? assignmentSpace }
        var spaces: [Int?] = []
        for slot in slots where !spaces.contains(spaceOf(slot)) { spaces.append(spaceOf(slot)) }
        spaces.sort { a, b in
            switch (a, b) {
            case (nil, nil), (_?, nil): return false
            case (nil, _?): return true
            case (let x?, let y?): return x < y
            }
        }
        return spaces.map { space in
            Group(screen: screen, layout: layout, space: space,
                  slots: slots.filter { spaceOf($0) == space }, assignment: assignment)
        }
    }
}

extension LoadoutEngine {
    struct ResolvedGroup {
        var screen: NSScreen
        var space: Int?
        var jobs: [SlotJob]
    }

    /// Which display (and desktop) each per-display assignment ends up on. An
    /// assignment whose display is not attached is redirected to its fallback,
    /// or to a free desktop on the main display; the redirections and the
    /// assignments with nowhere to go are written into `report`.
    func destinations(for loadout: Loadout, monitors: [Spaces.Monitor],
                              report: inout ApplyReport) -> [Int: (screen: NSScreen, space: Int?)] {
        let assignments = loadout.screens ?? []
        guard !assignments.isEmpty else { return [:] }
        let screens = NSScreen.screens
        let outcomes = ScreenFallback.plan(
            assignments.map {
                ScreenFallback.Request(screen: $0.screen, space: $0.space ?? $0.slots.compactMap(\.space).min(),
                                       fallback: $0.fallback)
            },
            screens: screens.map(\.descriptor), policy: loadout.screenMissingPolicy,
            desktops: { index in
                let monitor = Spaces.monitor(for: screens[index], in: monitors)
                return ScreenFallback.Desktops(count: monitor?.count ?? 1, current: monitor?.currentIndex)
            })

        var out: [Int: (screen: NSScreen, space: Int?)] = [:]
        for (index, outcome) in outcomes.enumerated() {
            let label = assignments[index].screen.label
            switch outcome {
            case .present(let i, _):
                out[index] = (screens[i], nil)
            case .redirected(let i, let space):
                out[index] = (screens[i], space)
                report.redirected.append(Redirect(assignment: index, screen: label,
                                                  toScreen: screens[i].localizedName, toSpace: space,
                                                  reason: "redirected", needsDesktops: nil))
            case .needsDesktops(let i, let count):
                report.failed["screen:\(label)"] = "needsDesktops"
                report.redirected.append(Redirect(assignment: index, screen: label,
                                                  toScreen: screens.indices.contains(i) ? screens[i].localizedName : nil,
                                                  toSpace: nil, reason: "needsDesktops", needsDesktops: count))
            case .skipped:
                report.failed["screen:\(label)"] = "screenMissing"
                report.redirected.append(Redirect(assignment: index, screen: label, toScreen: nil, toSpace: nil,
                                                  reason: "screenMissing", needsDesktops: nil))
            }
        }
        return out
    }

    /// The (display, desktop) groups an apply visits, each with its slot jobs. Missing
    /// displays, layouts and regions are written into `report`.
    func resolveGroups(_ loadout: Loadout, screen: NSScreen?, report: inout ApplyReport) -> [ResolvedGroup] {
        let monitors = Spaces.monitors()
        let destinations = self.destinations(for: loadout, monitors: monitors, report: &report)

        var groups: [ResolvedGroup] = []
        for group in LoadoutPlan.groups(for: loadout) {
            let key = group.screen.map { "screen:\($0.label)" } ?? "*"
            let target: NSScreen
            var space = group.space
            if let index = group.assignment {
                // A missing display with nowhere to go was reported already.
                guard let destination = destinations[index] else { continue }
                target = destination.screen
                if let forced = destination.space { space = forced }
            } else if let mouse = self.screen(screen) {
                target = mouse
            } else {
                report.failed[key] = "no screen"
                continue
            }
            guard let layout = store.layout(named: group.layout) else {
                report.failed[key] = "no layout named \(group.layout)"
                continue
            }
            let monitor = Spaces.monitor(for: target, in: monitors)
            var jobs: [SlotJob] = []
            for slot in group.slots {
                guard let region = layout.region(id: slot.regionID) else {
                    report.failed[slot.regionID] = "no such region"
                    continue
                }
                let job = SlotJob(regionID: slot.regionID, occupant: slot.occupant,
                                  rect: regionRect(region, on: target))
                job.slot = slot
                job.space = space
                job.spaceID = space.flatMap { monitor?.spaceID(at: $0) }
                jobs.append(job)
            }
            groups.append(ResolvedGroup(screen: target, space: space, jobs: jobs))
        }
        return groups
    }

    /// Apply every (display, desktop) group in turn, switching desktops where a
    /// slot asks for one and returning to the desktop that was showing before.
    func applyAcrossScreens(_ loadout: Loadout, clear: Bool, screen: NSScreen?,
                            completion: @escaping (ApplyReport) -> Void) {
        var report = ApplyReport(loadout: loadout.name)
        let groups = resolveGroups(loadout, screen: screen, report: &report)
        redirects = report.redirected
        redirectLoadout = loadout.name
        // Decide every slot up front, exactly as `apply … plan=1` reports it.
        report.steps = attachPlan(to: groups)
        let everyJob = groups.flatMap(\.jobs)
        guard !groups.isEmpty else { completion(report); return }

        var origins: [(screen: NSScreen, index: Int)] = []
        var index = 0

        func restore() {
            guard let origin = origins.popLast() else { completion(report); return }
            Spaces.switchTo(origin.index, on: origin.screen) { _ in restore() }
        }

        func enter(_ group: ResolvedGroup, done: @escaping (String?) -> Void) {
            guard let space = group.space else { done(nil); return }
            guard let monitor = Spaces.monitor(for: group.screen) else {
                done(Spaces.SwitchError.noDesktops.reason); return
            }
            guard monitor.currentIndex != space else { done(nil); return }
            if let current = monitor.currentIndex,
               !origins.contains(where: { $0.screen == group.screen }) {
                origins.append((group.screen, current))
            }
            Spaces.switchTo(space, on: group.screen) { result in
                switch result {
                case .success: done(nil)
                case .failure(let error):
                    NSLog("MacHUD: %@: %@", error.reason, error.message)
                    done(error.reason)
                }
            }
        }

        func step() {
            guard index < groups.count else { restore(); return }
            let group = groups[index]
            index += 1
            enter(group) { failure in
                if let failure {
                    for job in group.jobs { report.failed[job.regionID] = failure }
                    step()
                    return
                }
                if clear { report.cleared += self.clearOthers(keeping: everyJob, on: group.screen.frame) }
                guard !group.jobs.isEmpty else { step(); return }
                self.prepare(group, report: report) { prepared in
                    self.run(group.jobs, report: prepared) { updated in
                        report = updated
                        step()
                    }
                }
            }
        }
        step()
    }

    /// macOS hides a background app's windows from the accessibility API while
    /// they are on another desktop, so the engine would think the app has none
    /// and activate it to open one — which drags the desktop back. Catch that
    /// first: the window server still lists the windows.
    func spaceIssue(before job: SlotJob) -> String? {
        guard job.space != nil, !job.newWindowOnly, case .app(let bundleID, _) = job.occupant else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard !running.isEmpty else { return nil }
        // A window the accessibility API can see is either here or minimized;
        // either way the engine can place it.
        guard running.allSatisfy({ AXWindow.all(pid: $0.processIdentifier).filter(\.exists).isEmpty }) else {
            return nil
        }
        let numbers = running.flatMap { SpacesPrivate.windows(pid: $0.processIdentifier).map(\.number) }
        guard !numbers.isEmpty else { return nil }
        // One attempt at dragging the windows over, then judge by the result:
        // the private call reports nothing and is a no-op on some systems.
        if store.config.experimental?.spacesPrivateAPI == true, !job.movedForSpace, let spaceID = job.spaceID {
            job.movedForSpace = true
            if SpacesPrivate.move(windowNumbers: numbers, toSpace: spaceID) { return nil }
        }
        return "onOtherSpace"
    }

    /// A window that lives on another desktop cannot be placed from here. With
    /// the private API enabled it is dragged over; otherwise the slot fails.
    func spaceIssue(_ placeable: Placeable, job: SlotJob) -> String? {
        guard job.space != nil, case .ax(let window) = placeable else { return nil }
        guard !window.isMinimized, let frame = window.cocoaFrame else { return nil }
        let onThisDesktop = WindowList.onScreen().contains {
            $0.pid == window.pid && Geometry.matches($0.frame, frame, tolerance: 3)
        }
        return onThisDesktop ? nil : "onOtherSpace"
    }

    /// What a loadout puts on one display: its assignment for that display if it
    /// has one, otherwise the one-screen form (whose layout is the active one).
    func screenView(of loadout: Loadout?, on screen: NSScreen) -> (layout: Layout?, slots: [Slot]) {
        guard let loadout else { return (nil, []) }
        let descriptors = NSScreen.screens.map(\.descriptor)
        let position = NSScreen.screens.firstIndex(of: screen)
        let assignments = loadout.screens ?? []
        for assignment in assignments where assignment.screen.index(in: descriptors) == position {
            return (store.layout(named: assignment.layout), assignment.slots)
        }
        // A display that is not attached: show what the last apply put here instead.
        if redirectLoadout == loadout.name {
            for redirect in redirects where redirect.toScreen == screen.localizedName
                && assignments.indices.contains(redirect.assignment) {
                let assignment = assignments[redirect.assignment]
                return (store.layout(named: assignment.layout), assignment.slots)
            }
        }
        return (nil, loadout.slots)
    }

    // MARK: - Capture

    /// Capture several displays at once: each assignment's regions are read on
    /// its own screen, on whatever desktop is showing.
    func capture(name: String, assignments: [(ref: ScreenRef, layout: Layout, screen: NSScreen)]) -> Loadout {
        var loadout = Loadout(name: name, layout: assignments.first?.layout.name ?? "", slots: [],
                              hotkey: store.loadout(named: name)?.hotkey)
        loadout.screens = assignments.map { assignment in
            ScreenAssignment(screen: assignment.ref, layout: assignment.layout.name,
                             slots: capture(name: name, layout: assignment.layout, screen: assignment.screen).slots)
        }
        return loadout
    }

    enum ParsedScreens {
        case assignments([(ref: ScreenRef, layout: Layout, screen: NSScreen)])
        case error(String)
    }

    /// `<layout>@<screen>,<layout>@<screen>`; the layout may be left out to use
    /// the active one (`@main`).
    func parseCaptureScreens(_ text: String) -> ParsedScreens {
        var out: [(ref: ScreenRef, layout: Layout, screen: NSScreen)] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let pieces = part.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            let layoutName = pieces.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
                ?? store.activeLayout?.name ?? ""
            guard let layout = store.layout(named: layoutName) else { return .error("no layout named \(layoutName)") }
            guard pieces.count == 2, let ref = ScreenRef.parse(String(pieces[1])) else {
                return .error("expected <layout>@<screen> in \(part)")
            }
            guard let screen = ref.resolve() else { return .error("no screen matching \(ref.label)") }
            out.append((ref, layout, screen))
        }
        return out.isEmpty ? .error("screens=<layout>@<screen>,... required") : .assignments(out)
    }
}
