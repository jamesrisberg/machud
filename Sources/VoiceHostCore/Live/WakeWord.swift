@preconcurrency import AVFoundation
import Foundation
import VoiceKit

/// The wake word: VoiceKit's `WakeListener` on openWakeWord, fed by the microphone. Listens
/// only for a phrase that has a downloaded model (`WakeModels`); otherwise, or when listening
/// stops by itself, it says why through `onProblem`. The controller logs and restarts it.
///
/// One listener per model, threshold and frame count: stopping it (around a take, while muted)
/// closes the microphone and keeps the listener with its loaded model, so starting it again
/// rebuilds nothing; re-arming it after a wake that started nothing keeps the microphone open and
/// can drop what it hears for a while (VoiceKit's quiet period). Other settings replace it.
@MainActor
final class WakeWordListener: WakeDriving {
    typealias DetectorFactory = @MainActor (WakeModel, URL) throws -> WakeDetector
    typealias SourceFactory = @MainActor () -> WakeAudioSource

    var onWake: ((WakeDetection, Bool) -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onProblem: ((WakeFailure) -> Void)?

    private let modelsRoot: URL
    private let makeDetector: DetectorFactory
    private let makeSource: SourceFactory
    private let isInstalled: (WakeModel, URL) -> Bool
    private let now: @MainActor () -> TimeInterval
    /// The listener built for `listenerKey`, kept while stopped.
    private var listener: WakeListener?
    private var listenerKey: ListenerKey?
    /// Between `start` and `stop`: only then is a detection from `listener` current.
    private var running = false

    /// What a listener is built for: the phrase's model and the settings it scores with.
    private struct ListenerKey: Equatable {
        var model: String
        var threshold: Double
        var frames: Int
    }

    /// - Parameters:
    ///   - modelsRoot: the folder wake models are downloaded under (`WakeModel.directory(in:)`).
    ///   - makeDetector: the detector for an installed model's folder (openWakeWord).
    ///   - makeSource: the audio for one listener (the microphone).
    ///   - isInstalled: whether a model's folder is complete and verified.
    ///   - now: seconds on a monotonic clock, for the quiet period after a re-arm.
    init(modelsRoot: URL,
         makeDetector: @escaping DetectorFactory = WakeWordListener.openWakeWordDetector,
         makeSource: @escaping SourceFactory = { MicrophoneWakeSource() },
         isInstalled: @escaping (WakeModel, URL) -> Bool = { ModelStore.isInstalled($0.manifest, in: $1) },
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.modelsRoot = modelsRoot
        self.makeDetector = makeDetector
        self.makeSource = makeSource
        self.isInstalled = isInstalled
        self.now = now
    }

    static func openWakeWordDetector(model: WakeModel, directory: URL) throws -> WakeDetector {
        InProcessWakeDetector(engine: try OpenWakeWordEngine(model: model, directory: directory),
                              phrase: model.phrase, model: model.id)
    }

    func start(_ settings: VoiceSettings) {
        guard let model = WakeModels.model(forPhrase: settings.wakePhrase) else {
            release()
            return unavailable("There is no wake model for “\(settings.wakePhrase)” yet.")
        }
        let directory = model.directory(in: modelsRoot)
        guard isInstalled(model, directory) else {
            release()
            return unavailable("Download the \(model.phrase) model to use the wake word.")
        }
        let key = ListenerKey(model: model.id, threshold: settings.wakeThreshold, frames: settings.wakeFrames)
        if let listener, listenerKey == key {
            // Stopped, failed, or already listening (then this changes nothing).
            running = true
            Task { await listener.start() }
            return
        }
        release()
        let detector: WakeDetector
        do {
            detector = try makeDetector(model, directory)
        } catch {
            return unavailable("The \(model.phrase) model could not load: \(error.localizedDescription)")
        }
        let source = makeSource()
        let listener = WakeListener(detector: detector, source: source, threshold: key.threshold,
                                    frames: key.frames, now: now)
        (source as? WakeSourceFailing)?.onFailure = { [weak self, weak listener] reason in
            guard let self, let listener, self.listener === listener else { return }
            stop()
            onProblem?(WakeFailure(reason: reason, retryable: true))
        }
        listener.onWake = { [weak self, weak listener] detection in
            guard let self, let listener else { return }
            // One that was on its way when its listener was stopped or replaced is passed on
            // marked so: the controller journals it and acts on none of it.
            onWake?(detection, running && self.listener === listener)
        }
        listener.onStateChanged = { [weak self, weak listener] state in
            // A listener already replaced says nothing about the one running now.
            guard let self, let listener, self.listener === listener else { return }
            // The audio, the microphone's permission or the detector falling behind.
            if case .failed(let reason) = state { onProblem?(WakeFailure(reason: reason, retryable: true)) }
            onListeningChanged?(state == .listening)
        }
        self.listener = listener
        listenerKey = key
        running = true
        Task { await listener.start() }
    }

    func stop() {
        guard let listener, running else { return }
        running = false
        onListeningChanged?(false)
        Task { await listener.stop() }
    }

    func rearm(quietFor seconds: TimeInterval) {
        guard running, let listener else { return }
        Task { await listener.rearm(quietFor: seconds) }
    }

    /// Stops the listener and lets it go, its model with it: another phrase or settings, or a
    /// model that is no longer there.
    private func release() {
        guard let listener else { return }
        if running {
            running = false
            onListeningChanged?(false)
        }
        self.listener = nil
        listenerKey = nil
        Task { await listener.stop() }
    }

    /// No model for the phrase, or one that is missing or will not load: starting again as it is
    /// would fail the same way.
    private func unavailable(_ reason: String) {
        onListeningChanged?(false)
        onProblem?(WakeFailure(reason: reason, retryable: false))
    }
}

/// A wake audio source that can stop delivering by itself after it started.
@MainActor
protocol WakeSourceFailing: WakeAudioSource {
    /// Delivery stopped for good; the reason is for the user.
    var onFailure: ((String) -> Void)? { get set }
}

/// The default input device as 16 kHz mono chunks for the wake listener.
///
/// It runs its own `AVAudioEngine` beside SpeakFree's capture engine (which stays open for the
/// pre-buffer): macOS lets several engines read one input device. The input's own format is
/// converted to 16 kHz mono on the audio thread. A device or format change stops an engine, so
/// the source starts it again with the new format, and reports it when that fails.
@MainActor
final class MicrophoneWakeSource: WakeSourceFailing {
    struct StartFailed: LocalizedError {
        var errorDescription: String? { "The microphone could not start for the wake word." }
    }

