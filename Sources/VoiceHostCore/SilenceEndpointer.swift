import Foundation

/// Decides when a hands-free take (orb click, wake word, socket `ask`) is over, from the input
/// levels (every 50 ms) and the partial transcript.
///
/// Speech is a level above `threshold`: the room's noise floor times a margin set by the
/// sensitivity, never below an absolute minimum. The floor is estimated from the first
/// `calibration` seconds and then follows the room while nobody speaks (down quickly, up
/// slowly), so a fan or a café raises the threshold and a quiet room lowers it. Hysteresis
/// keeps soft syllables in speech: speech starts above `threshold`, and only a level below
/// `quietThreshold` counts as quiet. A rise shorter than `minimumSpeech` (a click, a knock)
/// is not speech and does not restart the pause.
///
/// With end of turn `auto`, the take ends after `pause` seconds of quiet once speech was
/// heard, plus `grace` while the latest words read as an unfinished sentence (or none have
/// been transcribed yet). Silence before any speech never ends the take, so a slow start is
/// not cut off. With `manual` only the maximum ends it; a tap ends it in the controller.
struct SilenceEndpointer {
    enum Ending: Equatable {
        case pause, maximum
    }

    static let defaultMaximum: TimeInterval = 120
    /// The opening stretch the first floor estimate is taken from.
    static let calibration: TimeInterval = 0.3
    /// How long a level must stay above the threshold to count as speech.
    static let minimumSpeech: TimeInterval = 0.15
    /// Added to the pause while the sentence looks unfinished.
    static let grace: TimeInterval = 1.5
    /// The floor's bounds. The upper one caps an estimate taken while the user already speaks
    /// (straight after the wake word); the floor falls to the room at the first quiet.
    static let floorRange: ClosedRange<Double> = 0.005...0.15
    /// Time constants of the running floor: it falls quickly to a quieter room and rises slowly,
    /// so trailing soft speech does not lift it.
    static let floorFall: TimeInterval = 0.5
    static let floorRise: TimeInterval = 3

    let pause: TimeInterval
    let maximum: TimeInterval
    /// End of turn `auto`: a pause ends the take.
    let automatic: Bool
    private let margin: Double
    private let minimumThreshold: Double

    /// The room's noise floor, on SpeakFree's level scale (0...1, RMS / 0.15).
    private(set) var floor = 0.02
    private var startedAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var calibrationLevels: [Double] = []
    private var heardSpeech = false
    private var speaking = false
    /// When the level last rose above the threshold, while it stays there.
    private var aboveSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var partial = ""

    init(settings: HandsFreeSettings = HandsFreeSettings(), maximum: TimeInterval = SilenceEndpointer.defaultMaximum) {
        pause = settings.pause
        self.maximum = maximum
        automatic = settings.endOfTurn == .auto
        switch settings.sensitivity {
        case .low: (margin, minimumThreshold) = (3, 0.08)
        case .medium: (margin, minimumThreshold) = (2, 0.05)
        case .high: (margin, minimumThreshold) = (1.5, 0.03)
        }
    }

    /// The level speech starts above.
    var threshold: Double { max(floor * margin, minimumThreshold) }
    /// The level speech has to fall below to count as quiet: halfway from the floor to `threshold`.
    var quietThreshold: Double { floor + (threshold - floor) / 2 }

    /// A level has arrived, so `floor` is measured rather than assumed.
    var heardLevels: Bool { startedAt != nil }

    /// The latest words read as unfinished, or none have been transcribed.
    var unfinished: Bool { Self.isUnfinished(partial) }

    /// The quiet a pause has to reach to end the take now.
    var requiredPause: TimeInterval { pause + (unfinished ? Self.grace : 0) }

    /// Quiet since the last speech at `time`; nil while speaking or before any speech.
    func quiet(at time: TimeInterval) -> TimeInterval? {
        guard heardSpeech, let quietSince else { return nil }
        return time - quietSince
    }

    /// The latest partial transcript.
    mutating func observe(partial text: String) {
        partial = text
    }

    /// Feeds one level reading; why the take should end, or nil.
    mutating func observe(level: Double, at time: TimeInterval) -> Ending? {
        let start = startedAt ?? time
        startedAt = start
        defer { lastTime = time }
        if time - start < Self.calibration {
            calibrationLevels.append(level)
            floor = Self.clampFloor(Self.median(calibrationLevels))
        }
        if time - start >= maximum - 1e-6 { return .maximum }

        if level >= threshold {
            let since = aboveSince ?? time
            aboveSince = since
            if speaking || time - since >= Self.minimumSpeech - 1e-6 {
                speaking = true
                heardSpeech = true
                quietSince = nil
            }
            // Never ends on a rise that may be the start of a word.
            return nil
        }
        aboveSince = nil
        if level < quietThreshold {
            speaking = false
            if heardSpeech, quietSince == nil { quietSince = time }
        }
        if !speaking, time - start >= Self.calibration { follow(level, at: time) }

        guard automatic, !speaking, let quiet = quiet(at: time) else { return nil }
        return quiet >= requiredPause - 1e-6 ? .pause : nil
    }

    /// Moves the floor toward a level heard while nobody speaks.
    private mutating func follow(_ level: Double, at time: TimeInterval) {
        let elapsed = max(time - (lastTime ?? time), 0)
        let constant = level < floor ? Self.floorFall : Self.floorRise
        let weight = 1 - exp(-elapsed / constant)
        floor = Self.clampFloor(floor + (level - floor) * weight)
    }

    private static func clampFloor(_ level: Double) -> Double {
        min(max(level, floorRange.lowerBound), floorRange.upperBound)
    }

    private static func median(_ levels: [Double]) -> Double {
        let sorted = levels.sorted()
        return sorted[sorted.count / 2]
    }

    /// Words a sentence does not end on: conjunctions, fillers, articles and prepositions that
    /// lead into more.
    static let unfinishedEndings: Set<String> = [
        "and", "but", "so", "because", "or", "nor", "um", "umm", "uh", "er", "erm", "hmm", "like",
        "the", "a", "an", "to", "with", "of",
    ]

    /// The text stops mid-thought: empty (nothing transcribed yet), a trailing comma, colon,
    /// semicolon or dash, or a last word from `unfinishedEndings` (whatever punctuation the
    /// transcriber put after it).
    static func isUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return true }
        if ",;:-–—".contains(last) { return true }
        let word = trimmed.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let bare = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        return unfinishedEndings.contains(bare)
    }
}
