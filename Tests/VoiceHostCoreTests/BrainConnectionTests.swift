import BrainKit
import XCTest
@testable import VoiceHostCore

/// A companion that answers over a stubbed URL session: `GET /v1/session` returns the current
/// snapshot, `POST /v1/runtime` switches it (or refuses during a turn, as the companion does).
private final class FakeCompanion: URLProtocol, @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var path: String
        var body: [String: String]?
    }

    private static let lock = NSLock()
    private static var _runtime = "codex"
    private static var _status = "idle"
    private static var _revision = 1
    private static var _requests: [Request] = []

    static func reset(runtime: String, status: String = "idle") {
        lock.withLock {
            _runtime = runtime
            _status = status
            _revision = 1
            _requests = []
        }
    }

    static func setStatus(_ status: String) {
        lock.withLock {
            _status = status
            _revision += 1
        }
    }

    static var requests: [Request] { lock.withLock { _requests } }
    static var runtime: String { lock.withLock { _runtime } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let (status, object): (Int, [String: Any]) = Self.lock.withLock {
            Self._requests.append(Request(method: method, path: path, body: body))
            if method == "POST", path == "/v1/runtime", let runtime = body?["runtime"] {
                guard !["running", "approval"].contains(Self._status) else {
                    return (409, ["error": "Finish or interrupt the active turn before switching runtime"])
                }
                Self._runtime = runtime
                Self._revision += 1
            }
            return (200, ["threadId": NSNull(), "turnId": NSNull(), "status": Self._status, "output": "",
                          "progress": "Ready", "approvals": [], "error": NSNull(), "revision": Self._revision,
                          "instanceId": "companion", "requestId": NSNull(), "runtime": Self._runtime])
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor
private final class StubProcess: ServiceProcess {
    let processIdentifier: Int32 = 4242
    let onOutput: @MainActor (String) -> Void
    init(onOutput: @escaping @MainActor (String) -> Void) { self.onOutput = onOutput }
    func terminate() {}
}

@MainActor
private final class StubLauncher: ProcessLaunching {
    var specs: [ProcessSpec] = []
    var processes: [StubProcess] = []

    func launch(_ spec: ProcessSpec, onOutput: @escaping @Sendable @MainActor (String) -> Void,
                onExit: @escaping @Sendable @MainActor (Int32) -> Void) throws -> ServiceProcess {
        specs.append(spec)
        let process = StubProcess(onOutput: onOutput)
        processes.append(process)
        return process
    }
}

/// Delayed work that runs only when the test says so.
@MainActor
private final class SteppedScheduler: ServiceScheduling {
    final class Item: ScheduledAction {
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func cancel() { cancelled = true }
    }

    private var items: [Item] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScheduledAction {
        let item = Item(action)
        items.append(item)
        return item
    }

    /// Runs everything scheduled so far: the service's debounce, the connection's settle, and
    /// the supervisor's timers (no-ops once the companion is ready).
    func runPending() {
        let due = items
        items = []
        for item in due where !item.cancelled { item.action() }
    }
}

@MainActor
final class BrainConnectionTests: XCTestCase {
    private var root: URL!
    private var launcher: StubLauncher!
    private var scheduler: SteppedScheduler!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brain-connection-\(UUID().uuidString)")
        let companion = root.appendingPathComponent("Companion")
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace"), withIntermediateDirectories: true)
        try Data().write(to: companion.appendingPathComponent("server.mjs"))
        launcher = StubLauncher()
        scheduler = SteppedScheduler()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeConnection() -> BrainConnection {
        let companion = root.appendingPathComponent("Companion")
        let service = BrainService(
            launcher: launcher, scheduler: scheduler,
            locator: {
                ExecutableLocator(path: "/usr/bin", home: "/Users/test",
                                  isExecutable: { $0 == "/opt/homebrew/bin/node" || $0 == "/opt/homebrew/bin/codex" },
                                  contentsOfDirectory: { _ in [] })
            },
            nodeVersion: { _ in "v22.3.0" }, companionDirectory: { companion }, environment: [:])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeCompanion.self]
        let session = URLSession(configuration: configuration)
        return BrainConnection(service: service, scheduler: scheduler, settle: 1) {
            AgentSessionClient(endpoint: $0.url, token: $0.token, session: session)
        }
    }

    private func launch(_ runtime: AgentRuntime) -> BrainServiceConfiguration {
        BrainServiceConfiguration(
            runtime: runtime, workingDirectory: root.appendingPathComponent("workspace").path,
            stateDirectory: root.appendingPathComponent("state").path, port: 8791)
    }

    /// Starts the companion: the token it writes, then its ready line; waits for the client.
    private func start(_ connection: BrainConnection, _ runtime: AgentRuntime) async throws {
        var health: [BrainHealth] = []
        connection.onHealthChanged = { health.append($0) }
        connection.configure(launch(runtime))
        let token = root.appendingPathComponent("state/token")
        try String(repeating: "a", count: 64).write(to: token, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: token.path)
        launcher.processes.last?.onOutput("Brain companion ready at http://127.0.0.1:8791")
        try await waitUntil { health.last == .ready }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath,
                           line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out", file: file, line: line)
    }

    private var runtimeRequests: [FakeCompanion.Request] {
        FakeCompanion.requests.filter { $0.path == "/v1/runtime" }
    }

    func testARuntimeChangeInSettingsReachesTheRunningCompanion() async throws {
        FakeCompanion.reset(runtime: "codex")
        let connection = makeConnection()
        try await start(connection, .codex)
        scheduler.runPending()
        XCTAssertEqual(connection.activeRuntime, "codex")
        XCTAssertTrue(runtimeRequests.isEmpty)

        connection.configure(launch(.mclaude))
        // Before the change settles nothing is sent: it may yet restart the companion.
        XCTAssertTrue(runtimeRequests.isEmpty)
        scheduler.runPending()
        try await waitUntil { FakeCompanion.runtime == "mclaude" }
        XCTAssertEqual(runtimeRequests, [.init(method: "POST", path: "/v1/runtime", body: ["runtime": "mclaude"])])
        // The same process: a runtime-only change is not a restart, and the next start uses it.
        XCTAssertEqual(launcher.specs.count, 1)
        try await waitUntil { connection.activeRuntime == "mclaude" }
    }

    func testACompanionRunningAnotherRuntimeIsSwitchedWhenItConnects() async throws {
        // The live bug: settings say mclaude, the companion reports codex.
        FakeCompanion.reset(runtime: "codex")
        let connection = makeConnection()
        try await start(connection, .mclaude)
        scheduler.runPending()
        try await waitUntil { FakeCompanion.runtime == "mclaude" }
        XCTAssertEqual(runtimeRequests.map(\.body), [["runtime": "mclaude"]])
    }

    func testTheSwitchWaitsForTheTurnToEnd() async throws {
        FakeCompanion.reset(runtime: "codex", status: "running")
        let connection = makeConnection()
        try await start(connection, .codex)
        scheduler.runPending()
        connection.configure(launch(.claude))
        scheduler.runPending()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(runtimeRequests.isEmpty, "no switch is asked during a turn")
        FakeCompanion.setStatus("completed")
        // The client's poll sees the turn end; the switch follows.
        try await waitUntil { FakeCompanion.runtime == "claude" }
        XCTAssertEqual(runtimeRequests.map(\.body), [["runtime": "claude"]])
    }
}
