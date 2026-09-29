import Foundation

/// Keeps the voice host (`MacHUDVoice`) running as MacHUD's child: starts it when voice is on,
/// restarts it with backoff when it dies, and stops it when voice is turned off or MacHUD quits.
/// The voice host is built in, so there is no dock button; its state is `voice status`.
@MainActor
final class VoiceHostSupervisor {
    enum Status: Equatable {
        /// `enabled` is off in voice.json.
        case disabled
        /// No helper next to the MacHUD binary.
        case notInstalled
        case running(pid: Int32)
        /// It exited; the next launch is scheduled.
        case restarting(after: TimeInterval)
        /// Stopped on purpose (MacHUD quitting, or `stop()`).
        case stopped
        /// It kept dying quickly; `start()` tries again.
        case failed(String)

        var name: String {
            switch self {
            case .disabled: return "disabled"
            case .notInstalled: return "notInstalled"
            case .running: return "running"
            case .restarting: return "restarting"
            case .stopped: return "stopped"
            case .failed: return "failed"
            }
        }

        /// A sentence for the settings tabs and the menu.
        var text: String {
            switch self {
            case .disabled: return "Voice is off."
            case .notInstalled: return "The voice host is not part of this build of MacHUD."
            case .running: return "The voice host is starting."
            case .restarting(let delay): return "The voice host stopped; restarting in \(Int(delay.rounded())) s."
            case .stopped: return "The voice host is stopped."
            case .failed(let why): return "The voice host keeps failing: \(why)"
            }
        }
    }

    /// The Keychain service an isolated instance's host keeps secrets under, so a test never
    /// reads or overwrites the user's Grok key.
    static let isolatedKeychainService = "com.jrisberg.machud.voice.isolated"

    /// Where an isolated instance's host keeps downloaded models: beside its own socket, so a
    /// test never reads, verifies or writes the real models folder.
    static func isolatedModelsDirectory(socketPath: String) -> String {
        (socketPath as NSString).deletingPathExtension + "-models"
    }

    /// A run at least this long counts as healthy and resets the backoff.
    static let stableRun: TimeInterval = 20
    /// Quick exits in a row before giving up.
    static let maxQuickRestarts = 5

    private(set) var status: Status = .stopped {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?
    let socketPath: String
    var now: () -> Date = Date.init

    private let launcher: VoiceHostLaunching
    private let helper: () -> URL?
    private let isEnabled: () -> Bool
    private let environment: [String: String]
    private let isolated: Bool
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var child: VoiceHostChild?
    private var launchedAt: Date?
    /// Bumped on every launch and stop, so a late exit or a stale restart is ignored.
    private var generation = 0
    private var quickExits = 0

    /// - Parameters:
    ///   - helper: the executable to run (`VoiceHostPaths.helperURL`), nil when there is none.
    ///   - isEnabled: voice.json's `enabled`, read at each start.
    ///   - environment: MacHUD's environment, passed through (`MACHUD_CONFIG`, `MACHUD_NO_HOTKEYS`
    ///     and the `MACHUD_VOICE_*` switches included).
    ///   - isolated: MacHUD is a test instance (`Env.isIsolated`); see `childEnvironment()`.
    init(launcher: VoiceHostLaunching, helper: @escaping () -> URL?, isEnabled: @escaping () -> Bool,
         socketPath: String, environment: [String: String], isolated: Bool,
         schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil) {
        self.launcher = launcher
        self.helper = helper
        self.isEnabled = isEnabled
        self.socketPath = socketPath
        self.environment = environment
        self.isolated = isolated
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    }

    var pid: Int32? { if case .running(let pid) = status { return pid }; return nil }
    var isRunning: Bool { pid != nil }
    /// Stopped or given up: `start()` brings it back (the menu's Restart, the tabs' Retry).
    var canRestart: Bool {
        switch status {
        case .stopped, .failed: return true
        default: return false
        }
    }

    /// Starts the host unless it is running, voice is off (`force` starts it anyway, to turn
    /// voice on through its own socket) or there is no helper. Clears a previous give-up.
    func start(force: Bool = false) {
        guard !isRunning else { return }
        guard force || isEnabled() else { cancelPending(); status = .disabled; return }
        quickExits = 0
        launch()
    }

    /// Stops the host for good (no restart).
    func stop() { halt(as: .stopped) }

    /// The host stored new settings: follow `enabled`.
    func settingsChanged(enabled: Bool) {
        if enabled { start(force: true) } else { halt(as: .disabled) }
    }

    /// The environment the helper runs with. A host started by an isolated MacHUD never touches
    /// what the real one owns: it runs with no microphone, no brain, no orb on screen, no sound
    /// and its own models folder unless `MACHUD_VOICE_LIVE=1`, and keeps secrets under its own
    /// Keychain service unless `MACHUD_VOICE_KEYCHAIN_SERVICE` names one.
    func childEnvironment() -> [String: String] {
        var env = environment
        env["MACHUD_VOICE_PARENT_PIPE"] = "1"
        env["MACHUD_VOICE_SOCKET"] = socketPath
        if isolated {
            if env["MACHUD_VOICE_LIVE"] != "1" {
                for key in ["MACHUD_VOICE_NO_MIC", "MACHUD_VOICE_NO_BRAIN", "MACHUD_VOICE_HEADLESS", "MACHUD_VOICE_NO_SPEECH"] {
                    env[key] = "1"
                }
                if (env["MACHUD_VOICE_MODELS_DIR"] ?? "").isEmpty {
                    env["MACHUD_VOICE_MODELS_DIR"] = Self.isolatedModelsDirectory(socketPath: socketPath)
                }
            }
            if (env["MACHUD_VOICE_KEYCHAIN_SERVICE"] ?? "").isEmpty {
                env["MACHUD_VOICE_KEYCHAIN_SERVICE"] = Self.isolatedKeychainService
            }
        }
        return env
    }

    private func halt(as final: Status) {
        cancelPending()
        let running = child
        child = nil
        status = final
        running?.terminate()
    }

    private func cancelPending() { generation += 1 }

    private func launch() {
        guard let executable = helper() else { status = .notInstalled; return }
        generation += 1
        let current = generation
        do {
            let started = try launcher.launch(executable, environment: childEnvironment()) { [weak self] code in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.exited(generation: current, code: code) }
                }
            }
            child = started
            launchedAt = now()
            status = .running(pid: started.pid)
            NSLog("MacHUD: voice host started (pid %d)", started.pid)
        } catch {
            NSLog("MacHUD: voice host failed to start: %@", "\(error)")
            launchedAt = now()
            scheduleRestart(generation: current, reason: "\(error)")
        }
    }

    private func exited(generation current: Int, code: Int32) {
        guard current == generation else { return }
        child = nil
        NSLog("MacHUD: voice host exited (%d)", code)
        scheduleRestart(generation: current, reason: "exited with status \(code)")
    }

    private func scheduleRestart(generation current: Int, reason: String) {
        let ran = launchedAt.map { now().timeIntervalSince($0) } ?? 0
        quickExits = ran >= Self.stableRun ? 1 : quickExits + 1
        guard quickExits <= Self.maxQuickRestarts else {
            status = .failed(reason)
            return
        }
        let delay = min(30, pow(2, Double(quickExits - 1)))
        status = .restarting(after: delay)
        schedule(delay) { [weak self] in
            guard let self, self.generation == current else { return }
            self.launch()
        }
    }
}
