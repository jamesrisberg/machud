import XCTest
@testable import MacHUDCore

/// A launcher that records launches and lets the test end a child by hand.
@MainActor
final class FakeVoiceLauncher: VoiceHostLaunching {
    final class Child: VoiceHostChild {
        let pid: Int32
        let onExit: @Sendable (Int32) -> Void
        var terminated = false
        init(pid: Int32, onExit: @escaping @Sendable (Int32) -> Void) {
            self.pid = pid
            self.onExit = onExit
        }
        func terminate() {
            terminated = true
            onExit(15)
        }
        /// The helper dies on its own (a crash).
        func crash() { onExit(6) }
    }

    var launches: [(executable: URL, environment: [String: String])] = []
    var children: [Child] = []
    var failNext: Error?

    nonisolated init() {}

    func launch(_ executable: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> VoiceHostChild {
        if let error = failNext { failNext = nil; throw error }
        launches.append((executable, environment))
        let child = Child(pid: Int32(1000 + children.count), onExit: onExit)
        children.append(child)
        return child
    }
}

@MainActor
final class VoiceHostSupervisorTests: XCTestCase {
    private var launcher: FakeVoiceLauncher!
    private var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var enabled = true
    private let helper = URL(fileURLWithPath: "/Apps/MacHUD.app/Contents/Helpers/MacHUDVoice")

    override func setUp() {
        launcher = FakeVoiceLauncher()
        scheduled = []
        enabled = true
    }

