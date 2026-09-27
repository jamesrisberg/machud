import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class AppSupervisorTests: XCTestCase {
    private let id = "xyz.wormhole"
    private let socket = "/tmp/wormhole-test.sock"
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var supervisor: AppSupervisor!
    private var changes: [String] = []

    private var app: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: id, name: "Wormhole", socket: socket,
                                          panels: [HUDManifest.Panel(id: "portal", title: "Portal")]),
                    bundleURL: URL(fileURLWithPath: "/Applications/Wormhole.app"))
    }

    override func setUpWithError() throws {
        workspace = FakeWorkspace()
        workspace.installed = [id]
        connector = FakeConnector()
        clock = ManualClock()
        supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned clock] in clock!.now }
        supervisor.onChange = { [unowned self] in self.changes.append($0) }
    }

    private var health: AppSupervisor.Health? { supervisor.record(id)?.health }

    func testNotInstalledAndNotRunning() {
        workspace.installed = []
        supervisor.update(apps: [app], autoLaunch: [])
        XCTAssertEqual(health, .notInstalled)
        XCTAssertEqual(supervisor.launch(id)?.description, "\(id) is not installed")
        workspace.installed = [id]
        supervisor.refresh(id)
        XCTAssertEqual(health, .notRunning)
    }

    func testRunningAppGetsSubscribedAndStateCached() {
        workspace.running[id] = [100]
        connector.reachable = [socket]
        connector.stateReply = ["ok": true, "panels": [["id": "portal", "visible": true, "mode": "compact", "badge": 3]]]
        supervisor.update(apps: [app], autoLaunch: [])
        XCTAssertEqual(health, .running)
        XCTAssertEqual(connector.requests.map(\.command), ["state"], "state is seeded after subscribing")
        XCTAssertEqual(supervisor.record(id)?.panels["portal"], HUDPanelState(id: "portal", visible: true, mode: .compact, badge: "3"))

        // Pushed partial update.
        connector.onEvents[socket]?(["event": "state", "panels": [["id": "portal", "visible": false, "mode": "compact"]]])
        XCTAssertEqual(supervisor.record(id)?.panels["portal"]?.visible, false)
        XCTAssertNil(supervisor.record(id)?.panels["portal"]?.badge)
        XCTAssertTrue(changes.contains(id))
    }

    func testSocketUnreachableRetriesWithBackoffThenReconnects() {
        workspace.running[id] = [100]
        supervisor.update(apps: [app], autoLaunch: [])
        XCTAssertEqual(health, .socketUnreachable)
        XCTAssertEqual(clock.runQueued(), [0.5])
        XCTAssertEqual(clock.runQueued(), [1])
        XCTAssertEqual(clock.runQueued(), [2])
        connector.reachable = [socket]
        clock.runQueued()
        XCTAssertEqual(health, .running)
        XCTAssertTrue(clock.queue.isEmpty)

        // The server drops us while the process lives: reconnect.
        connector.reachable = []
        connector.onCloses[socket]?()
        XCTAssertEqual(health, .socketUnreachable)
        connector.reachable = [socket]
        clock.runQueued()
        XCTAssertEqual(health, .running)
    }

    func testOnDemandLaunchQueuesCommandUntilSocketIsUp() {
        supervisor.update(apps: [app], autoLaunch: [])
        var reply: Result<[String: Any], Error>?
        supervisor.send(id, command: "panel", args: ["action": "show", "id": "portal"]) { reply = $0 }
        XCTAssertEqual(workspace.launches, [id])
        XCTAssertEqual(health, .launching)
        XCTAssertNil(reply)

        connector.reachable = [socket]
        workspace.start(id)
        XCTAssertEqual(health, .socketUnreachable)
        clock.runQueued()                                    // the post-launch connect
        XCTAssertEqual(health, .running)
        XCTAssertEqual(connector.requests.map(\.command), ["state", "panel"])
        XCTAssertEqual(connector.requests.last?.args["action"], "show")
        if case .success = reply {} else { XCTFail("queued command should have been sent") }
    }

    func testAutoLaunchRelaunchesWithBackoffAndGivesUpAfterThree() {
        supervisor.update(apps: [app], autoLaunch: [id])
        XCTAssertEqual(workspace.launches.count, 1)
        // Crash loop: each launch comes up and dies at once.
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            workspace.start(id)
            clock.queue.removeAll()                          // drop the connect attempt
            workspace.stop(id)
            delays += clock.runQueued()
        }
        XCTAssertEqual(workspace.launches.count, AppSupervisor.maxLaunchAttempts)
        XCTAssertEqual(delays, [2, 4], "backoff doubles; the third crash is not relaunched")
        XCTAssertEqual(health, .notRunning)
        XCTAssertTrue(supervisor.record(id)?.lastError?.contains("gave up") ?? false)
        XCTAssertNotNil(supervisor.launch(id), "on-demand launches are capped too")

        // An explicit `apps launch` resets the count.
        XCTAssertNil(supervisor.launch(id, manual: true))
        XCTAssertEqual(workspace.launches.count, AppSupervisor.maxLaunchAttempts + 1)
    }

    func testStableRunResetsAttemptsAndQuitIsNotRelaunched() {
        supervisor.update(apps: [app], autoLaunch: [id])
        workspace.start(id)
        clock.queue.removeAll()
        clock.now += AppSupervisor.stableRun + 1
        workspace.stop(id)
        XCTAssertEqual(supervisor.record(id)?.launchAttempts, 0, "a long run is not a crash loop")
        XCTAssertEqual(clock.runQueued(), [1])
        XCTAssertEqual(workspace.launches.count, 2)

        workspace.start(id)
        clock.queue.removeAll()
        var quit: Result<Bool, Error>?
        supervisor.quit(id) { quit = $0 }
        if case .success(let wasRunning) = quit { XCTAssertTrue(wasRunning) } else { XCTFail() }
        XCTAssertEqual(workspace.terminated, [id], "not subscribed, so terminate instead of socket quit")
        workspace.onTerminate?(id, 4242)
        XCTAssertTrue(clock.queue.isEmpty, "a requested quit is not relaunched")
    }

    func testTerminationIsSeenWhileTheDyingProcessIsStillListed() {
        connector.reachable = [socket]
        workspace.running[id] = [100]
        supervisor.update(apps: [app], autoLaunch: [])
        XCTAssertEqual(health, .running)
        // The server goes first (subscription closes) while the process is still listed...
        connector.onCloses[socket]?()
        XCTAssertEqual(health, .socketUnreachable)
        // ...then NSWorkspace announces the exit before NSRunningApplication catches up.
        workspace.stop(id, stale: true)
        XCTAssertEqual(health, .notRunning)
        clock.runQueued()
        XCTAssertEqual(health, .notRunning, "no reconnect to a dead process")
    }

    func testTerminationNoticeBeforeTheSocketCloses() {
        connector.reachable = [socket]
        workspace.running[id] = [100]
        supervisor.update(apps: [app], autoLaunch: [])
        // NSWorkspace first, process still listed; then the subscription notices.
        workspace.onTerminate?(id, 100)
        XCTAssertEqual(health, .notRunning)
        connector.onCloses[socket]?()
        clock.runQueued()
        XCTAssertEqual(health, .notRunning)
        XCTAssertEqual(connector.subscriptions.count, 1, "no resubscribe attempt")
    }

    func testFailedLaunchOfNonAutoLaunchAppFailsPendingAndDoesNotRetry() {
        workspace.launchError = NSError(domain: "test", code: 1)
        supervisor.update(apps: [app], autoLaunch: [])
        var reply: Result<[String: Any], Error>?
        supervisor.send(id, command: "panel", args: [:]) { reply = $0 }
        if case .failure = reply {} else { XCTFail("pending command should fail with the launch") }
        XCTAssertEqual(health, .notRunning)
        XCTAssertTrue(clock.queue.isEmpty)
    }

    func testRoutingTable() {
        typealias R = ExternalPlacement
        XCTAssertEqual(R.route(installed: false, health: .notInstalled, cooperative: false, hasAXWindow: false, socketGraceOver: true), .failed("not installed"))
        XCTAssertEqual(R.route(installed: true, health: .notRunning, cooperative: false, hasAXWindow: false, socketGraceOver: true), .launch)
        XCTAssertEqual(R.route(installed: true, health: .launching, cooperative: false, hasAXWindow: true, socketGraceOver: true), .wait)
        XCTAssertEqual(R.route(installed: true, health: .running, cooperative: true, hasAXWindow: false, socketGraceOver: false), .socket)
        XCTAssertEqual(R.route(installed: true, health: .running, cooperative: false, hasAXWindow: true, socketGraceOver: false), .ax)
        XCTAssertEqual(R.route(installed: true, health: .socketUnreachable, cooperative: false, hasAXWindow: true, socketGraceOver: false), .wait,
                       "give a fresh launch time to open its socket")
        XCTAssertEqual(R.route(installed: true, health: .socketUnreachable, cooperative: false, hasAXWindow: true, socketGraceOver: true), .ax)
    }
}
