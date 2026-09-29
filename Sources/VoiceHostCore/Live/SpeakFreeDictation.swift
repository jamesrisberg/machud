import AVFoundation
import Foundation
import SpeakFreeLib

/// Dictation through SpeakFree's `DictationSession` and Parakeet engine, using a model in
/// FluidAudio's cache (SpeakFree's download, or `ParakeetModelStore`'s; the same folder).
///
/// Nothing lands in SpeakFree's own folders by itself: SpeakFreeLib's config directory is
/// pointed at `directory` for this process, so a take's WAV and its sidecars are written in the
/// scratch folder `directory/recordings`. Retention follows the history setting: while it keeps
/// anything the take is kept there (SpeakFree's `finishRecording` writes the transcript
/// sidecars) and `DictationHistoryFiler` then moves it into the history folder; while it is off
/// the WAV is deleted when the take ends. Whatever is left in the scratch folder (a failed take,
/// a crashed host's recording, the in-progress marker) is deleted at start and whenever no take
/// is in flight. The process also sets `SPEAKFREE_DEV_MODE=0` before this runs, because
/// SpeakFree's developer marker (`~/.speakfree-dev`) would otherwise keep every recording.
@MainActor
final class SpeakFreeDictation: DictationDriving {
    var onUpdate: ((UUID, DictationUpdate) -> Void)?
    var isCapturing: Bool { session.isCapturing }

    /// SpeakFree's English default first, then its multilingual model.
    nonisolated static let parakeetModels = [Config.defaultParakeetModel, "parakeet-tdt-0.6b-v3"]

    private let session: DictationSession
    private let directory: URL
    private let language: String
    private let history: HistoryBox
    /// Takes started and not yet finished, failed or cancelled.
    private var inFlight: Set<UUID> = []

    init(directory: URL, historyLocator: DictationHistoryLocator) {
        Config.configDirOverride = directory
        self.directory = directory
        Self.removeLeftovers(in: directory)
        let config = Config.load()
        language = config.language
        let history = HistoryBox(locator: historyLocator)
        self.history = history
        session = DictationSession(recorder: AudioRecorder(), inserter: TextInserter(),
                                   retentionConfig: { history.retentionConfig() })
        session.configuration = DictationConfiguration(config: config)
        // Recordings that fail the length or silence gates are never kept.
        session.configuration.saveRecordings = false
        session.levelEventInterval = 0.05
        session.isEnabled = true
        prepareEngine()
        session.addObserver { [weak self] id, event in self?.forward(event, take: id) }
        // SpeakFree's recorder captures nothing until its engine is started; start it as soon
        // as the microphone is allowed (asking once if macOS hasn't decided yet), honouring the
        // pre-buffer setting that keeps the first word from being clipped.
        session.recorder.preBufferEnabled = config.preBuffer?.value ?? true
        Self.whenMicrophoneAllowed { [recorder = session.recorder] in recorder.warmUp() }
    }

    /// Picks up an installed Parakeet model: at start, after `models download`, and before a
    /// take while none was found (SpeakFree may have downloaded one meanwhile).
    func prepareEngine() {
        guard session.transcriber == nil,
              let model = Self.parakeetModels.first(where: { ParakeetModelManager.shared.isModelDownloaded($0) })
        else { return }
        let transcriber = Transcriber(engine: ParakeetEngine(), modelID: model, language: language)
        session.transcriber = transcriber
        session.engineID = "parakeet"
        // A cold Parakeet load takes seconds; do it before the first take needs it.
        Task.detached(priority: .utility) { await transcriber.warmUp() }
    }

    func setHistory(_ settings: DictationHistorySettings?) {
        history.update(settings)
    }

    /// Runs `start` on the main thread once microphone access is granted: at once when it
    /// already is, after the system prompt when undetermined, never when denied.
    private static func whenMicrophoneAllowed(_ start: @escaping @MainActor () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            MainActor.assumeIsolated { start() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                guard granted else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { start() } }
            }
        default:
            break
        }
    }

    /// What a finished take's retention follows: SpeakFree's defaults, kept while the history
    /// keeps anything, never pruned (the scratch folder holds only takes in flight).
    nonisolated static func retentionConfig(keep: Bool) -> Config {
        var config = Config.defaultConfig
        config.saveRecordings = FlexBool(keep)
        config.preserveAllRecordings = FlexBool(true)
        return config
    }

    /// Recordings and the in-progress marker a crashed or killed host, or a failed take, left behind.
    static func removeLeftovers(in directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory.appendingPathComponent("recordings"))
        try? fileManager.removeItem(at: directory.appendingPathComponent(".recording-in-progress.json"))
    }

    func start(_ destination: DictationDestination) -> DictationStartOutcome {
        prepareEngine()
        guard session.transcriber != nil else { return .refused(.modelMissing(recordingKept: false)) }
        history.refresh()
        return session.start(destination: destination)
    }

    func retarget(_ destination: DictationDestination) { session.retarget(to: destination) }
    func stop() { session.stopRecording() }
    func cancel() { session.cancel() }
    func insert(_ text: String) { _ = session.inserter.insert(text: text) }

    private func forward(_ event: DictationEvent, take id: UUID) {
        let update: DictationUpdate
        switch event {
        case .recording, .resumed:
            inFlight.insert(id)
            update = .recording(session.currentDestination ?? .cursor)
        case .retargeted(let destination):
            update = .retargeted(destination)
        case .inputLevel(let level):
            update = .level(Double(level))
        case .partialText(let text):
            update = .partial(text)
        case .partialTextCleared:
            update = .partial("")
        case .captureEnded:
            update = .transcribing
        case .finished(let result):
            // The agent gets the words as spoken (punctuation and glossary applied); the cursor
            // got the styled text already.
            let text = result.destination == .caller ? result.processed : result.styled
            if result.recordingKept { DictationHistoryFiler.file(recording: result.audioURL, plan: history.plan) }
            update = .finished(text: text, destination: result.destination, transcript: result.processed)
            takeEnded(id)
        case .failed(let failure):
            update = .failed(failure)
            takeEnded(id)
        case .cancelled:
            update = .failed(.cancelled)
            takeEnded(id)
        default:
            return
        }
        onUpdate?(id, update)
    }

    /// With no take in flight, the scratch folder holds nothing anyone needs.
    private func takeEnded(_ id: UUID) {
        inFlight.remove(id)
        guard inFlight.isEmpty, !session.isCapturing else { return }
        Self.removeLeftovers(in: directory)
    }
}

/// The history plan the retention closure (off the main thread) and the filer (on it) share.
/// The plan is resolved on the main thread, when the setting changes and as each take starts.
private final class HistoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private let locator: DictationHistoryLocator
    private var settings: DictationHistorySettings?
    private var current: DictationHistoryPlan

    init(locator: DictationHistoryLocator) {
        self.locator = locator
        current = locator.plan(for: nil)
    }

    var plan: DictationHistoryPlan { lock.withLock { current } }

    func update(_ settings: DictationHistorySettings?) {
        lock.withLock { self.settings = settings }
        refresh()
    }

    /// Resolves the plan again (SpeakFree installed or removed, its own choice changed).
    func refresh() {
        let settings = lock.withLock { self.settings }
        let plan = locator.plan(for: settings)
        lock.withLock { current = plan }
    }

    func retentionConfig() -> Config {
        SpeakFreeDictation.retentionConfig(keep: plan.keeps)
    }
}