    private func makeSupervisor(helper: URL? = nil, environment: [String: String] = ["PATH": "/usr/bin"]) -> VoiceHostSupervisor {
        let supervisor = VoiceHostSupervisor(
            launcher: launcher, helper: { [helper = helper ?? self.helper] in helper },
            isEnabled: { [unowned self] in self.enabled },
            socketPath: "/tmp/voice-test.sock", environment: environment,
            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) })
        supervisor.now = { [unowned self] in self.clock }
        return supervisor
    }

    private func runScheduled() {
        let due = scheduled
        scheduled = []
        for item in due { item.work() }
    }

    /// The exit arrives off the main thread in the real launcher; the supervisor hops back.
    private func settle() { _ = spin(until: { false }, timeout: 0.05) }

    func testStartLaunchesTheHelperWithTheParentPipeAndSocket() {
        let supervisor = makeSupervisor(environment: ["PATH": "/usr/bin", "MACHUD_CONFIG": "/tmp/c/layouts.json",
                                                      "MACHUD_NO_HOTKEYS": "1"])
        supervisor.start()
        XCTAssertEqual(launcher.launches.count, 1)
        let launch = launcher.launches[0]
        XCTAssertEqual(launch.executable, helper)
        XCTAssertEqual(launch.environment["MACHUD_VOICE_PARENT_PIPE"], "1")
        XCTAssertEqual(launch.environment["MACHUD_VOICE_SOCKET"], "/tmp/voice-test.sock")
        XCTAssertEqual(launch.environment["MACHUD_CONFIG"], "/tmp/c/layouts.json", "isolation passes through")
        XCTAssertEqual(launch.environment["MACHUD_NO_HOTKEYS"], "1")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertEqual(supervisor.status, .running(pid: 1000))
    }

    func testDisabledIsNotStarted() {
        enabled = false
        let supervisor = makeSupervisor()
        supervisor.start()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(supervisor.status, .disabled)
    }

    func testMissingHelperIsReported() {
        let supervisor = VoiceHostSupervisor(launcher: launcher, helper: { nil }, isEnabled: { true },
                                             socketPath: "/tmp/v.sock", environment: [:], schedule: { _, _ in })
        supervisor.start()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(supervisor.status, .notInstalled)
    }

    func testCrashRestartsWithBackoff() {
        let supervisor = makeSupervisor()
        supervisor.start()
        launcher.children[0].crash()
        settle()
        XCTAssertEqual(scheduled.map(\.delay), [1])
        XCTAssertEqual(supervisor.status, .restarting(after: 1))
        runScheduled()
        XCTAssertEqual(launcher.launches.count, 2)

        launcher.children[1].crash()
        settle()
        XCTAssertEqual(scheduled.map(\.delay), [2], "the delay doubles for a quick crash")
        runScheduled()
        launcher.children[2].crash()
        settle()
        XCTAssertEqual(scheduled.map(\.delay), [4])
    }

    func testALongRunResetsTheBackoff() {
        let supervisor = makeSupervisor()
        supervisor.start()
        launcher.children[0].crash()
        settle()
        runScheduled()
        clock += VoiceHostSupervisor.stableRun + 1
        launcher.children[1].crash()
        settle()
        XCTAssertEqual(scheduled.map(\.delay), [1])
    }

    func testGivesUpAfterRepeatedQuickCrashes() {
        let supervisor = makeSupervisor()
        supervisor.start()
        for i in 0..<VoiceHostSupervisor.maxQuickRestarts {
            launcher.children[i].crash()
            settle()
            runScheduled()
        }
        launcher.children.last!.crash()
        settle()
        XCTAssertTrue(scheduled.isEmpty)
        guard case .failed = supervisor.status else { return XCTFail("status \(supervisor.status)") }
        supervisor.start()
        XCTAssertEqual(launcher.launches.count, VoiceHostSupervisor.maxQuickRestarts + 2, "start() tries again")
    }

    func testStopTerminatesWithoutRestart() {
        let supervisor = makeSupervisor()
        supervisor.start()
        supervisor.stop()
        settle()
        XCTAssertTrue(launcher.children[0].terminated)
        XCTAssertTrue(scheduled.isEmpty)
        XCTAssertEqual(supervisor.status, .stopped)
    }

    func testTurningOffStopsAndTurningOnStarts() {
        let supervisor = makeSupervisor()
        supervisor.start()
        enabled = false
        supervisor.settingsChanged(enabled: false)
        settle()
        XCTAssertTrue(launcher.children[0].terminated)
        XCTAssertEqual(supervisor.status, .disabled)
        XCTAssertTrue(scheduled.isEmpty)

        enabled = true
        supervisor.settingsChanged(enabled: true)
        XCTAssertEqual(launcher.launches.count, 2)
        supervisor.settingsChanged(enabled: true)
        XCTAssertEqual(launcher.launches.count, 2, "already running")
    }

    func testForcedStartIgnoresTheStoredSwitch() {
        enabled = false
        let supervisor = makeSupervisor()
        supervisor.start(force: true)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testLaunchFailureRetries() {
        launcher.failNext = CocoaError(.fileNoSuchFile)
        let supervisor = makeSupervisor()
        supervisor.start()
        XCTAssertEqual(scheduled.map(\.delay), [1])
        runScheduled()
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testStatusChangesAreReported() {
        let supervisor = makeSupervisor()
        var seen: [VoiceHostSupervisor.Status] = []
        supervisor.onStatusChange = { seen.append($0) }
        supervisor.start()
        supervisor.stop()
        settle()
        XCTAssertEqual(seen, [.running(pid: 1000), .stopped])
    }
}

/// Paths and switches the supervisor reads.
final class VoiceHostPathsTests: XCTestCase {
    func testSocketPathPrefersTheOverride() {
        XCTAssertEqual(VoiceHostPaths.socketPath(environment: ["MACHUD_VOICE_SOCKET": "/tmp/x.sock", "MACHUD_SOCKET": "/tmp/m.sock"]),
                       "/tmp/x.sock")
    }

    func testIsolatedInstanceGetsItsOwnSocket() {
        XCTAssertEqual(VoiceHostPaths.socketPath(environment: ["MACHUD_SOCKET": "/tmp/machud-test.sock"]),
                       "/tmp/machud-test-voice.sock")
        XCTAssertEqual(VoiceHostPaths.socketPath(environment: ["MACHUD_CONFIG": "/tmp/t/layouts.json"]),
                       "/tmp/t/machud-voice.sock")
    }

    func testDefaultInstanceUsesTheSharedSocketDirectory() {
        XCTAssertTrue(VoiceHostPaths.socketPath(environment: [:]).hasSuffix("MacHUD/sockets/machud-voice.sock"))
    }

    func testHelperIsFoundInHelpersThenBesideTheBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let macos = dir.appendingPathComponent("MacHUD.app/Contents/MacOS")
        let helpers = dir.appendingPathComponent("MacHUD.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let binary = macos.appendingPathComponent("MacHUD")
        XCTAssertNil(VoiceHostPaths.helperURL(executable: binary))

        let beside = macos.appendingPathComponent("MacHUDVoice")
        try makeExecutable(beside)
        XCTAssertEqual(VoiceHostPaths.helperURL(executable: binary)?.path, beside.path, ".build runs")

        let bundled = helpers.appendingPathComponent("MacHUDVoice")
        try makeExecutable(bundled)
        XCTAssertEqual(VoiceHostPaths.helperURL(executable: binary)?.standardizedFileURL.path, bundled.path)
    }

    func testEnabledReadsVoiceJSONAndDefaultsOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("voice.json")
        XCTAssertTrue(VoiceHostPaths.isEnabled(settingsURL: url), "no file yet")
        try Data(#"{"enabled": false, "keyMode": "hold"}"#.utf8).write(to: url)
        XCTAssertFalse(VoiceHostPaths.isEnabled(settingsURL: url))
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(VoiceHostPaths.isEnabled(settingsURL: url), "the host decodes leniently; so does MacHUD")
    }

    private func makeExecutable(_ url: URL) throws {
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// The real launcher against a shell script standing in for the helper.
@MainActor
final class ChildProcessLauncherTests: XCTestCase {
    func testChildSeesEOFWhenTheParentLetsGo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-child-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("fake-helper")
        let marker = dir.appendingPathComponent("env")
        // Records its environment, then waits for stdin to close, as the parent-pipe host does.
        try Data("#!/bin/sh\necho \"$MACHUD_VOICE_PARENT_PIPE $MACHUD_VOICE_SOCKET\" > '\(marker.path)'\ncat > /dev/null\nexit 0\n".utf8)
            .write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let exited = expectation(description: "exited")
        let status = LockedBox<Int32?>(nil)
        let child = try ChildProcessLauncher().launch(script, environment: ["MACHUD_VOICE_PARENT_PIPE": "1",
                                                                            "MACHUD_VOICE_SOCKET": "/tmp/v.sock"]) {
            status.value = $0
            exited.fulfill()
        }
        XCTAssertGreaterThan(child.pid, 0)
        XCTAssertTrue(spin(until: { FileManager.default.fileExists(atPath: marker.path) }))
        XCTAssertNil(status.value, "still waiting on stdin")
        (child as! ChildProcessLauncher.Child).closeParentPipe()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(status.value, 0, "exits by itself on EOF, not by a signal")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "1 /tmp/v.sock\n")
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
