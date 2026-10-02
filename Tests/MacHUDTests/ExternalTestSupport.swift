import AppKit
import HUDKit
@testable import MacHUDCore

/// Hand-cranked workspace: tests decide what runs and fire the launch/terminate events.
@MainActor
final class FakeWorkspace: WorkspaceControl {
    var onLaunch: ((String) -> Void)?
    var onTerminate: ((String, pid_t) -> Void)?
    var running: [String: [pid_t]] = [:]
    var installed: Set<String> = []
    var launches: [String] = []
    var launchError: Error?
    var terminated: [String] = []

    /// Launch dates and bundles per pid; a running pid without an entry has none.
    var processInfo: [pid_t: AppProcess] = [:]

    func runningPIDs(bundleID: String) -> [pid_t] { running[bundleID] ?? [] }
    func processes(bundleID: String) -> [AppProcess] {
        (running[bundleID] ?? []).map { processInfo[$0] ?? AppProcess(pid: $0) }
    }
    func isInstalled(_ app: ExternalApp) -> Bool { installed.contains(app.id) }
    /// Called as each launch is asked for, before it completes.
    var onLaunchCall: (() -> Void)?

    /// The bundle each launch asked for.
    var launchedBundles: [URL] = []

    func launch(_ app: ExternalApp, completion: @escaping (Error?) -> Void) {
        launches.append(app.id)
        launchedBundles.append(app.bundleURL)
        onLaunchCall?()
        completion(launchError)
    }
    func terminate(bundleID: String) -> Bool {
        terminated.append(bundleID)
        return running.removeValue(forKey: bundleID) != nil
    }

    /// The process came up (as NSWorkspace would report it).
    func start(_ id: String, pid: pid_t = 4242) { running[id] = [pid]; onLaunch?(id) }
    /// The process went away. `stale` keeps it listed during the notification, as
    /// NSRunningApplication does.
    func stop(_ id: String, stale: Bool = false) {
        let pid = running[id]?.first ?? 0
        if !stale { running[id] = nil }
        onTerminate?(id, pid)
        running[id] = nil
    }
}

final class FakeSubscription: SocketSubscription {
    var cancelled = false
    func cancel() { cancelled = true }
}

/// Socket stand-in: `reachable` decides whether subscribe succeeds; requests are recorded.
@MainActor
final class FakeConnector: SocketConnector {
    var reachable: Set<String> = []
    var requests: [(path: String, command: String, args: [String: String])] = []
    var onEvents: [String: ([String: Any]) -> Void] = [:]
    var onCloses: [String: () -> Void] = [:]
    var subscriptions: [FakeSubscription] = []
    var stateReply: [String: Any] = ["ok": true, "panels": []]
    /// Replies for other commands, by command name (default `{"ok": true}`).
    var replies: [String: [String: Any]] = [:]
    /// Commands that fail at the socket level.
    var failing: Set<String> = []
    /// Holds completions instead of answering, when set (to test replies arriving later).
    var deferred: [(command: String, reply: () -> Void)]?

    func subscribe(path: String, onEvent: @escaping ([String: Any]) -> Void, onClose: @escaping () -> Void,
                   completion: @escaping (Result<SocketSubscription, Error>) -> Void) {
        guard reachable.contains(path) else { completion(.failure(HUDSocketError.notRunning(path, ECONNREFUSED))); return }
        onEvents[path] = onEvent
        onCloses[path] = onClose
        let sub = FakeSubscription()
        subscriptions.append(sub)
        completion(.success(sub))
    }

    func request(path: String, command: String, args: [String: String],
                 completion: @escaping (Result<[String: Any], Error>) -> Void) {
        requests.append((path, command, args))
        let answer: () -> Void = { [self] in
            if failing.contains(command) { completion(.failure(HUDSocketError.timeout)); return }
            completion(.success(command == "state" ? stateReply : replies[command] ?? ["ok": true]))
        }
        if deferred != nil, command != "state" { deferred?.append((command, answer)) } else { answer() }
    }
}

/// Collects scheduled work so tests can step time.
@MainActor
final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var queue: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void {
        { [unowned self] delay, work in self.queue.append((delay, work)) }
    }

    /// Runs everything queued so far (not what that work schedules), advancing the clock.
    @discardableResult
    func runQueued() -> [TimeInterval] {
        let due = queue
        queue = []
        for item in due { now += item.delay; item.work() }
        return due.map(\.delay)
    }
}

enum FakeBundles {
    /// Writes `<dir>/<name>.app/Contents/Resources/machud.json`.
    @discardableResult
    static func make(in dir: URL, name: String, json: String) throws -> URL {
        let app = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: resources.appendingPathComponent("machud.json"))
        return app
    }

    static func manifest(id: String, name: String, socket: String, panels: [String]) -> String {
        let list = panels.map { #"{"id": "\#($0)", "title": "\#($0.capitalized)", "verbs": ["show", "hide", "toggle", "frame"]}"# }
        return #"{"id": "\#(id)", "name": "\#(name)", "socket": "\#(socket)", "panels": [\#(list.joined(separator: ","))]}"#
    }

    static func tempDir(_ tag: String) -> URL {
        // Short: socket paths inside it must fit in sun_path.
        let dir = URL(fileURLWithPath: "/tmp/gs-\(tag)-\(getpid())-\(Int.random(in: 0..<100_000))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@MainActor
func spin(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return condition()
}