    struct MicrophoneDenied: LocalizedError {
        var errorDescription: String? {
            "MacHUD cannot use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
        }
    }

    var onSamples: (([Float]) -> Void)?
    var onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    func start() async throws {
        // Without access the input delivers silence, and the wake word would never hear a thing.
        guard await Self.microphoneAllowed() else { throw MicrophoneDenied() }
        try startEngine()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw StartFailed() }
        let deliver: @Sendable ([Float]) -> Void = { [weak self] samples in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onSamples?(samples) } }
        }
        // 100 ms buffers: well under the listener's one-second chunk limit.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10), format: inputFormat,
                         block: Self.tap(converter: converter, from: inputFormat, to: outputFormat, deliver: deliver))
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    /// The input device or its format changed and stopped the engine: start a new one on the
    /// current default input, or report the failure.
    private func restartAfterConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        stop()
        do {
            try startEngine()
            TakeLog.notice("wake audio restarted after an audio device change")
        } catch {
            onFailure?("The microphone stopped for the wake word after an audio device change.")
        }
    }

    /// Runs on the audio thread: converts each buffer and hands the samples on.
    private nonisolated static func tap(converter: AVAudioConverter, from inputFormat: AVAudioFormat,
                                        to outputFormat: AVAudioFormat,
                                        deliver: @escaping @Sendable ([Float]) -> Void) -> AVAudioNodeTapBlock {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            // `.noDataNow` (not end of stream) keeps the resampler's state from one buffer to the next.
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            deliver(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }
    }
}
