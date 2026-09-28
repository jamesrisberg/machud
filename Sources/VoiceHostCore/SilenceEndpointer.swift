import Foundation

/// Decides when a hands-free take (orb click, wake word, socket `ask`) is over: after
/// `silence` seconds below `threshold` once speech was heard, or `maximum` seconds after the
/// first level. Silence before any speech never ends the take, so a slow start is not cut off.
struct SilenceEndpointer {
    /// Input level (0...1, SpeakFree's scale: RMS / 0.15) that counts as speech.
    var threshold: Double
    var silence: TimeInterval
    var maximum: TimeInterval

    private var startedAt: TimeInterval?
    private var heardSpeech = false
    private var quietSince: TimeInterval?

    init(threshold: Double = 0.1, silence: TimeInterval = 1.2, maximum: TimeInterval = 30) {
        self.threshold = threshold
        self.silence = silence
        self.maximum = maximum
    }

    /// Feeds one level reading; true when the take should end.
    mutating func observe(level: Double, at time: TimeInterval) -> Bool {
        let start = startedAt ?? time
        startedAt = start
        if time - start >= maximum { return true }
        if level >= threshold {
            heardSpeech = true
            quietSince = nil
            return false
        }
        guard heardSpeech else { return false }
        let quiet = quietSince ?? time
        quietSince = quiet
        return time - quiet >= silence
    }
}
