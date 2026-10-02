import XCTest
@testable import VoiceHostCore

/// Deterministic SplitMix64, so every scenario run sees the same traces.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
}

/// Simulated hands-free takes: levels every 50 ms as SpeakFree reports them (per-buffer RMS / 0.15,
/// no smoothing), so every frame jitters independently around a phrase or pause envelope. Speech
/// frames are the phrase's level times a factor in `speechJitter`, with an occasional frame
/// dropping to the room between words; room frames are the floor times a factor in `noiseJitter`.
/// With streaming on, a partial transcript of what was said so far (a finished sentence, the hard
/// case for the grace) arrives every 2 s once a second of audio exists, 0.3 s after its audio.
struct EndpointerScenario {
    var name: String
    /// The room's level for a take; `louder` raises it from the second pause on (a fan starting).
    var floor: ClosedRange<Double>
    var louder: ClosedRange<Double>?
    /// Silence before the first word.
    var leadIn: ClosedRange<Double>
    /// The first phrase's level, when it differs (a loud start).
    var firstPhrase: ClosedRange<Double>?
    var phrase: ClosedRange<Double>
    var phraseLength: ClosedRange<Double> = 0.8...2.5
    var pause: ClosedRange<Double>
    var phrases = 4
    var streaming = true

    var speechJitter: ClosedRange<Double> = 0.4...1.6
    var noiseJitter: ClosedRange<Double> = 0.6...1.4
    /// Chance that a speech frame falls to the room (a gap between words).
    var wordGap = 0.06

    static let frame = 0.05

    struct Outcome {
        /// The take ended before the speaker had finished.
        var cutOff: Bool
        /// It ended within pause + grace + 0.5 s of the end of the speech.
        var onTime: Bool
        var ending: SilenceEndpointer.Ending?
        var at: Double?
        var speechEnd: Double
    }

    func run(seed: UInt64, settings: HandsFreeSettings = HandsFreeSettings()) -> Outcome {
        var random = SeededRandom(seed: seed)
        let floorLevel = random.uniform(floor)
        let louderLevel = louder.map { random.uniform($0) }
        // The envelope: (start, end, level) per phrase.
        var phrasesAt: [(start: Double, end: Double, level: Double)] = []
        var time = random.uniform(leadIn)
        var louderFrom = Double.infinity
        for index in 0..<phrases {
            let level = index == 0 ? random.uniform(firstPhrase ?? phrase) : random.uniform(phrase)
            let length = random.uniform(phraseLength)
            phrasesAt.append((time, time + length, level))
            time += length
            if index < phrases - 1 {
                if index == 1 { louderFrom = time }
                time += random.uniform(pause)
            }
        }
        let speechEnd = time
        var endpointer = SilenceEndpointer(settings: settings)
        var nextPartial = 2.0
        var frame = 0
        while true {
            let t = Double(frame) * Self.frame
            frame += 1
            guard t < speechEnd + 15 else { break }
            if streaming, t >= nextPartial + 0.3 {
                // Covers the audio up to `nextPartial`; it reads as a finished sentence.
                if nextPartial >= 1 { endpointer.observe(partial: "Said so far.", at: t) }
                nextPartial += 2
            }
            let room = (t >= louderFrom ? louderLevel ?? floorLevel : floorLevel) * random.uniform(noiseJitter)
            var level = room
            if let current = phrasesAt.first(where: { t >= $0.start && t < $0.end }),
               random.uniform(0...1) >= wordGap {
                level = max(room, current.level * random.uniform(speechJitter))
            }
            if let ending = endpointer.observe(level: level, at: t) {
                let allowed = settings.pause + SilenceEndpointer.grace + 0.5
                return Outcome(cutOff: t < speechEnd, onTime: t >= speechEnd && t <= speechEnd + allowed,
                               ending: ending, at: t, speechEnd: speechEnd)
            }
        }
        return Outcome(cutOff: false, onTime: false, ending: nil, at: nil, speechEnd: speechEnd)
    }

