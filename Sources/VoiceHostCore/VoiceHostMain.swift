import AppKit
import BrainKit
import HUDKit
import VoiceKit

/// Process entry for the voice host.
public enum VoiceHostMain {
    /// Keychain service the voice secrets (the Grok key) are stored under.
    public static let secretsService = "com.jrisberg.machud.voice"

    /// Builds the host from the process environment (`VoiceHostEnvironment`), serves the
    /// `machud-voice` socket and runs the app loop. `makePresenter` draws the state and sends
    /// the user's input back through the `VoiceHostActing` it is given.
    @MainActor
    public static func run(makePresenter: @escaping @MainActor (VoiceHostActing) -> VoiceHostPresenting) -> Never {
        // SpeakFree's developer marker would keep every recording; the voice host keeps none.
        setenv("SPEAKFREE_DEV_MODE", "0", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = VoiceHost(environment: VoiceHostEnvironment())
        host.start(presenter: makePresenter(host.controller))
        withExtendedLifetime(host) { app.run() }
        exit(0)
    }
}

/// A presenter that draws nothing.
@MainActor
public final class HeadlessVoicePresenter: VoiceHostPresenting {
    public init() {}
    public func render(_ state: VoiceHostState) {}
}

/// Everything one voice host process runs.
@MainActor
final class VoiceHost {
    let environment: VoiceHostEnvironment
    let controller: VoiceHostController
    private let server: HUDSocketServer
    private let commands: VoiceHostCommands
    private let brain: BrainConnection?
    private let dictation: DictationDriving
    private let models: VoiceModelProviding
    private let fullscreen = HUDFullscreenObserver()
    private var terminationSource: DispatchSourceSignal?

    init(environment: VoiceHostEnvironment) {
        self.environment = environment
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacHUD")
        let voiceRoot = support.appendingPathComponent("Voice")
        let modelsRoot = environment.modelsDirectory ?? voiceRoot.appendingPathComponent("Models")
        let secrets = KeychainVoiceSecretStore(service: environment.keychainService)
        let store = VoiceHostSettingsStore(directory: environment.configDirectory)

        dictation = environment.noMicrophone
            ? SimulatedDictation()
            : SpeakFreeDictation(directory: voiceRoot.appendingPathComponent("Dictation"))
        brain = environment.noBrain ? nil : BrainConnection()
        let kokoroDirectory = KokoroModels.directory(in: modelsRoot)
        models = KokoroModelStore(directory: kokoroDirectory)
        controller = VoiceHostController(
            settings: store.load(), dictation: dictation,
            keys: environment.noHotkeys ? nil : FnKeySource(), brain: brain,
            speaker: environment.noSpeech
                ? SilentSpeaker() : ReplySpeaker(kokoroDirectory: kokoroDirectory, secrets: secrets),
            wake: environment.noMicrophone ? nil : WakeWordListener(modelsRoot: modelsRoot),
            brainStateRoot: support.appendingPathComponent("Brain"),
            sessions: MacHUDSessions(socketPath: environment.machudSocketPath))
        server = HUDSocketServer(path: environment.socketPath, label: "machud-voice")
        commands = VoiceHostCommands(controller: controller, store: store, secrets: secrets,
                                     version: Self.version(), models: models)
    }

    func start(presenter: VoiceHostPresenting) {
        let server = self.server
        controller.onStateChange = { VoiceHostCommands.publish($0, on: server) }
        models.onChange = { [weak self] in
            guard let self else { return }
            VoiceHostCommands.publishModels(models.status, on: server)
        }
        controller.presenter = presenter
        commands.onQuit = { [weak self] in self?.shutDown() }
        commands.install(on: server)
        guard server.start() else {
            NSLog("MacHUDVoice: cannot listen on %@ (in use by another voice host, or unusable)", server.path)
            exit(1)
        }
        controller.start()
        fullscreen.onChange = { [weak self] _ in self?.updateFullScreen() }
        fullscreen.start()
        updateFullScreen()
        if environment.parentPipe { watchParentPipe() }
        handleTermination()
    }

    /// Throws away a take being recorded, stops the socket and the brain, then exits.
    func shutDown() -> Never {
        dictation.cancel()
        server.stop()
        brain?.configure(nil)
        exit(0)
    }

    /// SIGTERM (MacHUD stopping the host) shuts down the same way as `quit`.
    private func handleTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.shutDown() } }
        source.resume()
        terminationSource = source
    }

    /// The orb sits on the primary (menu-bar) screen; see `VoiceOrbScreen`.
    private func updateFullScreen() {
        let screen = VoiceOrbScreen.current()
        controller.setHiddenForFullScreen(screen.map { fullscreen.isFullScreen(screenID: HUDScreenSnapshot.id(for: $0)) } ?? false)
    }

    /// MacHUD holds our stdin open; end-of-file means it is gone, so the host goes too.
    private func watchParentPipe() {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 256)
            while read(STDIN_FILENO, &buffer, buffer.count) > 0 {}
            DispatchQueue.main.async { MainActor.assumeIsolated { self.shutDown() } }
        }
    }

    /// The enclosing MacHUD's version (`Contents/Helpers/MacHUDVoice` → `Contents/Info.plist`),
    /// or "dev" outside an app bundle.
    static func version() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return version
        }
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
