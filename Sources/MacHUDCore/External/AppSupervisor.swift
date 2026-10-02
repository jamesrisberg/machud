import AppKit
import HUDKit

/// What the supervisor needs from NSWorkspace; injected so the state machine is testable.
@MainActor
protocol WorkspaceControl: AnyObject {
    func runningPIDs(bundleID: String) -> [pid_t]
    /// The app's running processes with when each started and the bundle it runs from.
    func processes(bundleID: String) -> [AppProcess]
    func isInstalled(_ app: ExternalApp) -> Bool
    /// Launches without activating. `completion` runs on the main thread.
    func launch(_ app: ExternalApp, completion: @escaping (Error?) -> Void)
    /// Asks every instance to quit. False when none was running.
    func terminate(bundleID: String) -> Bool
    /// Kills these processes (a hung app that ignores the quit).
    func forceTerminate(pids: Set<pid_t>)
    /// Set by the supervisor; called on the main thread with the bundle id and pid.
    var onLaunch: ((String) -> Void)? { get set }
    /// The pid is passed because `runningPIDs` can still list the process while its
    /// termination is being announced.
    var onTerminate: ((String, pid_t) -> Void)? { get set }
}

/// A live subscription the supervisor can cancel.
protocol SocketSubscription: AnyObject {
    func cancel()
}

extension HUDSubscription: SocketSubscription {}

/// Socket I/O for the supervisor; every callback arrives on the main thread.
@MainActor
protocol SocketConnector: AnyObject {
    func subscribe(path: String, onEvent: @escaping ([String: Any]) -> Void, onClose: @escaping () -> Void,
                   completion: @escaping (Result<SocketSubscription, Error>) -> Void)
    func request(path: String, command: String, args: [String: String],
                 completion: @escaping (Result<[String: Any], Error>) -> Void)
}

/// Launches, watches and talks to the sibling MacHUD apps.
///
/// Per app: `notInstalled` → `notRunning` → `launching` → `socketUnreachable` (process up,
/// no subscription yet) → `running` (subscribed to `state`). A lost subscription while the
/// process lives goes back to `socketUnreachable` and reconnects with backoff. Relaunching
/// (only for `autoLaunch` apps that quit unexpectedly, or a failed on-demand launch) backs
/// off exponentially and gives up after `maxLaunchAttempts`; a run of `stableRun` seconds
/// or an explicit `apps launch` resets the count.
///
/// It also keeps what each app said in `hello` (contract and version), judges whether a
/// running app is behind its bundle on disk (`buildStatus`), checks that a panel MacHUD
/// showed reached the screen (`verifyShow`), and relaunches apps (`relaunch`).
@MainActor
final class AppSupervisor {
    enum Health: String {
        case running, socketUnreachable, launching, notRunning, notInstalled
    }

    final class Record {
        var app: ExternalApp
        var health: Health = .notRunning
        var autoLaunch = false
        var subscription: SocketSubscription?
        var connecting = false
        var connectAttempts = 0
        var launchAttempts = 0
        var launchInFlight = false
        var relaunchScheduled = false
        var launchedAt: Date?
        var quitRequested = false
        var lastError: String?
        /// Announced terminated but possibly still listed by NSRunningApplication.
        var deadPIDs: Set<pid_t> = []
        /// Latest pushed state per panel id.
        var panels: [String: HUDPanelState] = [:]
        /// Frames apps that report one in `state` (`frame`) gave, per panel id.
        var frames: [String: CGRect] = [:]
        /// The app's `hello` since it last connected.
        var hello: AppHello?
        /// Where each shown panel was found after MacHUD showed it, per panel id; dropped
        /// when the panel hides.
        var showChecks: [String: ShowOutcome] = [:]
        /// A `relaunch` is under way.
        var relaunching = false
        /// Old processes a relaunch waits to see announced terminated, so a late notice
        /// cannot land on the new instance.
        var relaunchAwaiting: Set<pid_t> = []
        /// Commands waiting for the socket, with when they give up.
        var pending: [(command: String, args: [String: String], deadline: Date,
                       completion: ((Result<[String: Any], Error>) -> Void)?)] = []

        init(app: ExternalApp) { self.app = app }

