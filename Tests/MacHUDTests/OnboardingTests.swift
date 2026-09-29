import AppKit
import XCTest
import HUDKit
@testable import MacHUDCore

@MainActor
final class FakeOnboardingPermissions: OnboardingPermissions {
    var accessibility = false
    var microphone: MicrophoneAccess = .notAsked
    var requests: [String] = []

    func requestAccessibility() -> String? { requests.append("accessibility"); return nil }
    func requestMicrophone(_ done: @escaping @MainActor (MicrophoneAccess) -> Void) -> String? {
        requests.append("microphone")
        microphone = .granted
        done(.granted)
        return nil
    }
    func openAccessibilitySettings() -> String? { requests.append("accessibilitySettings"); return nil }
    func openMicrophoneSettings() -> String? { requests.append("microphoneSettings"); return nil }
}

@MainActor
final class FakeOnboardingToolDock: OnboardingToolDock {
    var isEnabled = true
    var dockPosition: HUDDockPosition = .bottom
    var screenName: String?
    func setEnabled(_ on: Bool) { isEnabled = on }
    func move(to position: HUDDockPosition) { dockPosition = position }
}

/// Captures from a scripted result and applies on demand; never reads or moves a window.
@MainActor
final class FakeOnboardingLoadouts: OnboardingLoadouts {
    var saved: [String: OnboardingLoadoutSummary] = [:]
    var captureProblem: String?
    var captures: [String] = []
    var onApplied: ((OnboardingApplied) -> Void)?

    var names: [String] { saved.keys.sorted() }
    func summary(named name: String) -> OnboardingLoadoutSummary? { saved[name] }

    func capture(name: String, done: @escaping @MainActor (Result<OnboardingLoadoutSummary, OnboardingProblem>) -> Void) {
        captures.append(name)
        if let captureProblem { done(.failure(OnboardingProblem(captureProblem))); return }
        let summary = Self.summary(name)
        saved[name] = summary
        done(.success(summary))
    }

    func apply(_ name: String, placed: Int = 3, failed: Int = 0) {
        onApplied?(OnboardingApplied(loadout: name, placed: placed, failed: failed))
    }

    static func summary(_ name: String) -> OnboardingLoadoutSummary {
        OnboardingLoadoutSummary(name: name, regions: [
            .init(label: "Safari · Docs", frame: FractionRect(x: 0, y: 0, w: 0.5, h: 1)),
            .init(label: "Terminal", frame: FractionRect(x: 0.5, y: 0, w: 0.5, h: 0.6)),
            .init(label: "Notes", frame: FractionRect(x: 0.5, y: 0.6, w: 0.5, h: 0.4)),
        ], aspect: 1.6, screen: "Built-in Retina Display")
    }
}

/// Records presents and dismisses; never puts a window on screen.
@MainActor
final class FakeOnboardingPresenter: OnboardingPresenting {
    var isVisible = false
    var presents = 0
    func present(_ model: OnboardingModel) { isVisible = true; presents += 1 }
    func dismiss() { isVisible = false }
}

@MainActor
final class OnboardingTests: XCTestCase {
    private var dir: URL!
    private var host: FakeVoiceHost!
    private var voice: VoiceServices!
    private var permissions: FakeOnboardingPermissions!
    private var apps: AppsTabModel!
    private var presenter: FakeOnboardingPresenter!
    private var dock: FakeOnboardingToolDock!
    private var loadouts: FakeOnboardingLoadouts!
    /// What the fake host answers to `models status`; nil answers as an older host would.
    private var models: [String: Any]? = ["installed": false, "downloading": false, "progress": 0, "bytes": 330_000_000]
    private var modelRequests: [[String: String]] = []
    /// What the fake host answers to `brain status`; nil answers as an older host would.
    private var brainReply: [String: Any]? = ["ok": true, "available": false, "problem": "Choose a workspace folder for the agent.",
                                              "workspace": "", "runtimes": [
                                                ["id": "codex", "installed": true, "path": "/opt/homebrew/bin/codex"],
                                                ["id": "claude", "installed": true, "path": "/Users/me/.local/bin/claude"],
                                                ["id": "hermes", "installed": false],
                                                ["id": "mclaude", "installed": true, "path": "/Users/me/.local/bin/mclaude"]]]

