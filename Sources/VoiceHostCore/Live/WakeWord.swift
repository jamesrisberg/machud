@preconcurrency import AVFoundation
import Foundation
import VoiceKit

/// The wake word: VoiceKit's `WakeListener` on openWakeWord, fed by the microphone. Listens
/// only for a phrase that has a downloaded model (`WakeModels`); otherwise, or when listening
/// stops by itself, it says why through `onProblem`.
@MainActor
final class WakeWordListener: WakeDriving {
    typealias DetectorFactory = @MainActor (WakeModel, URL) throws -> WakeDetector
    typealias SourceFactory = @MainActor () -> WakeAudioSource

    var onWake: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    var onProblem: ((String?) -> Void)?

    private let modelsRoot: URL
    private let makeDetector: DetectorFactory
    private let makeSource: SourceFactory
    private let isInstalled: (WakeModel, URL) -> Bool
    private var listener: WakeListener?

    /// - Parameters:
    ///   - modelsRoot: the folder wake models are downloaded under (`WakeModel.directory(in:)`).
    ///   - makeDetector: the detector for an installed model's folder (openWakeWord).
    ///   - makeSource: the audio for one listening run (the microphone).
    ///   - isInstalled: whether a model's folder is complete and verified.
    init(modelsRoot: URL,
         makeDetector: @escaping DetectorFactory = WakeWordListener.openWakeWordDetector,
         makeSource: @escaping SourceFactory = { MicrophoneWakeSource() },
         isInstalled: @escaping (WakeModel, URL) -> Bool = { ModelStore.isInstalled($0.manifest, in: $1) }) {
        self.modelsRoot = modelsRoot
        self.makeDetector = makeDetector
        self.makeSource = makeSource
        self.isInstalled = isInstalled
    }

    static func openWakeWordDetector(model: WakeModel, directory: URL) throws -> WakeDetector {
        InProcessWakeDetector(engine: try OpenWakeWordEngine(model: model, directory: directory),
                              phrase: model.phrase, model: model.id)
    }

    func start(_ settings: VoiceSettings) {
        stop()
        guard let model = WakeModels.model(forPhrase: settings.wakePhrase) else {
            return unavailable("There is no wake model for “\(settings.wakePhrase)” yet.")
        }
        let directory = model.directory(in: modelsRoot)
        guard isInstalled(model, directory) else {
            return unavailable("Download the \(model.phrase) model to use the wake word.")
        }
        let detector: WakeDetector
        do {
            detector = try makeDetector(model, directory)
        } catch {
            return unavailable("The \(model.phrase) model could not load: \(error.localizedDescription)")
        }
        onProblem?(nil)
        let source = makeSource()
        let listener = WakeListener(detector: detector, source: source, threshold: settings.wakeThreshold)
        (source as? WakeSourceFailing)?.onFailure = { [weak self, weak listener] reason in
            guard let self, let listener, self.listener === listener else { return }
            NSLog("MacHUDVoice: wake word stopped: %@", reason)
            stop()
            onProblem?(reason)
        }
        listener.onWake = { [weak self] _ in self?.onWake?() }
        listener.onStateChanged = { [weak self, weak listener] state in
            // A listener already replaced says nothing about the one running now.
            guard let self, let listener, self.listener === listener else { return }
            if case .failed(let reason) = state {
                NSLog("MacHUDVoice: wake word stopped: %@", reason)
                onProblem?(reason)
            }
            onListeningChanged?(state == .listening)
        }
        self.listener = listener
        Task { await listener.start() }
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        onListeningChanged?(false)
        Task { await listener.stop() }
    }

    private func unavailable(_ reason: String) {
        NSLog("MacHUDVoice: wake word off: %@", reason)
        onListeningChanged?(false)
        onProblem?(reason)
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