        /// The manifest as a JSON object (its panels' verbs and capabilities included), so a
        /// client learns what an app offers from `apps` without reading its bundle.
        private static func object(_ manifest: HUDManifest) -> [String: Any]? {
            guard let data = try? JSONEncoder().encode(manifest) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        var isSubscribed: Bool { subscription != nil }

        var json: [String: Any] {
            var d: [String: Any] = ["id": app.id, "name": app.name, "bundle": app.bundleURL.path,
                                    "socket": app.socketPath, "health": health.rawValue,
                                    "running": health == .running || health == .socketUnreachable,
                                    "reachable": health == .running, "autoLaunch": autoLaunch,
                                    "launchAttempts": launchAttempts,
                                    "panels": app.manifest.presentedPanels.map { "\(app.id)/\($0.id)" },
                                    "widgets": app.manifest.widgetPanels.map(\.id)]
            if let manifest = Self.object(app.manifest) { d["manifest"] = manifest }
            if let lastError { d["lastError"] = lastError }
            return d
        }
    }

    static let maxLaunchAttempts = 3
    static let maxConnectAttempts = 8
    /// A process that stayed up this long was not crash-looping.
    static let stableRun: TimeInterval = 60
    static let pendingTimeout: TimeInterval = 20
    /// How long after an app answers a show its window is looked for: past HUDKit's
    /// slide-in, so the window is ordered in and opaque.
    static let showCheckDelay: TimeInterval = 0.5
    /// How long a relaunch waits for the old process to exit, then for the new one to listen.
    nonisolated static let relaunchTimeout: TimeInterval = 10
    static let relaunchPoll: TimeInterval = 0.25

    private(set) var records: [String: Record] = [:]
    /// Every app, in discovery order.
    private(set) var order: [String] = []

