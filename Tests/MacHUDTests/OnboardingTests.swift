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
        XCTAssertTrue(host.server.start())
        let supervisor = VoiceHostSupervisor(launcher: FakeVoiceLauncher(), helper: { URL(fileURLWithPath: "/x/MacHUDVoice") },
                                             isEnabled: { true }, socketPath: path, environment: [:], isolated: false,
                                             schedule: { _, _ in })
        voice = VoiceServices(supervisor: supervisor, socketPath: path)
        permissions = FakeOnboardingPermissions()
        apps = AppsTabModel()
        presenter = FakeOnboardingPresenter()
    }

    override func tearDownWithError() throws {
        voice.stop()
        host.server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() -> OnboardingModel {
        OnboardingModel(voice: voice, apps: apps, permissions: permissions)
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
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), ["welcome", "permissions", "voice", "brain", "apps", "tour"])
        XCTAssertEqual(OnboardingStep.welcome.next, .permissions)
        XCTAssertNil(OnboardingStep.tour.next)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertEqual(OnboardingStep.apps.previous, .brain)
    }

    func testStoreWantsLaunchUntilFinishedOrSkipped() {
        let store = OnboardingStore(url: dir.appendingPathComponent("state/onboarding.json"))
        XCTAssertNil(store.load())
        XCTAssertTrue(store.wantsLaunch, "never ran")
        store.save(.inProgress, step: .brain)
        XCTAssertEqual(store.load()?.step, .brain)
        XCTAssertTrue(store.wantsLaunch, "left unfinished")
        store.save(.completed, step: .tour)
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
        XCTAssertEqual(services.store.load(), OnboardingRecord(status: .inProgress, step: .voice, updatedAt: services.store.load()?.updatedAt))

        // Next launch: a fresh model resumes at Voice.
        let again = makeServices()
        XCTAssertTrue(again.showIfNeeded())
        XCTAssertEqual(again.model.step, .voice)
    }

    func testFinishingOrSkippingStopsLaunchShows() {
        let services = makeServices()
        services.show(step: .tour)
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

    func testMechaHUDOfferFindsItsCatalogRow() {
        let model = makeModel()
        XCTAssertNil(model.mechaHUD)
        apps.rows = [row(id: "xyz.machud.mechahud", name: "MechaHUD"), row(id: "xyz.machud.sift", name: "Sift")]
        XCTAssertEqual(model.mechaHUD?.id, "xyz.machud.mechahud")
    }

    // MARK: - Snapshots

    /// Renders every step offscreen (never on screen) into `MACHUD_ONBOARDING_SNAPSHOT_DIR`,
    /// else a temporary folder, and checks each image has the card drawn on it.
    func testSnapshotsEveryStep() throws {
        let model = makeModel()
        connect()
        model.go(to: .brain)
        XCTAssertTrue(spin(until: { model.brain != nil }))
        model.go(to: .welcome)
        permissions.accessibility = true
        model.refreshPermissions()
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

        let out = ProcessInfo.processInfo.environment["MACHUD_ONBOARDING_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("snapshots")
        let urls = try OnboardingSnapshot.writeAll(model, to: out)
        XCTAssertEqual(urls.map(\.lastPathComponent), OnboardingStep.allCases.map { "onboarding-\($0.index + 1)-\($0.rawValue).png" })
        for url in urls {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertEqual(rep.size, OnboardingSnapshot.canvas)
            // The card's centre is dark glass, the corner the dimmed desktop: they differ.
            let centre = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
            let corner = try XCTUnwrap(rep.colorAt(x: 4, y: rep.pixelsHigh - 60))
            XCTAssertNotEqual(centre, corner, url.lastPathComponent)
        }
        XCTAssertEqual(model.step, .welcome, "snapshots do not move the overlay")
    }

    private func row(id: String, name: String, summary: String? = nil, bundled: Bool = false, installed: String? = nil,
                     phase: AppInstaller.Phase? = nil, kind: String = "hover") -> AppsTabModel.Row {
        let entry = CatalogEntry(id: id, name: name, kind: kind, summary: summary, version: "0.1.0", bundled: bundled)
        let copy = installed.map { InstalledCopy(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), bundleID: id, version: $0) }
        return .init(status: CatalogAppStatus(entry: entry, installed: copy, running: false), iconURL: nil, phase: phase)
    }
}
