import Foundation
import VoiceKit

/// Speaks replies through VoiceKit's `SpeechStreamer`. The voice is built for each reply from
/// the settings and the stored Grok key, so a settings or key change applies to the next one;
/// `SpeechVoices` falls back to the system voice when Kokoro is not installed or there is no key.
@MainActor
final class ReplySpeaker: ReplySpeaking {
    var onFinished: (() -> Void)?
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
        self.streamer = streamer
        return streamer
    }
}
