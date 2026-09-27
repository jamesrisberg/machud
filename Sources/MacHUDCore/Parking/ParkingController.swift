import AppKit
import HUDKit

/// Parks windows off-screen at an edge, remembers where they rest, and brings them back
/// from the orb on that edge. Rest frames are persisted, so a crash can be undone at the
/// next launch; quitting restores everything.
@MainActor
final class ParkingController {
    enum Target {
        /// Another app's window: moved through Accessibility, animated by `AXFrameAnimator`.
        case ax(AXWindow)
        /// One of MacHUD's own windows: animated with `HUDAnimation`.
        case own(NSWindow)
        /// A HUDKit app's panel: the app is asked to park itself (`panel mode`).
        case cooperative(HUDSocketClient, panelID: String)
    }

    @MainActor
    final class Parked {
        var record: ParkedRecord
        let target: Target
        var revealed = false
        var animator: AXFrameAnimator?

        init(record: ParkedRecord, target: Target) {
            self.record = record
            self.target = target
        }

        var json: [String: Any] {
            let r = record
            func rect(_ f: CGRect) -> [String: Int] {
                ["x": Int(f.minX), "y": Int(f.minY), "w": Int(f.width), "h": Int(f.height)]
            }
            var d: [String: Any] = ["id": r.id, "label": r.label, "kind": r.kind.rawValue, "edge": r.edge.rawValue,
                                    "peek": r.peek, "rest": rect(r.rest), "parked": rect(r.parked),
                                    "revealed": revealed]
            if let n = r.windowNumber { d["window"] = n }
            if let s = r.sliver { d["sliver"] = s }
            if let b = r.bundleID { d["bundleID"] = b }
            if let p = r.panelID { d["panel"] = p }
            if case .ax(let w) = target, let f = w.cocoaFrame { d["frame"] = rect(f) }
            if case .own(let w) = target { d["frame"] = rect(w.frame) }
            return d
        }
    }

    /// Maps a `panel` occupant id to a HUDKit app that parks itself. Set by the external
    /// panel registry; nil means every panel is MacHUD's own.
    var cooperativeResolver: ((String) -> Target?)?

    private let panels: PanelRegistry
    private let store: ParkingStore
    private var state: ParkingState
    private(set) var parked: [Parked] = []
    private var orbs: [HUDEdge: OrbPanel] = [:]
    private var hover: [HUDEdge: HoverReveal] = [:]
    private var poll: Timer?

