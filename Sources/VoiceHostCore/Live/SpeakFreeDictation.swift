import Foundation
import SpeakFreeLib

/// Dictation through SpeakFree's `DictationSession` and Parakeet engine, using a model already
/// downloaded into FluidAudio's cache (SpeakFree's download; the voice host downloads none).
///
/// Retention is off and nothing lands in SpeakFree's own folders: SpeakFreeLib's config
/// directory is pointed at `directory` for this process, so a take's WAV is written there and
/// deleted when the take ends (the config written there keeps `saveRecordings` off). The
/// process also sets `SPEAKFREE_DEV_MODE=0` before this runs, because SpeakFree's developer
/// marker (`~/.speakfree-dev`) would otherwise keep every recording.
@MainActor
final class SpeakFreeDictation: DictationDriving {
    var onUpdate: ((UUID, DictationUpdate) -> Void)?
    var isCapturing: Bool { session.isCapturing }

    /// SpeakFree's English default first, then its multilingual model.
    static let parakeetModels = [Config.defaultParakeetModel, "parakeet-tdt-0.6b-v3"]

    private let session: DictationSession

    init(directory: URL) {
        Config.configDirOverride = directory
        let config = Config.load()
        session = DictationSession(recorder: AudioRecorder(), inserter: TextInserter())
        session.configuration = DictationConfiguration(config: config)
        session.configuration.saveRecordings = false
        session.levelEventInterval = 0.05
        if let model = Self.parakeetModels.first(where: { ParakeetModelManager.shared.isModelDownloaded($0) }) {
            let transcriber = Transcriber(engine: ParakeetEngine(), modelID: model, language: config.language)
            session.transcriber = transcriber
            session.engineID = "parakeet"
            // A cold Parakeet load takes seconds; do it before the first take needs it.
            Task.detached(priority: .utility) { await transcriber.warmUp() }
        }
        session.isEnabled = true
        session.addObserver { [weak self] id, event in self?.forward(event, take: id) }
    }

    func start(_ destination: DictationDestination) -> DictationStartOutcome {
        guard session.transcriber != nil else { return .refused(.modelMissing(recordingKept: false)) }
        return session.start(destination: destination)
    }

    func retarget(_ destination: DictationDestination) { session.retarget(to: destination) }
    func stop() { session.stopRecording() }
    func cancel() { session.cancel() }

    private func forward(_ event: DictationEvent, take id: UUID) {
        let update: DictationUpdate
        switch event {
        case .recording, .resumed:
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
            update = .finished(text: text, destination: result.destination)
        case .failed(let failure):
            update = .failed(failure)
        case .cancelled:
            update = .failed(.cancelled)
        default:
            return
        }
        onUpdate?(id, update)
    }
}
