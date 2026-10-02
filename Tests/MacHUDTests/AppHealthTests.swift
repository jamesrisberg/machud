import XCTest
import HUDKit
@testable import MacHUDCore

/// MacHUD does not take a sibling's word for what is on screen, notices siblings running an
/// older build or contract, and relaunches them.
@MainActor
final class AppHealthTests: XCTestCase {
    private let id = "xyz.pad"
    private let socket = "/tmp/gs-pad-health.sock"
    private var workspace: FakeWorkspace!
    private var connector: FakeConnector!
    private var clock: ManualClock!
    private var externals: ExternalPanels!
    private var supervisor: AppSupervisor { externals.supervisor }
    private var probe: ShowOutcome? = .onScreen
    private var missed: [(app: String, panel: String, outcome: ShowOutcome)] = []

    private var app: ExternalApp {
        ExternalApp(manifest: HUDManifest(id: id, name: "Pad", socket: socket,
                                          panels: [HUDManifest.Panel(id: "pad", title: "Pad", verbs: ["show", "hide", "frame"],
                                                                     kind: .hover)]),
                    bundleURL: URL(fileURLWithPath: "/Applications/Pad.app"))
    }

    override func setUp() {
        workspace = FakeWorkspace()
        workspace.installed = [id]
        connector = FakeConnector()
        connector.reachable = [socket]
        clock = ManualClock()
        let supervisor = AppSupervisor(workspace: workspace, connector: connector, schedule: clock.schedule)
        supervisor.now = { [unowned self] in self.clock.now }
        supervisor.contractVersion = "0.2.0"
        supervisor.windowProbe = { [unowned self] _ in self.probe }
        supervisor.fileDate = { _ in nil }
        supervisor.bundleVersion = { _ in nil }
        supervisor.bundleExecutable = { _ in nil }
        supervisor.onShowMissed = { [unowned self] in self.missed.append(($0, $1, $2)) }
        externals = ExternalPanels(registry: PanelRegistry(), supervisor: supervisor) { AppsConfig() }
        externals.install([app], autoLaunch: [])
        externals.rediscover = { [unowned self] in self.events.append("rediscover") }
        workspace.onLaunchCall = { [unowned self] in self.events.append("launch") }
    }

    private var events: [String] = []

    private func startApp(pid: pid_t = 4242) {
        workspace.start(id, pid: pid)
        clock.runQueued()
        XCTAssertEqual(supervisor.record(id)?.health, .running)
    }

    private var panel: ExternalPanel { externals.registry.panel(id: "\(id)/pad") as! ExternalPanel }
    private var row: [String: Any] { externals.json.first { $0["id"] as? String == id } ?? [:] }

    // MARK: Show verification

    func testShowThatLandedElsewhereIsRecordedAndReportedOnlyWhenLoud() {
        startApp()
        probe = .anotherDesktop
        panel.show(HUDPanelTransition(from: .bottom, reason: .hover))
        XCTAssertEqual(clock.runQueued(), [AppSupervisor.showCheckDelay])
        XCTAssertEqual(panel.json["onScreen"] as? Bool, false)
        XCTAssertEqual(panel.json["elsewhere"] as? String, "another desktop")
        XCTAssertTrue(missed.isEmpty, "a passing hover does not toast")

        panel.show(HUDPanelTransition(from: .bottom, reason: .click))
        clock.runQueued()
        XCTAssertEqual(missed.map { $0.outcome }, [.anotherDesktop])
        XCTAssertEqual(missed.first?.panel, "pad")

        panel.show()                                         // `panel show`, a loadout
        clock.runQueued()
        XCTAssertEqual(missed.count, 1, "plain shows record quietly")
        XCTAssertEqual(panel.json["elsewhere"] as? String, "another desktop")

        // A click on a hover button pins it: loud although the transition says hover.
        panel.show(HUDPanelTransition(reason: .hover), loud: true)
        clock.runQueued()
        XCTAssertEqual(missed.count, 2)
    }

