import Foundation

/// Decides when a hands-free take (orb click, wake word, socket `ask`) is over, from the input
/// levels (every 50 ms, SpeakFree's per-buffer RMS / 0.15, unsmoothed) and the partial transcript.
///
/// The room's noise floor is the lowest level of the trailing `floorWindow` seconds times
/// `floorFactor`, updated on every level: a quiet frame between words or phrases pulls it down
/// at once, and a room that gets louder lifts it within the window. Speech starts once the level
/// has stayed at or above `threshold` (the floor times a margin set by the sensitivity, never
/// below an absolute minimum) for `minimumSpeech`, without falling below `quietThreshold` in
/// between; a shorter rise (a click, a knock) is not speech. Speech then lasts until the level
/// has stayed below `quietThreshold` for `minimumSpeech`, so soft syllables between the two marks
/// and the gaps between words keep it going; the quiet is counted from the start of that dip.
///
/// With end of turn `auto`, the take ends after `pause` seconds of quiet once speech was
/// heard, plus `grace` while the sentence may not be over: the latest partial transcript ends
/// mid-thought, speech was heard after it arrived, or none has arrived yet while one is still
/// expected (`partialsExpected`). Silence before any speech never ends the take by a pause; with
/// no speech `nothingHeardAfter` seconds into the take it ends as `nothingHeard`. With `manual`
/// only the maximum ends it; a tap ends it in the controller.
struct SilenceEndpointer {
    enum Ending: Equatable {
        case pause, maximum, nothingHeard
    }

    static let defaultMaximum: TimeInterval = 120
    /// How long a level must stay up to count as speech.
    static let minimumSpeech: TimeInterval = 0.15
    /// Added to the pause while the sentence may not be over.
    static let grace: TimeInterval = 1.5
    /// The trailing stretch whose lowest level sets the floor, and the factor applied to it.
    static let floorWindow: TimeInterval = 3
    static let floorFactor = 1.2
    static let minimumFloor = 0.002
    /// An automatic take with no speech this long after it started ends as `nothingHeard`.
    static let nothingHeardAfter: TimeInterval = 10
    /// SpeakFree's streaming sends its first partial about 2.3 s into a take; with none by this
    /// time there is no transcript to wait for (streaming is off or the engine has none).
    static let partialsExpected: TimeInterval = 3

    let pause: TimeInterval
    let maximum: TimeInterval
    /// End of turn `auto`: a pause ends the take.
    let automatic: Bool
    private let margin: Double
    private let minimumThreshold: Double

    /// The room's noise floor, on SpeakFree's level scale (0...1, RMS / 0.15).
    private(set) var floor = 0.01
    private var startedAt: TimeInterval?
    /// The trailing levels that can still be the window's lowest, oldest first, rising.
    private var lows: [(time: TimeInterval, level: Double)] = []
    private var heardSpeech = false
    private var speaking = false
    /// When the level rose to the threshold, while it has not fallen below `quietThreshold` since.
    private var aboveSince: TimeInterval?
    private var quietSince: TimeInterval?
    /// When the level fell below `quietThreshold`, while it stays there.
    private var dipSince: TimeInterval?
    /// The latest level counted as speech.
    private var lastSpeechAt: TimeInterval?
    private var partial = ""
    private var partialAt: TimeInterval?

    init(settings: HandsFreeSettings = HandsFreeSettings(), maximum: TimeInterval = SilenceEndpointer.defaultMaximum) {
        pause = settings.pause
        self.maximum = maximum
        automatic = settings.endOfTurn == .auto
        switch settings.sensitivity {
        case .low: (margin, minimumThreshold) = (3, 0.035)
        case .medium: (margin, minimumThreshold) = (2.5, 0.025)
        case .high: (margin, minimumThreshold) = (2, 0.018)
        }
    }

    /// The level speech starts at.
    var threshold: Double { max(floor * margin, minimumThreshold) }
    /// The level speech has to fall below to count as quiet: halfway from the floor to `threshold`.
    var quietThreshold: Double { floor + (threshold - floor) / 2 }

    /// A level has arrived, so `floor` is measured rather than assumed.
    var heardLevels: Bool { startedAt != nil }

    /// The sentence may not be over at `time`: the latest partial ends mid-thought, speech was
    /// heard after it arrived, or none has arrived while one is still expected.
    func unfinished(at time: TimeInterval) -> Bool {
        guard let partialAt else {
            guard let startedAt else { return false }
            return time - startedAt < Self.partialsExpected
        }
        if let lastSpeechAt, lastSpeechAt > partialAt { return true }
        return Self.isUnfinished(partial)
    }

    /// The quiet a pause has to reach to end the take at `time`.
    func requiredPause(at time: TimeInterval) -> TimeInterval {
        pause + (unfinished(at: time) ? Self.grace : 0)
    }

    /// Quiet since the last speech at `time`; nil while speaking or before any speech.
    func quiet(at time: TimeInterval) -> TimeInterval? {
        guard heardSpeech, let quietSince else { return nil }
        return time - quietSince
    }

    /// The latest partial transcript, arriving at `time`.
    mutating func observe(partial text: String, at time: TimeInterval) {
        partial = text
        partialAt = time
    }

    /// Feeds one level reading; why the take should end, or nil.
    mutating func observe(level: Double, at time: TimeInterval) -> Ending? {
        let start = startedAt ?? time
        startedAt = start
        follow(level, at: time)
        if time - start >= maximum - 1e-6 { return .maximum }

        if level >= quietThreshold {
            dipSince = nil
            if level >= threshold, aboveSince == nil { aboveSince = time }
            if let since = aboveSince, speaking || time - since >= Self.minimumSpeech - 1e-6 {
                speaking = true
                heardSpeech = true
                quietSince = nil
                lastSpeechAt = time
            }
        } else {
            aboveSince = nil
            let dip = dipSince ?? time
            dipSince = dip
            // A gap shorter than a syllable does not end speech; a longer one is quiet from its start.
            if speaking, time - dip >= Self.minimumSpeech - 1e-6 { speaking = false }
            if !speaking, heardSpeech, quietSince == nil { quietSince = dip }
        }

        guard automatic else { return nil }
        guard heardSpeech else {
            return time - start >= Self.nothingHeardAfter - 1e-6 ? .nothingHeard : nil
        }
        // Never on a rise that may be the start of a word.
        guard !speaking, aboveSince == nil, let quiet = quiet(at: time) else { return nil }
        return quiet >= requiredPause(at: time) - 1e-6 ? .pause : nil
    }

    /// Adds a level to the trailing window and sets the floor from its lowest.
    private mutating func follow(_ level: Double, at time: TimeInterval) {
        while let last = lows.last, last.level >= level { lows.removeLast() }
        lows.append((time, level))
        while let first = lows.first, first.time < time - Self.floorWindow - 1e-6 { lows.removeFirst() }
        floor = max((lows.first?.level ?? level) * Self.floorFactor, Self.minimumFloor)
    }

    /// Words a sentence does not end on: conjunctions, fillers, articles and prepositions that
    /// lead into more.
    static let unfinishedEndings: Set<String> = [
        "and", "but", "so", "because", "or", "nor", "um", "umm", "uh", "er", "erm", "hmm", "like",
        "the", "a", "an", "to", "with", "of",
    ]

    /// The text stops mid-thought: a trailing comma, colon, semicolon or dash, or a last word from
    /// `unfinishedEndings` (whatever punctuation the transcriber put after it). Empty text is not.
    static func isUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if ",;:-–—".contains(last) { return true }
        let word = trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        return unfinishedEndings.contains(bare)
    }
}