    let workspace: WorkspaceControl
    let connector: SocketConnector
    /// Runs work after a delay; tests replace it to step time by hand.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    var now: () -> Date = Date.init
    /// Called whenever an app's health or pushed panel state changes.
    var onChange: ((String) -> Void)?
    /// The contract MacHUD speaks, compared with each app's `hello.hudkit`.
    var contractVersion = HUDKit.version
    /// When a file was last written (the executable a process runs from).
    var fileDate: (URL) -> Date? = { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
    /// A bundle's `CFBundleShortVersionString` as it is on disk now.
    var bundleVersion: (URL) -> String? = AppSupervisor.diskVersion
    /// The executable a bundle on disk launches.
    var bundleExecutable: (URL) -> URL? = AppSupervisor.diskExecutable
    /// Every bundle declaring an app id (set from discovery's duplicates); empty when only
    /// the one in use does.
    var bundles: (String) -> [URL] = { _ in [] }
    /// Where an app's panel is, given its processes and the frames of windows that are not
    /// panels (`widgetFrames`); nil when it cannot tell.
    var windowProbe: (Set<pid_t>, [CGRect]) -> ShowOutcome? = { WindowPresence.probe($0, ignoring: $1) }
    /// The frames of the app's widget instances MacHUD placed (wired to the widget layer).
    var widgetFrames: (String) -> [CGRect] = { _ in [] }
    /// A loud show (a click or summon, not a passing hover) did not reach the screen: app id,
    /// panel id and where it went.
    var onShowMissed: ((String, String, ShowOutcome) -> Void)?
    /// An app connected (or reconnected) and its queued commands went out: app id.
    var onConnected: ((String) -> Void)?
    /// An event other than `state` (`widget`) pushed by an app: app id and the event.
    var onAppEvent: ((String, [String: Any]) -> Void)?

    init(workspace: WorkspaceControl? = nil, connector: SocketConnector? = nil,
         schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil) {
        let workspace = workspace ?? NSWorkspaceControl()
        self.workspace = workspace
        self.connector = connector ?? HUDSocketConnector()
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
        workspace.onLaunch = { [weak self] id in self?.didLaunch(id) }
        workspace.onTerminate = { [weak self] id, pid in self?.didTerminate(id, pid: pid) }
    }

    func record(_ id: String) -> Record? { records[id] }

    /// The app's processes, minus the ones NSWorkspace already announced dead (it can
    /// keep listing them for a moment, and a closed socket often arrives after the
    /// termination notice).
    func livePIDs(_ id: String) -> [pid_t] {
        let listed = workspace.runningPIDs(bundleID: id)
        guard let record = records[id] else { return listed }
        record.deadPIDs.formIntersection(listed)
        return listed.filter { !record.deadPIDs.contains($0) }
    }
    var all: [Record] { order.compactMap { records[$0] } }

    /// Replaces the set of known apps (after a scan). Keeps the state of apps still present,
    /// drops (and disconnects) the rest, then brings every app's health up to date and
    /// launches the `autoLaunch` ones that are not running (unless the user quit them).
    func update(apps: [ExternalApp], autoLaunch: Set<String>) {
        let ids = Set(apps.map(\.id))
        for (id, record) in records where !ids.contains(id) {
            record.subscription?.cancel()
            records[id] = nil
        }
        order = apps.map(\.id)
        for app in apps {
            let record = records[app.id] ?? Record(app: app)
            record.app = app
            record.autoLaunch = autoLaunch.contains(app.id)
            records[app.id] = record
            refresh(app.id)
            if record.autoLaunch, record.health == .notRunning, !record.quitRequested { launch(app.id) }
        }
    }

    /// Changes which apps are kept running without a rescan. An app newly kept running is
    /// launched now unless the user quit it.
    func setAutoLaunch(_ ids: Set<String>) {
        for record in all {
            let wanted = ids.contains(record.app.id)
            guard wanted != record.autoLaunch else { continue }
            record.autoLaunch = wanted
            if wanted, record.health == .notRunning, !record.quitRequested { launch(record.app.id) }
        }
    }

    /// Re-reads process state for one app and (re)connects if it is up but unsubscribed.
    func refresh(_ id: String) {
        guard let record = records[id] else { return }
        let running = !livePIDs(id).isEmpty
        if !running {
            if record.health != .launching {
                set(record, workspace.isInstalled(record.app) ? .notRunning : .notInstalled)
            }
            return
        }
        if record.launchedAt == nil { record.launchedAt = now() }
        if record.isSubscribed { set(record, .running); return }
        set(record, .socketUnreachable)
        connect(id)
    }

    // MARK: - Launch and quit

    enum LaunchError: Error, CustomStringConvertible {
        case unknown(String), notInstalled(String), gaveUp(String, Int)
        var description: String {
            switch self {
            case .unknown(let id): return "no app \(id)"
            case .notInstalled(let id): return "\(id) is not installed"
            case .gaveUp(let id, let n): return "gave up launching \(id) after \(n) attempts"
            }
        }
    }

    /// Launches the app if it is not running. `manual` (an explicit `apps launch`) resets the
    /// attempt count; on-demand launches (panel show, loadouts) count against it. `bundle`
    /// launches that copy instead of the discovered one (a relaunch restarts the bundle the
    /// app was running from).
    @discardableResult
    func launch(_ id: String, manual: Bool = false, bundle: URL? = nil) -> LaunchError? {
        guard let record = records[id] else { return .unknown(id) }
        if manual { record.launchAttempts = 0; record.quitRequested = false }
        if !livePIDs(id).isEmpty { refresh(id); return nil }
        var app = record.app
        if let bundle { app.bundleURL = bundle }
        guard workspace.isInstalled(app) else {
            if bundle == nil { set(record, .notInstalled) }
            return .notInstalled(id)
        }
        if record.launchInFlight || record.health == .launching { return nil }
        guard record.launchAttempts < Self.maxLaunchAttempts else {
            record.lastError = LaunchError.gaveUp(id, record.launchAttempts).description
            return .gaveUp(id, record.launchAttempts)
        }
        record.launchAttempts += 1
        record.launchInFlight = true
        record.quitRequested = false
        set(record, .launching)
        workspace.launch(app) { [weak self] error in
            guard let self, let record = self.records[id] else { return }
            record.launchInFlight = false
            if let error {
                record.lastError = "\(error)"
                self.set(record, .notRunning)
                self.failPending(record, error)
                // A failed launch only retries for apps that are meant to stay up.
                if record.autoLaunch { self.scheduleRelaunch(id) }
            } else {
                // The launch notification normally beats this; cover the case it does not.
                self.refresh(id)
            }
        }
        return nil
    }

    /// Asks the app to quit: `quit` over the socket when reachable, else a terminate event.
    /// An app quit this way is not relaunched even if it is `autoLaunch`.
    func quit(_ id: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let record = records[id] else { completion(.failure(LaunchError.unknown(id))); return }
        record.quitRequested = true
        if record.isSubscribed {
            connector.request(path: record.app.socketPath, command: "quit", args: [:]) { [weak self] result in
                if case .failure = result { _ = self?.workspace.terminate(bundleID: id) }
                completion(.success(true))
            }
        } else {
            completion(.success(workspace.terminate(bundleID: id)))
        }
    }

    private func backoff(_ attempt: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, attempt - 1))))
    }

    private func scheduleRelaunch(_ id: String) {
        guard let record = records[id], !record.relaunchScheduled,
              record.launchAttempts < Self.maxLaunchAttempts else {
            if let record = records[id], record.launchAttempts >= Self.maxLaunchAttempts {
                record.lastError = LaunchError.gaveUp(id, record.launchAttempts).description
                onChange?(id)
            }
            return
        }
        record.relaunchScheduled = true
        // 2 s after the first launch dies, 4 s after the second; the third is final.
        schedule(backoff(record.launchAttempts + 1, base: 1, cap: 30)) { [weak self] in
            guard let self, let record = self.records[id] else { return }
            record.relaunchScheduled = false
            guard !record.quitRequested else { return }
            self.launch(id)
        }
    }

    // MARK: - Workspace events

    func didLaunch(_ id: String) {
        guard let record = records[id] else { return }
        // Opened again (by hand too): an earlier quit no longer keeps it down.
        record.quitRequested = false
        record.launchInFlight = false
        record.launchedAt = now()
        record.connectAttempts = 0
        if !record.isSubscribed { set(record, .socketUnreachable) }
        // Give the app a moment to open its socket.
        schedule(0.3) { [weak self] in self?.connect(id) }
    }

    func didTerminate(_ id: String, pid: pid_t) {
        guard let record = records[id] else { return }
        record.deadPIDs.insert(pid)
        record.relaunchAwaiting.remove(pid)
        // Another instance may still be running.
        guard livePIDs(id).isEmpty else { return }
        record.subscription?.cancel()
        record.subscription = nil
        record.connecting = false
        record.launchInFlight = false
        let ranFor = record.launchedAt.map { now().timeIntervalSince($0) } ?? 0
        record.launchedAt = nil
        if ranFor >= Self.stableRun { record.launchAttempts = 0 }
        for key in record.panels.keys { record.panels[key]?.visible = false }
        record.hello = nil
        record.showChecks = [:]
        failPending(record, LaunchError.unknown("\(id) quit"))
        set(record, workspace.isInstalled(record.app) ? .notRunning : .notInstalled)
        if record.autoLaunch && !record.quitRequested { scheduleRelaunch(id) }
    }

    // MARK: - Socket

    func connect(_ id: String) {
        guard let record = records[id], !record.isSubscribed, !record.connecting else { return }
        guard !livePIDs(id).isEmpty else {
            // Nothing to connect to after all: settle the health instead of leaving it
            // at socketUnreachable.
            if record.health == .socketUnreachable || record.health == .running { refresh(id) }
            return
        }
        record.connecting = true
        record.connectAttempts += 1
        connector.subscribe(path: record.app.socketPath, onEvent: { [weak self] event in
            self?.handle(event, from: id)
        }, onClose: { [weak self] in
            self?.subscriptionClosed(id)
        }, completion: { [weak self] result in
            guard let self, let record = self.records[id] else {
                if case .success(let sub) = result { sub.cancel() }
                return
            }
            record.connecting = false
            switch result {
            case .success(let sub):
                record.subscription = sub
                record.connectAttempts = 0
                record.lastError = nil
                self.set(record, .running)
                self.seedState(id)
                self.flushPending(record)
                self.askHello(id)
                self.onConnected?(id)
            case .failure(let error):
                record.lastError = "\(error)"
                self.set(record, .socketUnreachable)
                guard record.connectAttempts < Self.maxConnectAttempts else { return }
                // 0.5 s, 1 s, 2 s ... capped at 8 s.
                self.schedule(self.backoff(record.connectAttempts, base: 0.5, cap: 8)) { [weak self] in
                    self?.connect(id)
                }
            }
        })
    }

    private func subscriptionClosed(_ id: String) {
        guard let record = records[id] else { return }
        record.subscription = nil
        guard !livePIDs(id).isEmpty else { return }
        // The process is still up: its server restarted or dropped us.
        set(record, .socketUnreachable)
        record.connectAttempts = 0
        schedule(0.5) { [weak self] in self?.connect(id) }
    }

    /// `subscribe` pushes changes only; ask for the current state once.
    private func seedState(_ id: String) {
        guard let record = records[id] else { return }
        connector.request(path: record.app.socketPath, command: "state", args: [:]) { [weak self] result in
            if case .success(let response) = result { self?.handle(response, from: id) }
        }
    }

    /// The contract and version the running process was built with.
    private func askHello(_ id: String) {
        guard let record = records[id] else { return }
        record.hello = nil
        connector.request(path: record.app.socketPath, command: "hello", args: [:]) { [weak self] result in
            guard case .success(let reply) = result, reply["ok"] as? Bool != false,
                  let record = self?.records[id] else { return }
            record.hello = AppHello(reply: reply)
            self?.onChange?(id)
        }
    }

    func handle(_ event: [String: Any], from id: String) {
        if let name = event["event"] as? String, name != "state" {
            guard let record = records[id] else { return }
            // The app is terminating on purpose (its own Quit, ⌘Q, `quit`): the user quit it,
            // so no relaunch follows its exit. A kill or crash sends nothing and is relaunched.
            // Opening it again clears this (`didLaunch`).
            if name == "quitting" { record.quitRequested = true; return }
            onAppEvent?(id, event)
            return
        }
        guard let record = records[id], let panels = event["panels"] as? [[String: Any]] else { return }
        var changed = false
        for p in panels {
            guard let panelID = p["id"] as? String else { continue }
            var state = record.panels[panelID] ?? HUDPanelState(id: panelID, visible: false)
            if let visible = p["visible"] as? Bool { state.visible = visible }
            if !state.visible, record.showChecks.removeValue(forKey: panelID) != nil { changed = true }
            if let mode = (p["mode"] as? String).flatMap(HUDPanelMode.init(rawValue:)) { state.mode = mode }
            // Only as fresh as the last report: a report without one (HUDKit's own pushes)
            // forgets it rather than keep a stale frame.
            let frame = Self.frame(p["frame"])
            if record.frames[panelID] != frame {
                record.frames[panelID] = frame
                changed = true
            }
            state.badge = p["badge"].map { "\($0)" }
            state.status = p["status"].map { "\($0)" }
            if record.panels[panelID] != state { record.panels[panelID] = state; changed = true }
        }
        if changed { onChange?(id) }
    }

    /// An optional `frame` in a panel's state: `[x, y, w, h]`, `{x, y, w, h}` or `"x,y,w,h"`.
    nonisolated static func frame(_ raw: Any?) -> CGRect? {
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        if let a = raw as? [Any], a.count == 4 {
            let n = a.compactMap(num)
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
        }
        if let d = raw as? [String: Any], let x = num(d["x"]), let y = num(d["y"]),
           let w = num(d["w"] ?? d["width"]), let h = num(d["h"] ?? d["height"]) {
            return CGRect(x: x, y: y, width: w, height: h)
        }
        if let s = raw as? String { return HUDPanelTransition.parseAnchor(s) }
        return nil
    }

    /// Records a visibility change we just asked for, until the app confirms it.
    func assume(_ id: String, panel: String, visible: Bool) {
        guard let record = records[id] else { return }
        var state = record.panels[panel] ?? HUDPanelState(id: panel, visible: visible)
        state.visible = visible
        record.panels[panel] = state
        if !visible { record.showChecks[panel] = nil }
        onChange?(id)
    }

    // MARK: - Health

    /// Whether the running app is behind the bundle it runs from (rebuilt since it started,
    /// or a different version on disk than `hello` reported: a relaunch picks that up) or
    /// behind MacHUD's contract, and whether another bundle declaring the id holds a newer
    /// build (informational: a relaunch never switches copies). nil while it is not running.
    func buildStatus(_ id: String) -> AppBuildStatus? {
        guard let record = records[id] else { return nil }
        let live = Set(livePIDs(id))
        guard !live.isEmpty else { return nil }
        let processes = workspace.processes(bundleID: id).filter { live.contains($0.pid) }
        // The oldest process decides: it is the one that may be running an old build.
        let oldest = processes.min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
        let running = oldest?.bundleURL ?? record.app.bundleURL
        let built = (oldest?.executableURL ?? bundleExecutable(running)).flatMap(fileDate)
        var status = AppBuildStatus()
        status.outdated = AppBuildStatus.outdatedReason(launched: oldest?.launchDate, built: built,
                                                        running: record.hello?.version, onDisk: bundleVersion(running))
        let copies = bundles(id).filter { !Self.sameBundle($0, running) }.compactMap { bundle -> AppBuildStatus.Copy? in
            guard let date = bundleExecutable(bundle).flatMap(fileDate) else { return nil }
            return AppBuildStatus.Copy(path: bundle.path, version: bundleVersion(bundle), built: date)
        }
        if let newest = copies.max(by: { $0.built < $1.built }),
           newest.built.timeIntervalSince(built ?? .distantPast) > AppBuildStatus.tolerance {
            status.newerCopy = newest
        }
        if let contract = record.hello?.contract {
            status.contract = AppBuildStatus.contract(app: contract, machud: contractVersion)
        }
        return status
    }

    /// Ids of the running apps a relaunch would update (their own bundle is newer than the process).
    var outdatedIDs: [String] { order.filter { buildStatus($0)?.outdated != nil } }

    /// `CFBundleShortVersionString` read from the Info.plist on disk (not `Bundle`, which
    /// caches a bundle's Info.plist for the life of the process).
    nonisolated static func diskVersion(_ bundle: URL) -> String? {
        infoPlist(bundle)?["CFBundleShortVersionString"] as? String
    }

    /// The executable a bundle on disk launches (`CFBundleExecutable`).
    nonisolated static func diskExecutable(_ bundle: URL) -> URL? {
        (infoPlist(bundle)?["CFBundleExecutable"] as? String).map { bundle.appendingPathComponent("Contents/MacOS/\($0)") }
    }

    private nonisolated static func infoPlist(_ bundle: URL) -> [String: Any]? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    nonisolated static func sameBundle(_ a: URL, _ b: URL) -> Bool {
        ExternalAppCatalog.canonicalPath(a) == ExternalAppCatalog.canonicalPath(b)
    }

    /// After a show the app answered: once its window has had time to appear, records
    /// whether one of the app's windows is on screen on the active desktop. The window list
    /// decides; the app's `onActiveSpace` hint in its show reply (HUDKit 0.3+) is used only
    /// when the window list cannot tell. A `loud` show that missed is reported through
    /// `onShowMissed`; a passing hover only records it.
    func verifyShow(_ id: String, panel: String, loud: Bool, hint: Bool? = nil) {
        schedule(Self.showCheckDelay) { [weak self] in
            // A parked panel is mostly past the screen edge, its orb under the window filter.
            guard let self, let record = self.records[id], record.health == .running,
                  let state = record.panels[panel], state.visible, state.mode != .parked else { return }
            let outcome = self.windowProbe(Set(self.livePIDs(id)), self.widgetFrames(id)) ?? hint.map { $0 ? .onScreen : .anotherDesktop }
            guard let outcome else { return }
            if record.showChecks[panel] != outcome {
                record.showChecks[panel] = outcome
                self.onChange?(id)
            }
            if loud, !outcome.isOnScreen { self.onShowMissed?(id, panel, outcome) }
        }
    }

    // MARK: - Relaunch

    enum RelaunchError: Error, CustomStringConvertible {
        case busy(String), bundleMissing(String, String), didNotQuit(String), launch(LaunchError)
        /// The new process quit, failed to launch or did not listen in time: id and why.
        case didNotListen(String, String)
        var description: String {
            switch self {
            case .busy(let id): return "\(id) is already relaunching"
            case .bundleMissing(let id, let path):
                return "\(path) is gone (a build in progress?); \(id) was left running"
            case .didNotQuit(let id): return "\(id) did not quit, even when forced"
            case .launch(let error): return error.description
            case .didNotListen(let id, let why): return "\(id) did not come back: \(why)"
            }
        }
    }

    /// How long a forced quit gets to take effect.
    static let forceQuitGrace: TimeInterval = 3

    /// Quits the app, waits for its process to exit, launches the bundle it was running from
    /// again (as `apps launch`; never another copy declaring the id) and waits for it to
    /// listen. Completes with the new process's pid and health, or why it is not back. An
    /// app that is not running is just launched.
    ///
    /// The bundle must still be there before anything is quit (a build may have removed it).
    /// An app that ignores the quit for `relaunchTimeout` is force-terminated. The launch
    /// waits until the old processes' terminations were announced, so a late notice cannot
    /// mark the new instance stopped. Every outcome clears `quitRequested`, so an
    /// `autoLaunch` app stays supervised.
    func relaunch(_ id: String, completion: @escaping (Result<(pid: pid_t, health: Health), RelaunchError>) -> Void) {
        guard let record = records[id] else { completion(.failure(.launch(.unknown(id)))); return }
        guard !record.relaunching else { completion(.failure(.busy(id))); return }
        let old = Set(livePIDs(id))
        let bundle = workspace.processes(bundleID: id).first { old.contains($0.pid) }?.bundleURL
        if !old.isEmpty {
            var app = record.app
            if let bundle { app.bundleURL = bundle }
            guard workspace.isInstalled(app) else {
                completion(.failure(.bundleMissing(id, app.bundleURL.path)))
                return
            }
        }
        record.relaunching = true
        record.relaunchAwaiting = old
        let finish: (Result<(pid: pid_t, health: Health), RelaunchError>) -> Void = { [weak record] result in
            record?.relaunching = false
            record?.relaunchAwaiting = []
            record?.quitRequested = false
            completion(result)
        }
        let start = { [weak self] in
            guard let self else { return }
            if let error = self.launch(id, manual: true, bundle: bundle) { finish(.failure(.launch(error))); return }
            self.awaitListening(id, old: old, deadline: self.now().addingTimeInterval(Self.relaunchTimeout), finish)
        }
        guard !old.isEmpty else { start(); return }
        quit(id) { [weak self] _ in
            guard let self else { return }
            self.awaitExit(id, old: old, deadline: self.now().addingTimeInterval(Self.relaunchTimeout)) { [weak self] exited in
                guard let self else { return }
                if exited { start(); return }
                self.workspace.forceTerminate(pids: old.intersection(self.livePIDs(id)))
                self.awaitExit(id, old: old, deadline: self.now().addingTimeInterval(Self.forceQuitGrace)) { exited in
                    if exited { start() } else { finish(.failure(.didNotQuit(id))) }
                }
            }
        }
    }

    /// Done once the old processes are gone and their terminations were announced; at the
    /// deadline, gone is enough (a missed notice cannot hold a relaunch forever).
    private func awaitExit(_ id: String, old: Set<pid_t>, deadline: Date, _ done: @escaping (Bool) -> Void) {
        let gone = old.isDisjoint(with: workspace.runningPIDs(bundleID: id))
        let announced = records[id]?.relaunchAwaiting.isEmpty ?? true
        if gone && (announced || now() >= deadline) { done(true); return }
        guard now() < deadline else { done(false); return }
        schedule(Self.relaunchPoll) { [weak self] in self?.awaitExit(id, old: old, deadline: deadline, done) }
    }

    /// Succeeds once a new process is subscribed; fails when the launch failed or the new
    /// process quit (health back to `notRunning` with nothing in flight), or at the deadline.
    private func awaitListening(_ id: String, old: Set<pid_t>, deadline: Date,
                                _ done: @escaping (Result<(pid: pid_t, health: Health), RelaunchError>) -> Void) {
        guard let record = records[id] else { done(.failure(.launch(.unknown(id)))); return }
        let fresh = livePIDs(id).first { !old.contains($0) }
        if let fresh, record.health == .running { done(.success((fresh, .running))); return }
        let stopped = (record.health == .notRunning || record.health == .notInstalled) && !record.launchInFlight
        if stopped || now() >= deadline {
            let why = record.lastError ?? (stopped ? "it quit right after launching"
                                                   : "not listening after \(Int(Self.relaunchTimeout)) s")
            done(.failure(.didNotListen(id, why)))
            return
        }
        schedule(Self.relaunchPoll) { [weak self] in self?.awaitListening(id, old: old, deadline: deadline, done) }
    }

    // MARK: - Commands

    /// Sends a command to the app: now if subscribed, else once it is (launching it if it
    /// is not running). `completion` may be nil for fire-and-forget.
    func send(_ id: String, command: String, args: [String: String],
              completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard let record = records[id] else { completion?(.failure(LaunchError.unknown(id))); return }
        if record.isSubscribed {
            connector.request(path: record.app.socketPath, command: command, args: args) { result in
                completion?(result)
            }
            return
        }
        record.pending.append((command, args, now().addingTimeInterval(Self.pendingTimeout), completion))
        if livePIDs(id).isEmpty {
            if let error = launch(id) { failPending(record, error) }
        } else {
            connect(id)
        }
    }

    private func flushPending(_ record: Record) {
        let due = record.pending
        record.pending = []
        let t = now()
        for item in due {
            guard item.deadline > t else { item.completion?(.failure(HUDSocketError.timeout)); continue }
            connector.request(path: record.app.socketPath, command: item.command, args: item.args) { result in
                item.completion?(result)
            }
        }
    }

    private func failPending(_ record: Record, _ error: Error) {
        let due = record.pending
        record.pending = []
        for item in due { item.completion?(.failure(error)) }
    }

    private func set(_ record: Record, _ health: Health) {
        guard record.health != health else { return }
        record.health = health
        onChange?(record.app.id)
    }
}

