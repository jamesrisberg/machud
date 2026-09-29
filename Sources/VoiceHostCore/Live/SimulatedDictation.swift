import Foundation
import SpeakFreeLib

/// The capture path under `MACHUD_VOICE_NO_MIC=1`: takes behave like real ones (levels, a
/// transcript, the post-capture phases) without opening the microphone, transcribing or typing,
/// so MacHUD and the orchestrator can run an isolated voice host.
///
/// Levels are speech for `speechDuration`, then silence, so a hands-free take ends through the
/// endpointer as a real one would. Every take's text is `transcript`.
@MainActor
final class SimulatedDictation: DictationDriving {
    var onUpdate: ((UUID, DictationUpdate) -> Void)?
    private(set) var isCapturing = false

    let transcript: String
    let levelInterval: TimeInterval
    let speechDuration: TimeInterval
    let transcriptionDelay: TimeInterval
    private let schedule: VoiceScheduler

    private var takeID: UUID?
    private var destination: DictationDestination = .cursor
    private var elapsed: TimeInterval = 0
    /// Bumped when a take ends, so its pending level ticks stop.
    private var generation = 0

    init(transcript: String = "This is the simulated microphone.",
         levelInterval: TimeInterval = 0.05, speechDuration: TimeInterval = 1,
         transcriptionDelay: TimeInterval = 0.3,
         schedule: @escaping VoiceScheduler = mainQueueScheduler) {
        self.transcript = transcript
        self.levelInterval = levelInterval
        self.speechDuration = speechDuration
        self.transcriptionDelay = transcriptionDelay
        self.schedule = schedule
    }

    func start(_ destination: DictationDestination) -> DictationStartOutcome {
        guard !isCapturing else { return .refused(.busy) }
        let id = UUID()
        takeID = id
        self.destination = destination
        isCapturing = true
        elapsed = 0
        generation += 1
        onUpdate?(id, .recording(destination))
        tick(id, generation: generation)
        return .started(id)
    }

    func retarget(_ destination: DictationDestination) {
        guard isCapturing, let takeID else { return }
        self.destination = destination
        onUpdate?(takeID, .retargeted(destination))
    }

    func stop() {
        guard isCapturing, let id = takeID else { return }
        endCapture()
        onUpdate?(id, .transcribing)
        let destination = destination
        let text = transcript
        schedule(transcriptionDelay) { [weak self] in
            self?.onUpdate?(id, .finished(text: text, destination: destination, transcript: text))
        }
    }

    func cancel() {
        guard isCapturing, let id = takeID else { return }
        endCapture()
        onUpdate?(id, .failed(.cancelled))
    }

    /// Nothing is typed: the simulated host never touches the frontmost app.
    func insert(_ text: String) {}

    private func endCapture() {
        isCapturing = false
        generation += 1
    }

    private func tick(_ id: UUID, generation: Int) {
        schedule(levelInterval) { [weak self] in
            guard let self, self.generation == generation, isCapturing else { return }
            elapsed += levelInterval
            // A voice-like wobble while "speaking", then room noise.
            let level = elapsed < speechDuration ? 0.35 + 0.25 * abs(sin(elapsed * 9)) : 0.02
            onUpdate?(id, .level(level))
            tick(id, generation: generation)
        }
    }
}
