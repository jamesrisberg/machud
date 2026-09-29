import Foundation
import VoiceKit

/// A reply voice that makes no sound (`MACHUD_VOICE_NO_SPEECH=1`, set for an isolated host):
/// everything is "said" at once and reported finished on the next turn of the main queue.
@MainActor
final class SilentSpeaker: ReplySpeaking {
    var onFinished: (() -> Void)?
    private(set) var isSpeaking = false
    /// What each finished reply would have said.
    private(set) var said: [String] = []
    private var pending = ""
    private var generation = 0

    func configure(_ voice: VoiceSettings) {}

    func append(_ text: String) {
        pending += text
        if !text.isEmpty { isSpeaking = true }
    }

    func finish() {
        said.append(pending)
        pending = ""
        generation += 1
        let current = generation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.isSpeaking = false
                self.onFinished?()
            }
        }
    }

    func stop() {
        pending = ""
        generation += 1
        isSpeaking = false
    }
}