    init(panels: PanelRegistry, stateURL: URL) {
        self.panels = panels
        store = ParkingStore(url: stateURL)
        state = store.load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.restoreAll(animated: false) }
        }
        if !state.parked.isEmpty {
            // Left over from a crash: put them back once the app is up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.recoverLeftovers() }
            }
        }
    }

    func cooperativeTarget(_ panelID: String) -> Target? { cooperativeResolver?(panelID) }

    /// The parking of `target`, if it is parked.
    func entry(for target: Target) -> Parked? { parked.first { Self.same($0.target, target) } }

    /// Whether orbs are hidden when nobody chose (`orb hide`/`orb show`, the setting):
    /// true while the tool dock is on, since it is then the main affordance.
    var orbsHiddenByDefault = false {
        didSet { if orbsHiddenByDefault != oldValue, state.orbsHidden == nil { refreshOrbs() } }
    }

    var orbsHidden: Bool { state.orbsHidden ?? orbsHiddenByDefault }

    // MARK: - Park / unpark

    /// Park `target`, whose rest frame is `rest`, past `edge` of `screen` (default: the
    /// screen `rest` is on). Replaces any earlier parking of the same id or window.
    @discardableResult
    func park(_ target: Target, id: String, label: String, rest: CGRect, edge: HUDEdge, peek: CGFloat,
              screen: NSScreen?) -> Parked {
        drop { $0.record.id == id || Self.same($0.target, target) }
        let screenFrame = screen?.frame ?? HUDParking.screenFrame(for: rest)
        let geometry = ParkGeometry.parkedFrame(rest: rest, edge: edge, peek: peek, screen: screenFrame,
                                                screens: NSScreen.screens.map(\.frame))
        var record = ParkedRecord(id: id, label: label, kind: .ax, rest: rest, parked: geometry.frame, edge: edge,
                                  peek: geometry.crossedDisplay ? 0 : Double(peek))
        switch target {
        case .ax(let w):
            record.pid = w.pid
            record.bundleID = NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier
            record.title = w.title
            let frame = w.cocoaFrame
            record.windowNumber = WindowList.onScreen().first { entry in
                entry.pid == w.pid && frame.map { Geometry.matches(entry.frame, $0, tolerance: 3) } == true
            }?.number
        case .own(let w):
            record.kind = .own
            record.windowNumber = w.windowNumber
            record.panelID = panels.panels.first { $0.window === w }?.id
        case .cooperative(let client, let panelID):
            record.kind = .cooperative
            record.socket = client.path
            record.panelID = panelID
        }
        let entry = Parked(record: record, target: target)
        parked.append(entry)
        conceal(entry)
        persist()
        refreshOrbs()
        return entry
    }

    /// Bring a parked window back to its rest frame for good. nil id means all.
    @discardableResult
    func unpark(id: String?) -> Int {
        let chosen = parked.filter { id == nil || $0.record.id == id }
        for entry in chosen { reveal(entry, raise: true) }
        parked.removeAll { entry in chosen.contains { $0 === entry } }
        persist()
        refreshOrbs()
        return chosen.count
    }

    /// Forget the parkings of a HUDKit app that quit: its panels went with it, and its
    /// orb would otherwise stay behind with nothing to reveal.
    func forgetCooperative(socketPath: String) {
        let before = parked.count
        drop { entry in
            if case .cooperative(let client, _) = entry.target { return client.path == socketPath }
            return false
        }
        if parked.count != before { persist(); refreshOrbs() }
    }

    /// Put every parked window back where it rests. On quit this must finish before the
    /// process exits, so it moves without animating.
    @discardableResult
    func restoreAll(animated: Bool) -> Int {
        guard animated else {
            let count = parked.count
            for entry in parked {
                entry.animator?.cancel()
                switch entry.target {
                case .ax(let w): if w.exists { w.setCocoaFrame(entry.record.rest) }
                case .own(let w): w.setFrame(entry.record.rest, display: true)
                case .cooperative(let client, let panelID):
                    Self.requestMode(client: client, panelID: panelID, mode: .full, async: false)
                }
            }
            parked = []
            persist()
            refreshOrbs()
            return count
        }
        return unpark(id: nil)
    }

    /// Forget a window that is being placed normally, without moving it.
    func release(_ placeable: LoadoutEngine.Placeable) {
        let target: Target
        switch placeable {
        case .ax(let w): target = .ax(w)
        case .own(let w): target = .own(w)
        case .external(let p): target = .cooperative(HUDSocketClient(path: p.app.socketPath), panelID: p.panelID)
        }
        guard parked.contains(where: { Self.same($0.target, target) }) else { return }
        drop { Self.same($0.target, target) }
        persist()
        refreshOrbs()
    }

    /// Temporarily reveal (or conceal) the windows parked on `edge` (all edges when nil),
    /// as hovering the orb does. `pin` keeps them revealed like a click.
    func reveal(edge: HUDEdge?, pin: Bool) -> Int {
        var count = 0
        for e in edgesInUse where edge == nil || e == edge {
            var h = hover[e] ?? HoverReveal()
            if let action = h.reveal(pin: pin) { perform(action, on: e) }
            hover[e] = h
            count += group(e).count
        }
        return count
    }

    func conceal(edge: HUDEdge?) -> Int {
        var count = 0
        for e in edgesInUse where edge == nil || e == edge {
            var h = hover[e] ?? HoverReveal()
            if let action = h.conceal() { perform(action, on: e) }
            hover[e] = h
            count += group(e).count
        }
        return count
    }

    // MARK: - Moving

    private func conceal(_ entry: Parked) {
        entry.revealed = false
        entry.animator?.cancel()
        switch entry.target {
        case .ax(let w):
            guard let from = w.cocoaFrame else { return }
            adoptMovedRest(entry, current: from)
            let animator = AXFrameAnimator(window: w, from: from, to: entry.record.parked,
                                           duration: HUDAnimation.concealDuration) { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.recordWhereItLanded(entry, window: w)
            }
            entry.animator = animator
            animator.start()
        case .own(let w):
            adoptMovedRest(entry, current: w.frame)
            HUDAnimation.animate(w, to: entry.record.parked, duration: HUDAnimation.concealDuration,
                                 timing: HUDAnimation.concealTiming)
        case .cooperative(let client, let panelID):
            Self.requestMode(client: client, panelID: panelID, mode: .parked, rest: entry.record.rest,
                             edge: entry.record.edge, peek: CGFloat(entry.record.peek))
        }
    }

    private func reveal(_ entry: Parked, raise: Bool) {
        entry.revealed = true
        entry.animator?.cancel()
        switch entry.target {
        case .ax(let w):
            guard let from = w.cocoaFrame else { return }
            if raise { w.raise() }
            let animator = AXFrameAnimator(window: w, from: from, to: entry.record.rest,
                                           duration: HUDAnimation.revealDuration, completion: nil)
            entry.animator = animator
            animator.start()
        case .own(let w):
            w.orderFrontRegardless()
            HUDAnimation.reveal(w, to: entry.record.rest)
        case .cooperative(let client, let panelID):
            Self.requestMode(client: client, panelID: panelID, mode: .full)
        }
    }

    /// A revealed window the user dragged somewhere else rests there from now on.
    private func adoptMovedRest(_ entry: Parked, current: CGRect) {
        guard !Geometry.matches(current, entry.record.parked, tolerance: 2),
              !Geometry.matches(current, entry.record.rest, tolerance: 2),
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(current) }),
              ParkGeometry.visibleSliver(of: current, edge: entry.record.edge,
                                         screens: NSScreen.screens.map(\.frame)) > CGFloat(entry.record.peek) + 8
        else { return }
        let screen = HUDParking.screenFrame(for: current)
        let geometry = ParkGeometry.parkedFrame(rest: current, edge: entry.record.edge,
                                                peek: CGFloat(entry.record.peek), screen: screen,
                                                screens: NSScreen.screens.map(\.frame))
        entry.record.rest = current
        entry.record.parked = geometry.frame
        entry.record.sliver = nil
        persist()
    }

    /// macOS keeps part of some windows on screen however far they are pushed; keep
    /// what it allowed as the parked frame and record the sliver.
    private func recordWhereItLanded(_ entry: Parked, window: AXWindow) {
        guard !entry.revealed, let actual = window.cocoaFrame else { return }
        if Geometry.matches(actual, entry.record.parked, tolerance: 2) { return }
        entry.record.parked = actual
        let sliver = ParkGeometry.visibleSliver(of: actual, edge: entry.record.edge,
                                                screens: NSScreen.screens.map(\.frame))
        entry.record.sliver = sliver > CGFloat(entry.record.peek) + 0.5 ? Double(sliver) : nil
        NSLog("MacHUD: %@ stopped at %@ while parking (%.0f pt still visible)", entry.record.label,
              NSStringFromRect(actual), sliver)
        persist()
    }

    /// One serial queue for every cooperative request, so a quick reveal-then-conceal
    /// reaches the app in that order (a concurrent queue could swap them).
    nonisolated static let socketQueue = DispatchQueue(label: "machud.parking.socket", qos: .userInitiated)

    /// Asks a HUDKit app to switch a panel's mode. Parking first tells the app its rest
    /// frame (`panel frame`), so it slides back to where the slot is, then passes the
    /// slot's edge and peek. Socket I/O stays off the main thread unless `async` is false
    /// (quitting).
    nonisolated static func requestMode(client: HUDSocketClient, panelID: String, mode: HUDPanelMode,
                                        rest: CGRect? = nil, edge: HUDEdge? = nil, peek: CGFloat? = nil,
                                        async: Bool = true) {
        let requests = modeRequests(panelID: panelID, mode: mode, rest: rest, edge: edge, peek: peek)
        let send: @Sendable () -> Void = {
            var c = client
            c.timeout = 2
            for args in requests {
                do {
                    _ = try c.request("panel", args: args)
                } catch {
                    NSLog("MacHUD: panel %@ for %@ failed: %@", args["action"] ?? "", panelID, "\(error)")
                    return
                }
            }
        }
        if async { socketQueue.async(execute: send) } else { send() }
    }

    /// The `panel` requests `requestMode` sends, in order. Pure, for tests.
    nonisolated static func modeRequests(panelID: String, mode: HUDPanelMode, rest: CGRect?, edge: HUDEdge?,
                                         peek: CGFloat?) -> [[String: String]] {
        var out: [[String: String]] = []
        if mode == .parked, let rest {
            out.append(["id": panelID, "action": "frame", "x": "\(Double(rest.minX))", "y": "\(Double(rest.minY))",
                        "w": "\(Double(rest.width))", "h": "\(Double(rest.height))"])
        }
        var args = ["id": panelID, "action": "mode", "mode": mode.rawValue]
        if mode == .parked {
            if let edge { args["edge"] = edge.rawValue }
            if let peek { args["peek"] = "\(Double(peek))" }
        }
        out.append(args)
        return out
    }

    // MARK: - Orbs

    private var edgesInUse: [HUDEdge] {
        HUDEdge.allCases.filter { e in parked.contains { $0.record.edge == e } }
    }

    private func group(_ edge: HUDEdge) -> [Parked] { parked.filter { $0.record.edge == edge } }

    private func perform(_ action: HoverReveal.Action, on edge: HUDEdge) {
        pruneGone()
        for entry in group(edge) {
            switch action {
            case .reveal: reveal(entry, raise: true)
            case .conceal: conceal(entry)
            }
        }
        orbs[edge]?.revealed = action == .reveal
    }

    func orbClicked(_ edge: HUDEdge) {
        var h = hover[edge] ?? HoverReveal()
        if let action = h.click() { perform(action, on: edge) }
        hover[edge] = h
    }

    func setOrbsHidden(_ hidden: Bool) {
        // Stored either way, so an explicit choice outlives the tool dock's default.
        state.orbsHidden = hidden
        persist()
        refreshOrbs()
    }

    /// Move an orb (circle origin, screen coordinates) and remember it.
    func setOrbOrigin(_ origin: CGPoint, edge: HUDEdge) {
        state.orbs[edge.rawValue] = origin
        persist()
        refreshOrbs()
    }

    func orbJSON() -> [[String: Any]] {
        edgesInUse.map { edge in
            var d: [String: Any] = ["edge": edge.rawValue, "count": group(edge).count,
                                    "visible": !orbsHidden && orbs[edge]?.isVisible == true,
                                    "revealed": hover[edge]?.isRevealed ?? false,
                                    "pinned": hover[edge]?.phase == .pinned]
            if let f = orbs[edge]?.orbFrame, !f.isNull {
                d["x"] = Int(f.minX); d["y"] = Int(f.minY); d["w"] = Int(f.width); d["h"] = Int(f.height)
            }
            return d
        }
    }

    private func refreshOrbs() {
        let edges = Set(edgesInUse)
        for (edge, orb) in orbs where !edges.contains(edge) || orbsHidden {
            orb.hide()
            if !edges.contains(edge) { orbs[edge] = nil; hover[edge] = nil }
        }
        guard !orbsHidden, !edges.isEmpty else { stopPolling(); return }
        for edge in edges {
            let orb = orbs[edge] ?? makeOrb(edge)
            orb.count = group(edge).count
            orb.show(at: orbOrigin(edge))
        }
        startPolling()
    }

    private func makeOrb(_ edge: HUDEdge) -> OrbPanel {
        let orb = OrbPanel(edge: edge)
        orb.onClick = { [weak self] in self?.orbClicked(edge) }
        orb.onMoved = { [weak self, weak orb] _ in
            guard let self, let origin = orb?.origin else { return }
            self.state.orbs[edge.rawValue] = origin
            self.persist()
        }
        orbs[edge] = orb
        return orb
    }

    private func orbOrigin(_ edge: HUDEdge) -> CGPoint {
        if let saved = state.orbs[edge.rawValue],
           NSScreen.screens.contains(where: { $0.frame.contains(saved) }) { return saved }
        let union = group(edge).reduce(CGRect.null) { $0.union($1.record.rest) }
        let screen = NSScreen.screens.max {
            $0.frame.intersection(union).area < $1.frame.intersection(union).area
        } ?? NSScreen.main
        return ParkGeometry.defaultOrbOrigin(edge: edge, restUnion: union,
                                             visible: screen?.visibleFrame ?? union, size: OrbPanel.diameter)
    }

    private func startPolling() {
        guard poll == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        for (edge, orb) in orbs where orb.isVisible {
            let circle = orb.orbFrame
            var area = circle
            for entry in group(edge) where entry.revealed { area = area.union(entry.record.rest) }
            var h = hover[edge] ?? HoverReveal()
            let action = h.update(onOrb: circle.insetBy(dx: -2, dy: -2).contains(mouse),
                                  inside: area.insetBy(dx: -4, dy: -4).contains(mouse), now: now)
            hover[edge] = h
            if let action { perform(action, on: edge) }
        }
    }

    // MARK: - Bookkeeping

    private func drop(where match: (Parked) -> Bool) {
        for entry in parked where match(entry) { entry.animator?.cancel() }
        parked.removeAll(where: match)
    }

    /// Windows whose app quit or that were closed.
    private func pruneGone() {
        let before = parked.count
        parked.removeAll { entry in
            switch entry.target {
            case .ax(let w): return !w.exists
            case .own(let w): return !w.isVisible
            case .cooperative: return false
            }
        }
        if parked.count != before { persist(); refreshOrbs() }
    }

    /// Called whenever the set of parked windows changes (the tool dock shows a button
    /// for them while the orbs are hidden).
    var onParkedChange: (() -> Void)?

    private func persist() {
        defer { onParkedChange?() }
        state.parked = parked.map(\.record)
        store.save(state)
        // A panel's mode (parked or not) is part of the state subscribers see.
        panels.noteChange()
    }

    static func same(_ a: Target, _ b: Target) -> Bool {
        switch (a, b) {
        case (.ax(let x), .ax(let y)): return x.isSame(as: y)
        case (.own(let x), .own(let y)): return x === y
        case (.cooperative(let c1, let p1), .cooperative(let c2, let p2)): return c1.path == c2.path && p1 == p2
        default: return false
        }
    }

    /// Records from a previous run that did not quit cleanly: find each window at its
    /// parked frame and put it back where it rested.
    private func recoverLeftovers() {
        guard Accessibility.isTrusted else { return }
        var recovered = 0
        for record in state.parked {
            switch record.kind {
            case .ax:
                if let w = Self.findLeftover(record) { w.setCocoaFrame(record.rest); recovered += 1 }
            case .cooperative:
                if let socket = record.socket, let panelID = record.panelID {
                    Self.requestMode(client: HUDSocketClient(path: socket), panelID: panelID, mode: .full)
                    recovered += 1
                }
            case .own:
                // Our own panels are rebuilt at their saved frames on launch.
                break
            }
        }
        NSLog("MacHUD: restored %d of %d windows left parked by the previous run", recovered, state.parked.count)
        state.parked = parked.map(\.record)
        store.save(state)
    }

    private static func findLeftover(_ record: ParkedRecord) -> AXWindow? {
        var pids: [pid_t] = []
        if let pid = record.pid, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
           record.bundleID == nil || app.bundleIdentifier == record.bundleID { pids.append(pid) }
        if let bundleID = record.bundleID {
            pids += NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier).filter { !pids.contains($0) }
        }
        let windows = pids.flatMap { AXWindow.all(pid: $0) }
        if let byFrame = windows.first(where: {
            $0.cocoaFrame.map { Geometry.matches($0, record.parked, tolerance: 4) } == true
        }) { return byFrame }
        return windows.first { w in
            guard let f = w.cocoaFrame, let title = record.title, !title.isEmpty, w.title == title else { return false }
            return abs(f.width - record.rest.width) <= 4 && abs(f.height - record.rest.height) <= 4
                && !NSScreen.screens.contains { $0.visibleFrame.contains(f) }
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
