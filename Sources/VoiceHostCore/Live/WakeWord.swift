@preconcurrency import AVFoundation
import Foundation
import VoiceKit

/// The wake word: VoiceKit's `WakeListener` on openWakeWord, fed by the microphone. Listens
/// only for a phrase that has a downloaded model (`WakeModels`); otherwise it stays off and
/// says why in `unavailableReason`.
@MainActor
final class WakeWordListener: WakeDriving {
    var onWake: (() -> Void)?
    var onListeningChanged: ((Bool) -> Void)?
    private(set) var unavailableReason: String?

    private let modelsRoot: URL
    private var listener: WakeListener?

    /// - Parameter modelsRoot: the folder wake models are downloaded under
    ///   (`WakeModel.directory(in:)`).
    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
    }

    func start(_ settings: VoiceSettings) {
        stop()
        guard let model = WakeModels.model(forPhrase: settings.wakePhrase) else {
            return unavailable("No wake model for \"\(settings.wakePhrase)\"")
        }
        let directory = model.directory(in: modelsRoot)
        guard ModelStore.isInstalled(model.manifest, in: directory) else {
            return unavailable("The \"\(model.phrase)\" wake model is not downloaded")
        }
        let engine: OpenWakeWordEngine
        do {
            engine = try OpenWakeWordEngine(model: model, directory: directory)
        } catch {
            return unavailable(error.localizedDescription)
        }
        unavailableReason = nil
        let listener = WakeListener(
            detector: InProcessWakeDetector(engine: engine, phrase: model.phrase, model: model.id),
            source: MicrophoneWakeSource(), threshold: settings.wakeThreshold)
        listener.onWake = { [weak self] _ in self?.onWake?() }
        listener.onStateChanged = { [weak self] state in
            if case .failed(let reason) = state { self?.unavailableReason = reason }
            self?.onListeningChanged?(state == .listening)
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
        unavailableReason = reason
        NSLog("MacHUDVoice: wake word off: %@", reason)
        onListeningChanged?(false)
    }
}

/// The default input device as 16 kHz mono chunks for the wake listener.
@MainActor
final class MicrophoneWakeSource: WakeAudioSource {
    struct StartFailed: LocalizedError {
        var errorDescription: String? { "The microphone could not start for the wake word" }
    }

    var onSamples: (([Float]) -> Void)?
    private let engine = AVAudioEngine()

    func start() async throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
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
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