    func testShowThatReachedTheScreenIsRecordedQuietly() {
        startApp()
        panel.show()
        clock.runQueued()
        XCTAssertEqual(panel.json["onScreen"] as? Bool, true)
        XCTAssertNil(panel.json["elsewhere"])
        XCTAssertTrue(missed.isEmpty)
    }

    func testHideAndQuitForgetTheCheck() {
        startApp()
        probe = .offScreen
        panel.show()
        clock.runQueued()
        XCTAssertEqual(panel.json["elsewhere"] as? String, "off screen")
        panel.hide()
        XCTAssertNil(panel.json["onScreen"])
        XCTAssertNil(supervisor.record(id)?.showChecks["pad"])

        panel.show()
        clock.runQueued()
        connector.onEvents[socket]?(["event": "state", "panels": [["id": "pad", "visible": false]]])
        XCTAssertNil(supervisor.record(id)?.showChecks["pad"], "the app hid it itself")

        panel.show()
        clock.runQueued()
        workspace.stop(id)
        XCTAssertTrue(supervisor.record(id)?.showChecks.isEmpty ?? false)
    }

    func testNoCheckWhenThePanelHidBeforeItRanOrTheShowFailed() {
        startApp()
        probe = .anotherDesktop
        panel.show(HUDPanelTransition(reason: .click))
        panel.hide()
        clock.runQueued()
        XCTAssertTrue(missed.isEmpty)

        connector.replies["panel"] = ["ok": false, "error": "no such panel"]
        panel.show()
        XCTAssertTrue(clock.queue.isEmpty, "a refused show is not checked")
    }

    func testTheAppsHintDecidesOnlyWhenTheWindowListCannot() {
        startApp()
        probe = .onScreen
        connector.replies["panel"] = ["ok": true, "visible": true, "onActiveSpace": false]
        panel.show()
        clock.runQueued()
        XCTAssertEqual(panel.json["onScreen"] as? Bool, true, "the window list wins")

        probe = nil
        panel.show(HUDPanelTransition(reason: .summon))
        clock.runQueued()
        XCTAssertEqual(panel.json["elsewhere"] as? String, "another desktop")
        XCTAssertEqual(missed.count, 1)
    }