    struct Rates {
        var cutOff: Double
        var onTime: Double
    }

    func rates(seeds: Int = 500, settings: HandsFreeSettings = HandsFreeSettings()) -> Rates {
        var cutOff = 0
        var onTime = 0
        for seed in 0..<seeds {
            let outcome = run(seed: UInt64(seed), settings: settings)
            if outcome.cutOff { cutOff += 1 }
            if outcome.onTime { onTime += 1 }
        }
        return Rates(cutOff: Double(cutOff) / Double(seeds), onTime: Double(onTime) / Double(seeds))
    }

    static let quiet: ClosedRange<Double> = 0.006...0.012
    static let normal: ClosedRange<Double> = 0.15...0.45
    static let soft: ClosedRange<Double> = 0.04...0.08

    static let all: [EndpointerScenario] = [
        EndpointerScenario(name: "quiet room, soft speech", floor: quiet, leadIn: 0.2...0.8, phrase: soft,
                           pause: 0.5...1.5),
        EndpointerScenario(name: "fan room, normal speech", floor: 0.03...0.06, leadIn: 0.2...0.8, phrase: normal,
                           pause: 0.5...1.8),
        EndpointerScenario(name: "loud start, then normal", floor: quiet, leadIn: 0...0.1, firstPhrase: 0.6...0.95,
                           phrase: normal, pause: 0.5...1.5),
        EndpointerScenario(name: "loud start, then soft", floor: quiet, leadIn: 0...0.1, firstPhrase: 0.6...0.95,
                           phrase: soft, pause: 0.5...1.5),
        EndpointerScenario(name: "late start", floor: quiet, leadIn: 2...6, phrase: normal, pause: 0.5...1.5),
        EndpointerScenario(name: "room gets louder mid-take", floor: quiet, louder: 0.04...0.06, leadIn: 0.2...0.8,
                           phrase: normal, pause: 0.5...1.5),
        EndpointerScenario(name: "fan room, streaming off", floor: 0.03...0.06, leadIn: 0.2...0.8, phrase: normal,
                           pause: 0.5...1.8, streaming: false),
        EndpointerScenario(name: "fan room, late start", floor: 0.03...0.06, leadIn: 2...6, phrase: normal,
                           pause: 0.5...1.5),
        loudContinuousStart,
    ]

    /// Talking straight away, loudly, for 12 s with only short gaps between words.
    static let loudContinuousStart = EndpointerScenario(
        name: "loud continuous start, 12 s, short gaps", floor: quiet, leadIn: 0...0.05, phrase: 0.6...0.95,
        phraseLength: 12...12, pause: 0...0, phrases: 1, wordGap: 0.03)
}

/// Mid-sentence cut-offs at most 2%, and the take ends on time after the speech in at least 95%,
/// at default settings, for every scenario.
final class EndpointerScenarioTests: XCTestCase {
    func testScenariosAtDefaultSettings() {
        for scenario in EndpointerScenario.all {
            let rates = scenario.rates()
            print(String(format: "endpointer scenario %@: cut off %.1f%%, on time %.1f%%",
                         scenario.name, rates.cutOff * 100, rates.onTime * 100))
            XCTAssertLessThanOrEqual(rates.cutOff, 0.02, "\(scenario.name): cut off")
            XCTAssertGreaterThanOrEqual(rates.onTime, 0.95, "\(scenario.name): on time")
        }
    }

    func testALoudContinuousStartIsNeverThrownAway() {
        for seed in 0..<500 {
            XCTAssertNotEqual(EndpointerScenario.loudContinuousStart.run(seed: UInt64(seed)).ending, .nothingHeard,
                              "seed \(seed)")
        }
    }

    func testTheSameSeedGivesTheSameTake() {
        let scenario = EndpointerScenario.all[1]
        let first = scenario.run(seed: 42)
        let second = scenario.run(seed: 42)
        XCTAssertEqual(first.at, second.at)
        XCTAssertEqual(first.speechEnd, second.speechEnd)
    }
}