// MARK: - Real implementations

@MainActor
final class NSWorkspaceControl: WorkspaceControl {
    var onLaunch: ((String) -> Void)?
    var onTerminate: ((String, pid_t) -> Void)?
    private var observation: NSKeyValueObservation?

    /// KVO on `runningApplications`, not the didLaunch/didTerminate notifications: those
    /// are not posted for LSUIElement (menu bar) apps, which most MacHUD siblings are.
    init() {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            // Only incremental changes: a wholesale replacement would read as every app
            // quitting and relaunching.
            guard change.kind == .insertion || change.kind == .removal else { return }
            let launched = (change.newValue ?? []).compactMap { app in app.bundleIdentifier.map { ($0, app.processIdentifier) } }
            let ended = (change.oldValue ?? []).compactMap { app in app.bundleIdentifier.map { ($0, app.processIdentifier) } }
            let box = UncheckedBox((launched, ended))
            let deliver = {
                MainActor.assumeIsolated {
                    for (id, _) in box.value.0 { self?.onLaunch?(id) }
                    for (id, pid) in box.value.1 { self?.onTerminate?(id, pid) }
                }
            }
            if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
        }
    }

    func runningPIDs(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
    }

    func processes(bundleID: String) -> [AppProcess] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.map {
            AppProcess(pid: $0.processIdentifier, launchDate: $0.launchDate, bundleURL: $0.bundleURL,
                       executableURL: $0.executableURL)
        }
    }

    func isInstalled(_ app: ExternalApp) -> Bool {
        FileManager.default.fileExists(atPath: app.bundleURL.path)
    }

    func launch(_ app: ExternalApp, completion: @escaping (Error?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func terminate(bundleID: String) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        apps.forEach { $0.terminate() }
        return !apps.isEmpty
    }

    func forceTerminate(pids: Set<pid_t>) {
        for pid in pids { NSRunningApplication(processIdentifier: pid)?.forceTerminate() }
    }
}

