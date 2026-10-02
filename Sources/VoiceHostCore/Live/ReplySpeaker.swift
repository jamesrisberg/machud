import Foundation
import os
import VoiceKit

/// Speaks replies through VoiceKit's `SpeechStreamer`. The voice is built for each reply from
/// the settings and the stored Grok key, so a settings or key change applies to the next one;
/// `SpeechVoices` falls back to the system voice when Kokoro is not installed or there is no key.
/// `warmUp` builds the reply's voice early and has it load, so a reply that is coming starts
/// sooner. Each reply's speech metrics are logged once, without its text.
@MainActor
final class ReplySpeaker: ReplySpeaking {
    var onFinished: (() -> Void)?
    var onChunkStarted: ((SpeechChunk) -> Void)?
    var isSpeaking: Bool { streamer?.isSpeaking == true }

    private let kokoroDirectory: URL
    private let secrets: VoiceSecretStoring
    private var settings = VoiceSettings()
    private var streamer: SpeechStreamer?

    init(kokoroDirectory: URL, secrets: VoiceSecretStoring) {
        self.kokoroDirectory = kokoroDirectory
        self.secrets = secrets
    }

    func configure(_ voice: VoiceSettings) {
        settings = voice
    }

    func warmUp() {
        currentStreamer().warmUp()
    }

    func append(_ text: String) {
        currentStreamer().append(text)
    }

    func finish() {
        guard let streamer else { return }
        streamer.finish()
    }

    func stop() {
        streamer?.stop()
        streamer = nil
    }

    private func currentStreamer() -> SpeechStreamer {
        if let streamer { return streamer }
        let voice = SpeechVoices.make(for: settings, kokoroModelDirectory: kokoroDirectory, secrets: secrets)
        let streamer = SpeechStreamer(voice: voice)
        streamer.onFinished = { [weak self, weak streamer] _ in
            guard let self, let streamer, self.streamer === streamer else { return }
            self.streamer = nil
            onFinished?()
        }
        streamer.onChunkStarted = { [weak self, weak streamer] chunk in
            guard let self, let streamer, self.streamer === streamer else { return }
            onChunkStarted?(chunk)
        }
        // The voice it was spoken with (Kokoro falls back to the system voice when not installed).
        let kind = String(describing: type(of: voice))
        streamer.onMetrics = { metrics in Self.log(metrics, voice: kind) }
        self.streamer = streamer
        return streamer
    }

    private static let logger = Logger(subsystem: VoiceHostMain.secretsService, category: "speech")

    /// One line per reply: how soon it was heard and how often it waited, never what it said.
    private static func log(_ metrics: SpeechStreamMetrics, voice: String) {
        func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "never" }
        logger.notice("""
            Reply \(metrics.outcome.rawValue, privacy: .public) (\(voice, privacy: .public)): \
            first chunk queued \(ms(metrics.firstChunkQueuedMilliseconds), privacy: .public), \
            first audio \(ms(metrics.firstAudioMilliseconds), privacy: .public), \(metrics.chunks) chunks, \
            \(metrics.underruns) underruns (\(metrics.underrunMilliseconds) ms; text \(metrics.textUnderrunMilliseconds) ms, \
            synthesis \(metrics.synthesisUnderrunMilliseconds) ms)
            """)
    }
}