    override func setUpWithError() throws {
        // Short: socket paths are limited to 103 bytes.
        dir = URL(fileURLWithPath: "/tmp/mho-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("v.sock").path
        host = FakeVoiceHost(path: path)
        host.server.register("brain") { [unowned self] args, done in
            guard args["action"] == "status", let reply = self.brainReply else {
                done(["ok": false, "error": "unknown command brain"]); return
            }
            var r = reply
            r["workspace"] = (self.host.settings["brain"] as? [String: Any])?["workspacePath"] ?? ""
            done(r)
        }
        registerModels(on: host)
        XCTAssertTrue(host.server.start())
        let supervisor = VoiceHostSupervisor(launcher: FakeVoiceLauncher(), helper: { URL(fileURLWithPath: "/x/MacHUDVoice") },
                                             isEnabled: { true }, socketPath: path, environment: [:], isolated: false,
                                             schedule: { _, _ in })
        voice = VoiceServices(supervisor: supervisor, socketPath: path)
        permissions = FakeOnboardingPermissions()
        apps = AppsTabModel()
        presenter = FakeOnboardingPresenter()
        dock = FakeOnboardingToolDock()
        loadouts = FakeOnboardingLoadouts()
    }

    /// `models` as the contract has it: `status` reports Kokoro, `download` starts it.
    private func registerModels(on host: FakeVoiceHost) {
        host.server.register("models") { [unowned self] args, done in
            self.modelRequests.append(args)
            guard var kokoro = self.models else { done(["ok": false, "error": "unknown command models"]); return }
            if args["action"] == "download" {
                kokoro["downloading"] = true
                kokoro["progress"] = 0.1
                self.models = kokoro
            }
            done(["ok": true, "kokoro": kokoro])
        }
    }

    override func tearDownWithError() throws {
        voice.stop()
        host.server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> OnboardingModel {
        let model = OnboardingModel(voice: voice, apps: apps, permissions: permissions)
        model.toolDock = dock
        model.loadouts = loadouts
        return model
    }

    private func makeServices(_ model: OnboardingModel? = nil) -> OnboardingServices {
        let services = OnboardingServices(model: model ?? makeModel(),
                                          store: OnboardingStore(url: dir.appendingPathComponent("state/onboarding.json")),
                                          presenter: presenter)
        services.launchAllowed = { true }
        return services
    }

    private func connect() {
        voice.start()
        XCTAssertTrue(spin(until: { self.voice.connection.isConnected }))
        XCTAssertTrue(spin(until: { self.voice.settingsModel.status == .ready }))
    }

    // MARK: - Pure parts

    func testStepsRunInOrder() {
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue),
                       ["welcome", "permissions", "voice", "brain", "apps", "tooldock", "loadout", "radial", "done"])
        XCTAssertEqual(OnboardingStep.sections, [.permissions, .voice, .brain, .apps, .toolDock, .loadout, .radial])
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.toolDock.previous, .apps)
    }

    /// A record from another version (a step or section this build does not know) still reads,
    /// so someone who finished the guide is not shown it again.
    func testRecordFromAnotherVersionStillReads() throws {
        let url = dir.appendingPathComponent("state/onboarding.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"status":"completed","step":"tour","updatedAt":"2026-09-27T10:00:00Z"}"#.utf8).write(to: url)
        let store = OnboardingStore(url: url)
        XCTAssertEqual(store.load()?.status, .completed)
        XCTAssertEqual(store.load()?.step, .welcome)
        XCTAssertFalse(store.wantsLaunch)

        try Data(#"{"status":"inProgress","step":"radial","sections":{"voice":"done","gone":"done","apps":"nope"},"loadout":"Desk"}"#.utf8)
            .write(to: url)
        let record = try XCTUnwrap(store.load())
        XCTAssertEqual(record.step, .radial)
        XCTAssertEqual(record.sections, ["voice": .done])
        XCTAssertEqual(record.loadout, "Desk")
    }

    func testStoreKeepsSectionsAndLoadoutUnlessGiven() {
        let store = OnboardingStore(url: dir.appendingPathComponent("state/onboarding.json"))
        store.save(.inProgress, step: .voice, sections: ["permissions": .skipped], loadout: "Desk")
        store.save(.inProgress, step: .brain)
        XCTAssertEqual(store.load()?.sections, ["permissions": .skipped])
        XCTAssertEqual(store.load()?.loadout, "Desk")
        XCTAssertEqual(store.load()?.step, .brain)
    }

    func testStoreWantsLaunchUntilFinishedOrSkipped() {
        let store = OnboardingStore(url: dir.appendingPathComponent("state/onboarding.json"))
        XCTAssertNil(store.load())
        XCTAssertTrue(store.wantsLaunch, "never ran")
        store.save(.inProgress, step: .brain)
        XCTAssertEqual(store.load()?.step, .brain)
        XCTAssertTrue(store.wantsLaunch, "left unfinished")
        store.save(.completed, step: .done)
        XCTAssertFalse(store.wantsLaunch)
        store.save(.skipped, step: .welcome)
        XCTAssertFalse(store.wantsLaunch)
        store.reset()
        XCTAssertTrue(store.wantsLaunch)
    }

    func testBrainStatusParsesTheContractReply() throws {
        let status = try XCTUnwrap(BrainStatus(reply: brainReply!))
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.problem, "Choose a workspace folder for the agent.")
        XCTAssertEqual(status.runtimes.map(\.id), ["codex", "claude", "hermes", "mclaude"])
        XCTAssertEqual(status.runtime("hermes")?.installed, false)
        XCTAssertNil(status.runtime("hermes")?.path)
        XCTAssertEqual(status.runtime("mclaude")?.path, "/Users/me/.local/bin/mclaude")
        XCTAssertNil(BrainStatus(reply: ["ok": false, "error": "unknown command brain"]))
        XCTAssertNil(BrainStatus(reply: ["ok": true, "available": true, "problem": ""])?.problem)
    }

    /// Every field `VoiceHostCommands.brain` and `BrainRuntimeDetection.json` send.
    func testBrainStatusParsesTheHostsFullReply() throws {
        let status = try XCTUnwrap(BrainStatus(reply: [
            "ok": true, "available": false, "problem": "Choose a workspace folder for the agent.", "workspace": "",
            "runtime": "mclaude", "sessionKey": "claude:abc",
            "runtimes": [["id": "codex", "name": "Codex", "installed": true, "path": "/bin/codex"],
                         ["id": "hermes", "name": "Hermes", "installed": true, "apiServer": false],
                         ["id": "mclaude", "name": "mclaude", "installed": false, "tmux": NSNull()]]]))
        XCTAssertEqual(status.runtimes.map(\.id), ["codex", "hermes", "mclaude"])
        XCTAssertEqual(status.runtime("codex")?.path, "/bin/codex")
        XCTAssertEqual(status.runtime("mclaude")?.installed, false)
        XCTAssertEqual(status.problem, "Choose a workspace folder for the agent.")
    }

    func testLiveStateReadsTheHostState() {
        XCTAssertFalse(VoiceLiveState(state: nil).connected)
        XCTAssertEqual(VoiceLiveState(state: nil).headline(keyMode: "hold"), "Voice is not running.")
        let listening = VoiceLiveState(state: ["phase": ["name": "listening", "mode": "dictation"], "inputLevel": 0.4,
                                               "partialTranscript": "hello there", "brainAvailable": false,
                                               "brainProblem": "Codex is not installed", "muted": false])
        XCTAssertTrue(listening.isActive)
        XCTAssertEqual(listening.partialTranscript, "hello there")
        XCTAssertEqual(listening.inputLevel, 0.4)
        XCTAssertEqual(listening.brainProblem, "Codex is not installed")
        XCTAssertEqual(listening.headline(keyMode: "hold"), "Listening. Keep talking…")
        let idle = VoiceLiveState(state: ["phase": ["name": "idle"]])
        XCTAssertTrue(idle.headline(keyMode: "hold").contains("Hold fn"))
        XCTAssertTrue(idle.headline(keyMode: "toggle").contains("Tap fn"))
        let failed = VoiceLiveState(state: ["phase": ["name": "failed", "message": "no mic"]])
        XCTAssertEqual(failed.headline(keyMode: "hold"), "That did not work: no mic")
    }

    // MARK: - Showing, resuming, finishing

    func testFirstLaunchShowsAtWelcomeAndResumesWhereLeft() {
        let services = makeServices()
        XCTAssertTrue(services.wantsLaunch)
        XCTAssertTrue(services.showIfNeeded())
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(services.model.step, .welcome)
        services.model.next()
        services.model.next()
        XCTAssertEqual(services.model.step, .voice)
        services.model.later()
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(services.store.load()?.status, .inProgress)
        XCTAssertEqual(services.store.load()?.step, .voice)
        XCTAssertEqual(services.store.load()?.sections, ["permissions": .skipped], "not granted: moving on skipped it")

        // Next launch: a fresh model resumes at Voice.
        let again = makeServices()
        XCTAssertTrue(again.showIfNeeded())
        XCTAssertEqual(again.model.step, .voice)
    }

    func testFinishingOrSkippingStopsLaunchShows() {
        let services = makeServices()
        services.show(step: .done)
        services.model.next()   // Finish on the last step.
        XCTAssertFalse(presenter.isVisible)
        XCTAssertEqual(services.store.load()?.status, .completed)
        XCTAssertFalse(services.showIfNeeded())

        services.show()
        XCTAssertEqual(services.model.step, .welcome, "a finished onboarding opens at the start")
        services.model.skip()
        XCTAssertEqual(services.store.load()?.status, .skipped)
        XCTAssertFalse(makeServices().showIfNeeded())
    }

    func testIsolatedInstanceDoesNotShowByItself() {
        let services = makeServices()
        services.launchAllowed = { false }
        XCTAssertFalse(services.showIfNeeded())
        XCTAssertFalse(presenter.isVisible)
        XCTAssertNil(services.store.load())
    }

    func testShowPreparesTheAppsStep() {
        let services = makeServices()
        var prepared = 0
        services.prepareApps = { prepared += 1 }
        services.show()
        XCTAssertEqual(prepared, 1)
    }

    func testControlVerb() {
        let services = makeServices()
        func run(_ words: [String]) -> [String: Any] { services.handle(HUDSocketClient.parseArguments(words)) }

        var r = run([])
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["visible"] as? Bool, false)
        XCTAssertTrue(r["record"] is NSNull)
        XCTAssertEqual(run(["next"])["ok"] as? Bool, false, "next needs the overlay up")

        r = run(["show", "step=brain"])
        XCTAssertEqual(r["visible"] as? Bool, true)
        XCTAssertEqual(r["step"] as? String, "brain")
        XCTAssertEqual(run(["next"])["step"] as? String, "apps")
        XCTAssertEqual(run(["back"])["step"] as? String, "brain")
        XCTAssertEqual(run(["show", "step=nowhere"])["ok"] as? Bool, false)

        r = run(["hide"])
        XCTAssertEqual(r["visible"] as? Bool, false)
        XCTAssertEqual((r["record"] as? [String: Any])?["status"] as? String, "inProgress")
        XCTAssertEqual((r["record"] as? [String: Any])?["step"] as? String, "brain")

        r = run(["reset"])
        XCTAssertTrue(r["record"] is NSNull)
        XCTAssertTrue(services.wantsLaunch)

        _ = run(["show"])
        r = run(["skip"])
        XCTAssertEqual(r["visible"] as? Bool, false)
        XCTAssertEqual((r["record"] as? [String: Any])?["status"] as? String, "skipped")
        XCTAssertEqual(run(["bogus"])["ok"] as? Bool, false)
        XCTAssertEqual(run(["snapshot"])["ok"] as? Bool, false, "snapshot needs dir=")
    }

    // MARK: - Checklist

    func testChecklistStatesFollowTheUserAndTheSystem() {
        let services = makeServices()
        let model = services.model
        services.show()
        XCTAssertEqual(Set(OnboardingStep.sections.map { model.status(of: $0) }), [.todo])

        // Get started goes to the first section that is not done.
        permissions.accessibility = true
        permissions.microphone = .granted
        model.refreshPermissions()
        XCTAssertEqual(model.status(of: .permissions), .done, "granted: done by itself")
        model.next()
        XCTAssertEqual(model.step, .voice)

        // Voice is off (no host): moving on leaves it skipped; Skip for now does the same.
        model.next()
        XCTAssertEqual(model.status(of: .voice), .skipped)
        XCTAssertEqual(model.step, .brain)
        model.skipSection()
        XCTAssertEqual(model.status(of: .brain), .skipped)
        XCTAssertEqual(model.step, .apps)
        model.next()
        XCTAssertEqual(model.status(of: .apps), .done, "a choice: moving on is done")
        model.next()
        XCTAssertEqual(model.status(of: .toolDock), .done)
        XCTAssertEqual(model.step, .loadout)

        // A skipped section still turns done by itself: permissions revoked then granted.
        permissions.accessibility = false
        model.refreshPermissions()
        XCTAssertEqual(model.status(of: .permissions), .todo)
        model.go(to: .permissions)
        model.skipSection()
        XCTAssertEqual(model.status(of: .permissions), .skipped)
        permissions.accessibility = true
        model.tick()
        XCTAssertEqual(model.status(of: .permissions), .done)

        // Saved with the record and restored by the next launch.
        XCTAssertEqual(services.store.load()?.sections?["voice"], .skipped)
        XCTAssertEqual(services.store.load()?.sections?["apps"], .done)
        let again = makeServices()
        again.show()
        XCTAssertEqual(again.model.status(of: .voice), .skipped)
        XCTAssertEqual(again.model.status(of: .toolDock), .done)
        XCTAssertEqual(again.model.step, .voice, "resumes where it was left: skipping Permissions moved on")
        XCTAssertEqual((again.statusJSON["sections"] as? [String: String])?["brain"], "skipped")

        // The welcome page's button then goes to the first section still open.
        again.model.go(to: .welcome)
        again.model.next()
        XCTAssertEqual(again.model.step, .voice)
    }

    // MARK: - Tool dock

    func testToolDockSectionDrivesTheDockLive() {
        let model = makeModel()
        XCTAssertTrue(model.dockEnabled)
        XCTAssertEqual(model.dockPosition, .bottom)
        model.setDock(enabled: false)
        XCTAssertFalse(dock.isEnabled)
        XCTAssertFalse(model.dockEnabled)
        model.moveDock(to: .topLeft)
        XCTAssertEqual(dock.dockPosition, .topLeft)
        XCTAssertTrue(dock.isEnabled, "choosing a place shows it again")
        XCTAssertEqual(model.dockPosition, .topLeft)
        // Changed from the dock's own menu: the tick picks it up.
        dock.dockPosition = .right
        model.tick()
        XCTAssertEqual(model.dockPosition, .right)
        XCTAssertEqual((model.json["toolDock"] as? [String: Any])?["position"] as? String, "right")
    }

    /// Every click on the miniature moves the dock, not just the first: regression for a bug
    /// where the picker's overlapping hit regions (fixed alongside this) made later clicks look
    /// like they did nothing.
    func testToolDockMovesOnEveryConsecutiveClick() {
        let model = makeModel()
        let sequence: [HUDDockPosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left, .bottom]
        for position in sequence {
            model.moveDock(to: position)
            XCTAssertEqual(dock.dockPosition, position, "the dock itself moved")
            XCTAssertEqual(model.dockPosition, position, "the model picked up the move")
        }
    }

    /// The miniature's eight hit regions never overlap: an overlap lets the topmost one (drawn
    /// last) swallow taps meant for its neighbor, which is what made the picker feel dead after
    /// the first click.
    func testDockPositionPickerRegionsNeverOverlap() {
        for size in [CGSize(width: 430, height: 230), CGSize(width: 300, height: 230), CGSize(width: 600, height: 180)] {
            let screen = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            var byPosition: [HUDDockPosition: [CGRect]] = [:]
            for position in ToolDock.menuPositions {
                let rects = DockPositionPicker.segments(position, in: screen)
                XCTAssertFalse(rects.isEmpty)
                for rect in rects {
                    XCTAssertGreaterThan(rect.width, 0, "\(position) at \(size)")
                    XCTAssertGreaterThan(rect.height, 0, "\(position) at \(size)")
                }
                byPosition[position] = rects
            }
            for (i, a) in ToolDock.menuPositions.enumerated() {
                for b in ToolDock.menuPositions[(i + 1)...] {
                    for rectA in byPosition[a] ?? [] {
                        for rectB in byPosition[b] ?? [] {
                            XCTAssertFalse(rectA.intersects(rectB), "\(a) \(rectA) overlaps \(b) \(rectB) at \(size)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - First loadout and the radial menu

    func testFirstLoadoutCapturesAndShowsItsRegions() {
        let services = makeServices()
        let model = services.model
        services.show(step: .loadout)
        XCTAssertEqual(model.status(of: .loadout), .todo)
        model.startArranging()
        XCTAssertEqual(model.compact, .arrange)

        loadouts.captureProblem = "No app windows are on this display. Open two or three, then capture."
        model.captureLoadout()
        XCTAssertEqual(model.loadoutNote, loadouts.captureProblem)
        XCTAssertEqual(model.compact, .arrange, "stays out of the way to try again")
        XCTAssertNil(model.firstLoadout)

        loadouts.captureProblem = nil
        model.loadoutName = "Deep Work"
        model.captureLoadout()
        XCTAssertEqual(loadouts.captures.last, "Deep Work")
        XCTAssertNil(model.compact, "back to the full overlay")
        XCTAssertEqual(model.firstLoadout?.regions.map(\.label), ["Safari · Docs", "Terminal", "Notes"])
        XCTAssertEqual(model.status(of: .loadout), .done)
        XCTAssertEqual(services.store.load()?.loadout, "Deep Work")
        XCTAssertEqual(model.practiceTarget, "Deep Work")

        // Restored at the next launch; a loadout deleted since is not made.
        XCTAssertEqual(makeServices().model.status(of: .loadout), .todo, "nothing restored before show")
        let again = makeServices()
        again.show()
        XCTAssertEqual(again.model.firstLoadout?.name, "Deep Work")
        loadouts.saved = [:]
        let after = makeServices()
        after.show()
        XCTAssertNil(after.model.firstLoadout)
    }

    func testRadialPracticeCompletesOnMacHUDsApply() {
        loadouts.saved = ["Other": FakeOnboardingLoadouts.summary("Other")]
        let services = makeServices()
        let model = services.model
        services.show(step: .loadout)
        model.loadoutName = "Desk"
        model.captureLoadout()

        // Applies before the practice step do not count.
        loadouts.apply("Desk")
        XCTAssertNil(model.practice)

        model.go(to: .radial)
        model.startPractice()
        XCTAssertEqual(model.compact, .practice)
        loadouts.apply("Other")
        XCTAssertNil(model.practice, "another loadout is not the practice")
        XCTAssertEqual(model.compact, .practice)
        loadouts.apply("Desk", placed: 3)
        XCTAssertEqual(model.practice, OnboardingApplied(loadout: "Desk", placed: 3, failed: 0))
        XCTAssertNil(model.compact, "the overlay comes back to say so")
        XCTAssertEqual(model.status(of: .radial), .done)
        XCTAssertEqual(services.store.load()?.sections?["radial"], nil, "done by itself, not a mark")
        XCTAssertEqual(((services.statusJSON["radial"] as? [String: Any])?["applied"] as? [String: Any])?["loadout"] as? String, "Desk")
    }

    func testRadialPracticeWithoutAFirstLoadoutUsesTheFirstThereIs() {
        let model = makeModel()
        XCTAssertNil(model.practiceTarget)
        loadouts.saved = ["Work": FakeOnboardingLoadouts.summary("Work")]
        XCTAssertEqual(model.practiceTarget, "Work")
        model.go(to: .radial)
        loadouts.apply("Work")
        XCTAssertEqual(model.status(of: .radial), .done, "applied while on the step, without the compact card")
    }

    // MARK: - Permissions

    func testPermissionsFollowTheSystemAndAskThroughIt() {
        let model = makeModel()
        XCTAssertFalse(model.accessibility)
        XCTAssertFalse(model.permissionsGranted)
        permissions.accessibility = true
        model.tick()
        XCTAssertTrue(model.accessibility, "granted in System Settings, picked up by the tick")
        model.requestMicrophone()
        XCTAssertEqual(model.microphone, .granted)
        XCTAssertTrue(model.permissionsGranted)
        model.requestAccessibility()
        model.openMicrophoneSettings()
        XCTAssertEqual(permissions.requests, ["microphone", "accessibility", "microphoneSettings"])
    }

    // MARK: - Voice

    func testVoiceStepEditsTheHostSettingsAndFollowsItsState() {
        let model = makeModel()
        connect()
        XCTAssertTrue(model.voiceOn)
        XCTAssertEqual(model.keyMode, "hold")
        model.setKeyMode("toggle")
        XCTAssertTrue(spin(until: { self.host.settings["keyMode"] as? String == "toggle" }))
        model.setAgentGesture(false)
        XCTAssertTrue(spin(until: { self.host.settings["agentGesture"] as? Bool == false }))

        host.server.publish("state", payload: ["state": ["phase": ["name": "listening", "mode": "dictation"],
                                                         "inputLevel": 0.5, "partialTranscript": "testing one two",
                                                         "muted": false, "brainAvailable": false]])
        XCTAssertTrue(spin(until: { model.live.partialTranscript == "testing one two" }))
        XCTAssertTrue(model.live.isActive)
    }

    // MARK: - Brain

    func testBrainStepShowsDetectionAndAsksForTheWorkspace() {
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.brain != nil }))
        XCTAssertEqual(model.runtimeInstalled("codex"), true)
        XCTAssertEqual(model.runtimeInstalled("hermes"), false)
        XCTAssertEqual(model.runtimePath("mclaude"), "/Users/me/.local/bin/mclaude")
        XCTAssertFalse(model.brainReady)
        XCTAssertEqual(model.brainProblem, "Choose a workspace folder for the agent.")

        let sets = host.settingsSets
        model.chooseRuntime("mclaude")
        XCTAssertTrue(spin(until: { (self.host.settings["brain"] as? [String: Any])?["runtime"] as? String == "mclaude" }))
        XCTAssertEqual(host.settingsSets, sets + 1, "runtime and brainEnabled go in one settings set")
        XCTAssertEqual(host.settings["brainEnabled"] as? Bool, true)
        XCTAssertEqual((host.settings["voice"] as? [String: Any])?["wakePhrase"] as? String, "Hey Computer", "other keys kept")

        model.chooseFolder = { done in done(URL(fileURLWithPath: "/Users/me/work")) }
        model.chooseWorkspace()
        XCTAssertTrue(spin(until: { model.workspace == "/Users/me/work" }))
        XCTAssertEqual((host.settings["brain"] as? [String: Any])?["workspacePath"] as? String, "/Users/me/work")

        // The host now reports its own reason until the brain is up.
        brainReply?["problem"] = "Codex is not installed"
        model.refreshBrainStatus()
        XCTAssertTrue(spin(until: { model.brainProblem == "Codex is not installed" }))
        brainReply?["available"] = true
        brainReply?["problem"] = nil
        model.refreshBrainStatus()
        XCTAssertTrue(spin(until: { model.brainReady }))
        XCTAssertNil(model.brainProblem)
    }

    func testBrainStepWithAnOlderHostFallsBackToTheStateProblem() {
        // A host from before `brain status`: no `brain` command and no `brainProblem` in its state.
        brainReply = nil
        host.server.register("state") { _, done in done(["ok": true, "state": ["phase": ["name": "idle"], "muted": false,
                                                                               "brainAvailable": false]]) }
        let model = makeModel()
        connect()
        model.chooseFolder = { done in done(URL(fileURLWithPath: "/w")) }
        model.chooseWorkspace()
        XCTAssertTrue(spin(until: { model.workspace == "/w" }))
        model.refreshBrainStatus()
        XCTAssertTrue(spin(until: { model.brainProblem == "unknown command brain" }))
        host.server.publish("state", payload: ["state": ["phase": ["name": "idle"], "brainAvailable": false,
                                                         "brainProblem": "The brain companion failed to start"]])
        XCTAssertTrue(spin(until: { model.brainProblem == "The brain companion failed to start" }))
    }

    /// The normal path against the shared fake's `brain` handler, which answers with the voice
    /// host's real `brain status` fields (`VoiceHostCommands.brain`).
    func testBrainStepReadsTheHostsBrainStatus() {
        // A fresh fake without this suite's scripted `brain` handler.
        host.server.stop()
        host = FakeVoiceHost(path: dir.appendingPathComponent("v.sock").path)
        registerModels(on: host)
        XCTAssertTrue(host.server.start())
        host.brainProblem = "Codex is not installed"
        host.mclaudeInstalled = true
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.brain != nil }))
        XCTAssertEqual(host.brainRequests.last, ["action": "status"])
        XCTAssertEqual(model.runtimeInstalled("codex"), true)
        XCTAssertEqual(model.runtimePath("codex"), "/bin/codex")
        XCTAssertEqual(model.runtimeInstalled("claude"), false)
        XCTAssertEqual(model.runtimeInstalled("mclaude"), true)
        model.chooseFolder = { done in done(URL(fileURLWithPath: "/w")) }
        model.chooseWorkspace()
        XCTAssertTrue(spin(until: { model.workspace == "/w" }))
        XCTAssertEqual(model.brainProblem, "Codex is not installed")
        host.brainProblem = nil
        host.server.publish("state", payload: ["state": host.state])
        XCTAssertTrue(spin(until: { model.brainReady }))
        XCTAssertNil(model.brainProblem)
    }

    func testBrainWhileVoiceIsDownSaysSo() {
        let model = makeModel()
        XCTAssertEqual(model.brainProblem, "Turn voice on first: the brain runs inside the voice host.")
        model.chooseRuntime("codex")
        XCTAssertNotNil(model.brainNote)
    }

    func testWorkspaceDefaultsToTheHomeFolder() {
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.brain != nil }))
        XCTAssertTrue(model.workspaceIsDefault)
        XCTAssertEqual(model.workspace, NSHomeDirectory(), "the host did not resolve it: still home")
        XCTAssertEqual(model.workspaceDisplay, "~")

        // The host reports the resolved path; a choice replaces it and Use Home clears it.
        brainReply?["workspace"] = "/Users/me"
        host.server.register("brain") { [unowned self] _, done in
            var r = self.brainReply!
            let stored = (self.host.settings["brain"] as? [String: Any])?["workspacePath"] as? String ?? ""
            r["workspace"] = stored.isEmpty ? "/Users/me" : stored
            done(r)
        }
        model.refreshBrainStatus()
        XCTAssertTrue(spin(until: { model.workspace == "/Users/me" }))
        model.chooseFolder = { done in done(URL(fileURLWithPath: "/Users/me/work")) }
        model.chooseWorkspace()
        XCTAssertTrue(spin(until: { model.workspace == "/Users/me/work" }))
        XCTAssertFalse(model.workspaceIsDefault)
        model.useHomeWorkspace()
        XCTAssertTrue(spin(until: { model.workspaceIsDefault }))
        XCTAssertEqual((host.settings["brain"] as? [String: Any])?["workspacePath"] as? String, "")
    }

    func testRepliesSettingsAndTestVoice() {
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertFalse(model.speakReplies)
        XCTAssertEqual(model.replyVoice, "kokoro")
        model.setSpeakReplies(true)
        XCTAssertTrue(spin(until: { (self.host.settings["voice"] as? [String: Any])?["speakReplies"] as? Bool == true }))
        XCTAssertTrue(spin(until: { model.speakReplies }))
        model.setReplyVoice("system")
        XCTAssertTrue(spin(until: { model.replyVoice == "system" }))
        XCTAssertEqual((host.settings["voice"] as? [String: Any])?["wakePhrase"] as? String, "Hey Computer", "other keys kept")

        model.testVoice()
        XCTAssertTrue(spin(until: { self.host.actions.contains { $0["name"] == "say" } }))
        XCTAssertEqual(host.actions.last?["text"], OnboardingModel.testPhrase)
        XCTAssertTrue(spin(until: { !model.saying }))
        XCTAssertNil(model.sayNote)

        // An older host without `say` says why.
        host.server.register("action") { _, done in done(["ok": false, "error": "unknown action say"]) }
        model.testVoice()
        XCTAssertTrue(spin(until: { model.sayNote == "unknown action say" }))
    }

    func testTestVoiceWhileVoiceIsDownSaysSo() {
        let model = makeModel()
        model.testVoice()
        XCTAssertEqual(model.sayNote, "Turn voice on first: replies are spoken by the voice host.")
        XCTAssertTrue(host.actions.isEmpty)
    }

    func testKokoroDownloadThroughModels() {
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.kokoro != nil }))
        XCTAssertEqual(model.kokoro, KokoroModelStatus(installed: false, bytes: 330_000_000))
        model.downloadKokoro()
        XCTAssertTrue(spin(until: { model.kokoro?.downloading == true }))
        XCTAssertTrue(modelRequests.contains { $0["action"] == "download" && $0["id"] == "kokoro" })
        models = ["installed": false, "downloading": true, "progress": 0.6]
        model.tick()   // Downloading: refreshed every tick.
        XCTAssertTrue(spin(until: { model.kokoro?.progress == 0.6 }))
        models = ["installed": true, "downloading": false, "progress": 1]
        model.tick()
        XCTAssertTrue(spin(until: { model.kokoro?.installed == true }))

        // An older host: no Kokoro state, and the reason.
        models = nil
        let older = makeModel()
        older.go(to: .brain)
        XCTAssertTrue(spin(until: { older.kokoroNote == "unknown command models" }))
        XCTAssertNil(older.kokoro)
    }

    func testMechaHUDOfferFindsItsCatalogRow() {
        let model = makeModel()
        XCTAssertNil(model.mechaHUD)
        apps.rows = [row(id: "xyz.machud.mechahud", name: "MechaHUD"), row(id: "xyz.machud.sift", name: "Sift")]
        XCTAssertEqual(model.mechaHUD?.id, "xyz.machud.mechahud")
    }

    // MARK: - Snapshots

    /// Renders every step offscreen (never on screen) into `MACHUD_ONBOARDING_SNAPSHOT_DIR`,
    /// else a temporary folder, and checks each image has the card drawn on it. The checklist
    /// is mid-way (some sections done, one skipped, the rest to do); `fresh-` shows the welcome
    /// checklist before anything, `after-` the radial menu once practised.
    func testSnapshotsEveryStep() throws {
        let model = makeModel()
        connect()
        let out = ProcessInfo.processInfo.environment["MACHUD_ONBOARDING_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("snapshots")
        brainReply?["problem"] = "Codex is not signed in. Run codex login in Terminal."
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try OnboardingSnapshot.write(model, shot: .init(file: "", step: .welcome), to: out.appendingPathComponent("onboarding-fresh-welcome.png"))

        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.brain != nil && model.kokoro != nil }))
        permissions.accessibility = true
        model.refreshPermissions()
        model.go(to: .voice)
        model.next()                       // Voice is on: done.
        model.skipSection()                // Brain: skipped.
        model.next()                       // Apps: done.
        model.go(to: .welcome)
        host.server.publish("state", payload: ["state": ["phase": ["name": "listening", "mode": "dictation"],
                                                         "inputLevel": 0.55, "partialTranscript": "Remind me to call Sam at four",
                                                         "muted": false, "brainAvailable": false]])
        XCTAssertTrue(spin(until: { model.live.isActive }))
        apps.rows = [row(id: "xyz.machud.sift", name: "Sift", summary: "A file manager that lives in the tool dock.", bundled: true),
                     row(id: "xyz.machud.stash", name: "Stash", summary: "A clipboard shelf for snippets and files.", bundled: true,
                         installed: "0.1.0"),
                     row(id: "xyz.machud.scratch", name: "Scratch", summary: "A quick notes pad.", phase: .downloading(0.4)),
                     row(id: "xyz.machud.mechahud", name: "MechaHUD", summary: "A dashboard for your agent sessions.", kind: "windowed")]
        apps.selected = ["xyz.machud.sift"]
        apps.catalogNote = "4 apps · checked just now"
        model.loadoutName = "Deep Work"
        model.captureLoadout()
        XCTAssertEqual(model.status(of: .loadout), .done)
        XCTAssertEqual(model.sectionsJSON, ["permissions": "todo", "voice": "done", "brain": "skipped", "apps": "done",
                                            "tooldock": "todo", "loadout": "done", "radial": "todo"])

        let urls = try OnboardingSnapshot.writeAll(model, to: out)
        XCTAssertEqual(urls.map(\.lastPathComponent), OnboardingSnapshot.shots.map(\.file))
        XCTAssertEqual(urls.count, OnboardingStep.allCases.count + 3)
        for (url, shot) in zip(urls, OnboardingSnapshot.shots) where shot.compact == nil {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(rep.size, OnboardingSnapshot.canvas)
            // The card's centre is glass, the corner the tinted desktop: they differ.
            let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            let corner = try XCTUnwrap(rep.colorAt(x: 4, y: rep.pixelsHigh - 60))
            XCTAssertNotEqual(centre, corner, url.lastPathComponent)
        }

        model.go(to: .radial)
        loadouts.apply("Deep Work", placed: 3)
        XCTAssertEqual(model.status(of: .radial), .done)
        try OnboardingSnapshot.write(model, shot: .init(file: "", step: .radial), to: out.appendingPathComponent("onboarding-after-radial.png"))
        try OnboardingSnapshot.write(model, shot: .init(file: "", step: .done), to: out.appendingPathComponent("onboarding-after-done.png"))
        XCTAssertEqual(model.step, .radial, "snapshots do not move the overlay")
    }

    private func row(id: String, name: String, summary: String? = nil, bundled: Bool = false, installed: String? = nil,
                     phase: AppInstaller.Phase? = nil, kind: String = "hover") -> AppsTabModel.Row {
        let entry = CatalogEntry(id: id, name: name, kind: kind, summary: summary, version: "0.1.0", bundled: bundled)
        let copy = installed.map { InstalledCopy(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: id, version: $0) }
        return .init(status: CatalogAppStatus(entry: entry, installed: copy, running: false), iconURL: nil, phase: phase)
    }
}