/// `HUDSocketClient` off the main thread, results back on it.
@MainActor
final class HUDSocketConnector: SocketConnector {
    /// Short: a sibling that does not answer within this is treated as unreachable.
    var timeout: TimeInterval = 3
    private let queue = DispatchQueue(label: "machud.external", attributes: .concurrent)
    /// One serial queue per socket, so requests reach an app in the order they were made
    /// (`panel frame` before `panel show`, a quick show before its hide) while a slow app
    /// never holds up another.
    private var requestQueues: [String: DispatchQueue] = [:]

    private func requestQueue(_ path: String) -> DispatchQueue {
        if let q = requestQueues[path] { return q }
        let q = DispatchQueue(label: "machud.external.\((path as NSString).lastPathComponent)", target: queue)
        requestQueues[path] = q
        return q
    }

    func subscribe(path: String, onEvent: @escaping ([String: Any]) -> Void, onClose: @escaping () -> Void,
                   completion: @escaping (Result<SocketSubscription, Error>) -> Void) {
        let client = HUDSocketClient(path: path, timeout: timeout)
        let events = UncheckedBox(onEvent), closed = UncheckedBox(onClose), done = UncheckedBox(completion)
        queue.async {
            let result = Result<SocketSubscription, Error> {
                try client.subscribe(events: ["state", "widget"], onEvent: { event in
                    let box = UncheckedBox(event)
                    DispatchQueue.main.async { events.value(box.value) }
                }, onClose: {
                    DispatchQueue.main.async { closed.value() }
                })
            }
            let box = UncheckedBox(result)
            DispatchQueue.main.async { done.value(box.value) }
        }
    }

    func request(path: String, command: String, args: [String: String],
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let client = HUDSocketClient(path: path, timeout: timeout)
        let done = UncheckedBox(completion)
        requestQueue(path).async {
            let result = Result<[String: Any], Error> { try client.request(command, args: args) }
            let box = UncheckedBox(result)
            DispatchQueue.main.async { done.value(box.value) }
        }
    }
}

/// Carries a non-Sendable value across a queue hop we know is safe (handed off, not shared).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