    func testClassifyFromTheWindowList() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        typealias W = WindowPresence.Window
        let here = W(frame: CGRect(x: 100, y: 100, width: 400, height: 300), onScreen: true)
        let away = W(frame: CGRect(x: 100, y: 100, width: 400, height: 300), onScreen: false, spaces: 1)
        let orderedOut = W(frame: CGRect(x: 100, y: 100, width: 400, height: 300), onScreen: false, spaces: 0)
        let beyond = W(frame: CGRect(x: 5000, y: 100, width: 400, height: 300), onScreen: true)
        XCTAssertEqual(WindowPresence.classify([away, here], screens: screens), .onScreen)
        XCTAssertEqual(WindowPresence.classify([away, orderedOut], screens: screens), .anotherDesktop)
        XCTAssertEqual(WindowPresence.classify([orderedOut], screens: screens), .offScreen)
        XCTAssertEqual(WindowPresence.classify([beyond], screens: screens), .offScreen)
        XCTAssertEqual(WindowPresence.classify([], screens: screens), .offScreen)
    }

    // MARK: Stale builds and contract

    func testHelloIsKeptAndAnOlderContractIsReported() throws {
        connector.replies["hello"] = ["ok": true, "hudkit": "0.1.4", "version": "0.1.0"]
        startApp()
        XCTAssertEqual(supervisor.record(id)?.hello, AppHello(contract: "0.1.4", version: "0.1.0"))
        let contract = try XCTUnwrap(row["contract"] as? [String: Any])
        XCTAssertEqual(contract["app"] as? String, "0.1")
        XCTAssertEqual(contract["machud"] as? String, "0.2")
        XCTAssertEqual(contract["older"] as? Bool, true)
        XCTAssertEqual(entry?.actions.filter { $0.kind == .status }.map(\.title), ["Built for an older MacHUD"])

        connector.replies["hello"] = ["ok": true, "hudkit": "0.2.3"]
        workspace.stop(id)
        XCTAssertNil(supervisor.record(id)?.hello, "forgotten when it quits")
        XCTAssertNil(row["contract"])
        startApp()
        XCTAssertEqual((row["contract"] as? [String: Any])?["older"] as? Bool, false, "a newer patch is the same contract")
    }

    func testRebuiltBundleOrNewerVersionOnDiskMarksTheAppOutdated() {
        let started = clock.now
        let exe = URL(fileURLWithPath: "/Applications/Pad.app/Contents/MacOS/Pad")
        workspace.processInfo[4242] = AppProcess(pid: 4242, launchDate: started,
                                                 bundleURL: URL(fileURLWithPath: "/Applications/Pad.app"), executableURL: exe)
        var built = started.addingTimeInterval(-60)
        supervisor.fileDate = { $0 == exe ? built : nil }
        connector.replies["hello"] = ["ok": true, "hudkit": "0.2.0", "version": "0.1.0"]
        startApp()
        XCTAssertEqual(row["outdated"] as? Bool, false)
        XCTAssertFalse(MacHUDMenuModel.hasOutdated(externals: externals))

        built = started.addingTimeInterval(3600)
        XCTAssertEqual(row["outdated"] as? Bool, true)
        XCTAssertEqual(row["outdatedReason"] as? String, "rebuilt after it started")
        XCTAssertTrue(MacHUDMenuModel.hasOutdated(externals: externals))
        XCTAssertEqual(entry?.actions.filter { $0.kind == .status }.map(\.title), ["Update ready, relaunch to apply"])

        supervisor.bundleVersion = { _ in "0.2.0" }
        XCTAssertEqual(row["outdatedReason"] as? String, "running 0.1.0, 0.2.0 on disk; rebuilt after it started")

        workspace.stop(id)
        XCTAssertNil(row["outdated"], "only running apps are judged")
        XCTAssertEqual(entry?.actions.last?.kind, .launch)
    }

    func testANewerBundleBesideTheRunningOneIsTheUpdate() {
        // Running an old dev build while a newer install of the same id sits in /Applications.
        let dev = URL(fileURLWithPath: "/Users/me/dev/pad/build/Pad.app")
        let installed = URL(fileURLWithPath: "/Applications/Pad.app")
        let started = clock.now
        workspace.processInfo[4242] = AppProcess(pid: 4242, launchDate: started, bundleURL: dev,
                                                 executableURL: dev.appendingPathComponent("Contents/MacOS/Pad"))
        supervisor.bundles = { _ in [dev, installed] }
        supervisor.nextBundle = { $0.first { $0 == installed } ?? $0[0] }
        supervisor.bundleExecutable = { $0.appendingPathComponent("Contents/MacOS/Pad") }
        supervisor.fileDate = { $0.path.hasPrefix(installed.path) ? started.addingTimeInterval(86_400) : started.addingTimeInterval(-60) }
        supervisor.bundleVersion = { $0 == installed ? "0.2.0" : "0.1.0" }
        connector.replies["hello"] = ["ok": true, "hudkit": "0.2.0", "version": "0.1.0"]
        startApp()
        XCTAssertEqual(row["outdatedReason"] as? String,
                       "running 0.1.0, 0.2.0 on disk; rebuilt after it started (/Applications/Pad.app)")

        supervisor.nextBundle = { $0[0] }                    // the dev build is the newest
        XCTAssertEqual(row["outdated"] as? Bool, false)
    }

    func testOutdatedReasonAndContractRules() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(AppBuildStatus.outdatedReason(launched: t, built: t.addingTimeInterval(1), running: nil, onDisk: nil),
                     "a build finishing as it launches is the build it runs")
        XCTAssertNil(AppBuildStatus.outdatedReason(launched: nil, built: t, running: "1.0", onDisk: nil))
        XCTAssertEqual(AppBuildStatus.contract(app: "0.3.0", machud: "0.2.9")?.older, false)
        XCTAssertEqual(AppBuildStatus.contract(app: "1.0", machud: "0.9.0")?.older, false)
        XCTAssertNil(AppBuildStatus.contract(app: "dev", machud: "0.2.0"))
    }

    private var entry: MacHUDMenuModel.Entry? {
        MacHUDMenuModel.entries(externals: externals) { _ in .full }.first
    }

    // MARK: Relaunch

    func testRelaunchQuitsWaitsForTheExitThenLaunchesAndWaitsForTheSocket() {
        startApp(pid: 100)
        var result: [String: Any]?
        externals.relaunch(id) { result = $0 }
        XCTAssertEqual(connector.requests.last?.command, "quit")
        XCTAssertEqual(clock.runQueued(), [AppSupervisor.relaunchPoll], "still running: wait")
        XCTAssertTrue(workspace.launches.isEmpty)

        workspace.stop(id)
        clock.runQueued()
        XCTAssertEqual(workspace.launches, [id])
        XCTAssertEqual(events, ["rediscover", "launch"], "discovery picks the bundle before it is launched")
        XCTAssertNil(result)
        workspace.start(id, pid: 200)
        clock.runQueued()                                    // connect and the next poll
        clock.runQueued()
        XCTAssertEqual(result?["pid"] as? Int, 200)
        XCTAssertEqual(result?["previousPID"] as? Int, 100)
        XCTAssertEqual(result?["health"] as? String, "running")
        XCTAssertFalse(supervisor.record(id)?.relaunching ?? true)
        XCTAssertFalse(supervisor.record(id)?.quitRequested ?? true, "the new process is supervised as usual")
    }

    func testRelaunchGivesUpOnAnAppThatDoesNotQuit() {
        startApp(pid: 100)
        var result: [String: Any]?
        externals.relaunch(id) { result = $0 }
        var second: [String: Any]?
        externals.relaunch(id) { second = $0 }
        XCTAssertEqual(second?["error"] as? String, "\(id) is already relaunching")
        for _ in 0..<100 where result == nil { clock.runQueued() }
        XCTAssertEqual(result?["error"] as? String, "\(id) did not quit within 10 s")
        XCTAssertTrue(workspace.launches.isEmpty)
    }

    func testRelaunchOfAStoppedAppLaunchesIt() {
        var result: [String: Any]?
        externals.relaunch(id) { result = $0 }
        XCTAssertEqual(workspace.launches, [id])
        workspace.start(id, pid: 300)
        clock.runQueued()
        clock.runQueued()
        XCTAssertEqual(result?["pid"] as? Int, 300)
        XCTAssertNil(result?["previousPID"])
    }

    func testRelaunchAllOutdatedOnlyTouchesOutdatedApps() {
        let other = ExternalApp(manifest: HUDManifest(id: "xyz.other", name: "Other", socket: "/tmp/gs-other-health.sock",
                                                      panels: [HUDManifest.Panel(id: "main", title: "Main")]),
                                bundleURL: URL(fileURLWithPath: "/Applications/Other.app"))
        workspace.installed.insert(other.id)
        connector.reachable.insert(other.socketPath)
        externals.install([app, other], autoLaunch: [])
        let exe = URL(fileURLWithPath: "/Applications/Pad.app/Contents/MacOS/Pad")
        workspace.processInfo[100] = AppProcess(pid: 100, launchDate: clock.now, executableURL: exe)
        supervisor.fileDate = { [clock] in $0 == exe ? clock!.now.addingTimeInterval(600) : nil }
        startApp(pid: 100)
        workspace.start(other.id, pid: 101)
        clock.runQueued()
        XCTAssertEqual(supervisor.outdatedIDs, [id])

        var result: [String: [String: Any]]?
        externals.relaunchAll(outdatedOnly: true) { result = $0 }
        XCTAssertEqual(connector.requests.filter { $0.command == "quit" }.map(\.path), [socket])
        workspace.stop(id)
        clock.runQueued()
        workspace.start(id, pid: 102)
        clock.runQueued()
        clock.runQueued()
        XCTAssertEqual(result.map { Array($0.keys) }, [id])
        XCTAssertEqual(result?[id]?["pid"] as? Int, 102)

        var none: [String: [String: Any]]?
        workspace.processInfo = [:]
        externals.relaunchAll(outdatedOnly: true) { none = $0 }
        XCTAssertEqual(none?.count, 0, "nothing outdated answers at once")
    }
}
