import AVFoundation
import SpeakFreeLib
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// With the real models, what confirming the wake phrase does: each clip goes through the wake
/// detector as the voice host runs it (the owner's threshold, the default frame count, 100 ms
/// chunks), the audio a wake hands over goes to the dictation's Parakeet model through the voice
/// host's own `WakeAudioTranscription`, and the table says whether the words contain the phrase,
/// what they are, and how long it took. For a clip that wakes it also says how much of the clip
/// was still to come when it woke, and whether the phrase is found when the speech model is given
/// 0.3 s or 0.6 s more of what followed (the voice host gives it none). It asserts only that the
/// repository's fixture wakes; the rest is an instrument.
///
/// Runs only with `MACHUD_WAKE_CONFIRM_MODELS` set to a folder holding the Hey Jarvis files (they
/// are installed into a temporary folder first) and a Parakeet model in FluidAudio's cache (it is
/// only read). `MACHUD_WAKE_CONFIRM_AUDIO` adds every .wav under a folder, such as the one
/// `Kits/VoiceKit/Tests/WakeEval/make-synthetic.sh` writes (`positives/`, `confusables/`); clips
/// are padded with a second of silence on each side. SpeakFree's configuration is pointed at a
/// temporary folder, so nothing of the user's is read. Nothing opens the microphone.
///
/// It refuses, before reading anything, an audio folder that holds the owner's recordings
/// (SpeakFree's `~/.config/speakfree`, MacHUD's `~/Library/Application Support/MacHUD`), and prints
/// what the model wrote only for the repository's fixture and the synthetic sets' `positives/` and
/// `confusables/`.
///
///     MACHUD_WAKE_CONFIRM_MODELS=<folder> MACHUD_WAKE_CONFIRM_AUDIO=<folder> \
///         swift test --filter WakeConfirmationModelTests
@MainActor
final class WakeConfirmationModelTests: XCTestCase {
    /// The owner's threshold.
    static let threshold = 0.53

    func testTheSpeechModelConfirmsWhatTheWakeWordHeard() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let folder = environment["MACHUD_WAKE_CONFIRM_AUDIO"], let refusal = Self.refusal(for: URL(fileURLWithPath: folder)) {
            return XCTFail(refusal)
        }
        guard let wakeFiles = environment["MACHUD_WAKE_CONFIRM_MODELS"].map(URL.init(fileURLWithPath:)) else {
            throw XCTSkip("set MACHUD_WAKE_CONFIRM_MODELS to a folder with the Hey Jarvis files")
        }
        guard let parakeet = SpeakFreeDictation.parakeetModels.first(where: {
            ParakeetModelManager.shared.isModelDownloaded($0)
        }) else { throw XCTSkip("no Parakeet model in FluidAudio's cache") }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wake-confirm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let configDirectory = Config.configDirOverride
        Config.configDirOverride = scratch.appendingPathComponent("speakfree")
        defer { Config.configDirOverride = configDirectory }

        let model = WakeModels.heyJarvis
        let wakeDirectory = scratch.appendingPathComponent("wake")
        try await ModelStore.install(
            model.manifest.seeded(from: [wakeFiles]), into: wakeDirectory,
            downloader: { _, _, _ in throw ModelDownload.Failure.invalidDownload }, progress: { _, _ in })
        let wakeEngine = try OpenWakeWordEngine(model: model, directory: wakeDirectory)
        let detector = InProcessWakeDetector(engine: wakeEngine, phrase: model.phrase, model: model.id)

        let engine = ParakeetEngine()
        let transcriber = Transcriber(engine: engine, modelID: parakeet, language: "en")
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await engine.loadModel(modelID: parakeet)
        let loadSeconds = ProcessInfo.processInfo.systemUptime - loadStart

        var clips = [Self.fixture]
        if let folder = environment["MACHUD_WAKE_CONFIRM_AUDIO"] {
            clips += Self.wavFiles(under: URL(fileURLWithPath: folder))
        }
        var rows: [Row] = []
        for clip in clips {
            let speech = try Self.samples(clip)
            let silence = [Float](repeating: 0, count: 16_000)
            let audio = silence + speech + silence
            let woke = try await Self.wake(on: audio, detector: detector)
            // A clip that does not wake is still transcribed, over the 2.5 s that end where it
            // scored highest, to show what the speech model makes of it.
            var heard = woke?.detection.audio ?? []
            if woke == nil { heard = Self.heard(audio, endingAt: try await Self.peakEnd(audio, engine: wakeEngine)) }
            let started = ProcessInfo.processInfo.systemUptime
            let words = await Self.transcribe(heard, with: transcriber)
            let ms = Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded())
            var later: [Result<String, WakeConfirmFailure>] = []
            if let woke {
                for extra in Self.extraSeconds {
                    let end = min(audio.count, woke.end + Int(extra * 16_000))
                    later.append(await Self.transcribe(Array(audio[max(0, woke.end - WakeListener.heardSamples)..<end]),
                                                       with: transcriber))
                }
            }
            rows.append(Row(clip: Self.name(clip), showsWords: Self.showsWords(clip), wake: woke?.detection, words: words,
                            ms: ms, phrase: model.phrase,
                            toCome: woke.map { Int((Double(silence.count + speech.count - $0.end) / 16).rounded()) },
                            later: later))
        }
        print(Self.report(rows, parakeet: parakeet, loadSeconds: loadSeconds))
        XCTAssertNotNil(rows.first?.wake, "the repository's Hey Jarvis fixture wakes the detector")
    }

    /// The measurement never transcribes the owner's recordings, and shows the words only for clips
    /// whose content is known: the repository's fixture and the synthetic sets. Nothing is read.
    func testTheOwnersRecordingsAreNeverMeasuredAndOnlyKnownClipsShowTheirWords() {
        let home = URL(fileURLWithPath: "/Users/someone")
        for path in ["/Users/someone/.config/speakfree", "/Users/someone/.config/speakfree/recordings",
                     "/Users/someone/.config/SpeakFree/recordings", "/Users/someone/.config/x/../speakfree/recordings",
                     "/Users/someone/Library/Application Support/MacHUD/Voice/History"] {
            XCTAssertNotNil(Self.refusal(for: URL(fileURLWithPath: path), home: home), path)
        }
        for path in ["/tmp/synthetic", "/Users/someone/.config/speakfree-renders", "/Users/someone/scratch/positives"] {
            XCTAssertNil(Self.refusal(for: URL(fileURLWithPath: path), home: home), path)
        }
        XCTAssertTrue(Self.showsWords(Self.fixture))
        XCTAssertTrue(Self.showsWords(URL(fileURLWithPath: "/tmp/synthetic/positives/hey-jarvis-Moira-140.wav")))
        XCTAssertTrue(Self.showsWords(URL(fileURLWithPath: "/tmp/synthetic/confusables/Hey-Travis-Karen.wav")))
        XCTAssertFalse(Self.showsWords(URL(fileURLWithPath: "/tmp/synthetic/extras/Jarvis-Moira.wav")))
        XCTAssertFalse(Self.showsWords(URL(fileURLWithPath: "/tmp/clips/take-1.wav")))
    }

    /// The more audio, after the wake, the speech model is also given for a clip that woke.
    static let extraSeconds: [Double] = [0.3, 0.6]

    struct Row {
        let clip: String
        /// What the model wrote may be printed (`showsWords`).
        let showsWords: Bool
        let wake: WakeDetection?
        let words: Result<String, WakeConfirmFailure>
        let ms: Int
        let phrase: String
        /// For a wake: milliseconds of the clip after the audio handed over ended (negative: it
        /// ended in the silence after the clip).
        var toCome: Int?
        /// For a wake: the words with `extraSeconds` more audio.
        var later: [Result<String, WakeConfirmFailure>] = []

        var confirmed: Bool { contains(words) }

        func contains(_ words: Result<String, WakeConfirmFailure>) -> Bool {
            guard case .success(let words) = words else { return false }
            return TriggerPhrase.transcript(words, contains: phrase)
        }

        var text: String { showsWords ? Self.quote(words) : "(words not shown)" }

        static func quote(_ words: Result<String, WakeConfirmFailure>) -> String {
            switch words {
            case .success(let words): "\"\(words)\""
            case .failure(let failure): "(\(failure))"
            }
        }
    }

    /// The detector as the listener runs it: armed, fed 100 ms chunks, and the audio handed over
    /// with a wake being the last 2.5 s fed, up to the end of the chunk in which it came.
    /// `end` is where the audio handed over ends, in samples of `audio`.
    static func wake(on audio: [Float], detector: InProcessWakeDetector) async throws -> (detection: WakeDetection, end: Int)? {
        _ = try await detector.arm(threshold: threshold, frames: VoiceSettings().wakeFrames)
        var fed: [Float] = []
        for start in stride(from: 0, to: audio.count, by: 1600) {
            let chunk = Array(audio[start..<min(start + 1600, audio.count)])
            fed += chunk
            if let detection = try await detector.detect(chunk) {
                return (WakeDetection(score: detection.score, phrase: detection.phrase, frames: detection.frames,
                                      peak: detection.peak, audio: Array(fed.suffix(WakeListener.heardSamples))),
                        fed.count)
            }
        }
        await detector.disarm()
        return nil
    }

    /// Where the frame that scored highest ends, in samples.
    static func peakEnd(_ audio: [Float], engine: OpenWakeWordEngine) async throws -> Int {
        try await engine.reset()
        var best = (score: Float(-1), end: audio.count)
        for start in stride(from: 0, through: audio.count - 1280, by: 1280) {
            let score = try await engine.score(Array(audio[start..<(start + 1280)]))
            if score > best.score { best = (score, start + 1280) }
        }
        return best.end
    }

    static func heard(_ audio: [Float], endingAt end: Int) -> [Float] {
        Array(audio[max(0, end - WakeListener.heardSamples)..<end])
    }

    static func transcribe(_ audio: [Float], with transcriber: Transcriber) async -> Result<String, WakeConfirmFailure> {
        await withCheckedContinuation { continuation in
            WakeAudioTranscription.transcribe(audio, with: transcriber, language: "en") { continuation.resume(returning: $0) }
        }
    }

    // MARK: Files

    /// Why the clips in `folder` may not be measured, or nil: SpeakFree's and MacHUD's folders
    /// hold the owner's dictation recordings, which are never transcribed here.
    static func refusal(for folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        func path(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path.lowercased() }
        let audio = path(folder)
        for owner in [".config/speakfree", "Library/Application Support/MacHUD"] {
            let protected = path(home.appendingPathComponent(owner))
            if audio == protected || audio.hasPrefix(protected + "/") {
                return "MACHUD_WAKE_CONFIRM_AUDIO is \(folder.path), inside \(owner): the owner's recordings are never "
                    + "transcribed by this test"
            }
        }
        return nil
    }

    /// The repository's fixture and the synthetic sets' own clips, whose words are known.
    static func showsWords(_ clip: URL) -> Bool {
        clip.standardizedFileURL == fixture.standardizedFileURL
            || ["positives", "confusables"].contains(clip.deletingLastPathComponent().lastPathComponent)
    }

    static var fixture: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../hudkit/Kits/VoiceKit/Tests/VoiceKitTests/Fixtures/hey-jarvis-16k.wav").standardized
    }

    static func wavFiles(under folder: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "wav" }
        return files.sorted { $0.path < $1.path }
    }

    static func name(_ clip: URL) -> String {
        "\(clip.deletingLastPathComponent().lastPathComponent)/\(clip.lastPathComponent)"
    }

    /// 16 kHz mono samples; other formats are converted.
    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false) else { throw CocoaError(.fileReadCorruptFile) }
        if input.sampleRate == 16_000, input.channelCount == 1, input.commonFormat == .pcmFormatFloat32,
           let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        guard let converter = AVAudioConverter(from: input, to: output),
              let converted = AVAudioPCMBuffer(
                pcmFormat: output, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / input.sampleRate) + 1024)
        else { throw CocoaError(.fileReadCorruptFile) }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let channel = converted.floatChannelData?[0] else { throw CocoaError(.fileReadCorruptFile) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    // MARK: Report

    static func report(_ rows: [Row], parakeet: String, loadSeconds: Double) -> String {
        var lines = ["", "Wake confirmation with the real models: \(parakeet) (loaded in \(String(format: "%.1f", loadSeconds)) s), "
            + "Hey Jarvis at threshold \(threshold), \(VoiceSettings().wakeFrames) frames", ""]
        lines.append(["clip".padding(toLength: 52, withPad: " ", startingAt: 0), "wake", "frames", "peak ",
                      "  ms", "phrase", "to come", "+0.3 s", "+0.6 s", "words"].joined(separator: "  "))
        for row in rows {
            let wake = row.wake
            lines.append([
                row.clip.padding(toLength: 52, withPad: " ", startingAt: 0),
                wake == nil ? "no  " : "yes ",
                wake.map { "\($0.frames)".padding(toLength: 6, withPad: " ", startingAt: 0) } ?? "-     ",
                wake.map { String(format: "%.3f", $0.peak) } ?? "-    ",
                String(format: "%4d", row.ms),
                row.confirmed ? "yes   " : "no    ",
                row.toCome.map { String(format: "%4d ms", $0) } ?? "      -",
                row.later.count > 0 ? (row.contains(row.later[0]) ? "yes   " : "no    ") : "-     ",
                row.later.count > 1 ? (row.contains(row.later[1]) ? "yes   " : "no    ") : "-     ",
                row.text + (row.later.isEmpty || !row.showsWords ? "" : " / " + row.later.map { Row.quote($0) }.joined(separator: " / ")),
            ].joined(separator: "  "))
        }
        func summary(_ title: String, _ subset: [Row]) {
            guard !subset.isEmpty else { return }
            let woke = subset.filter { $0.wake != nil }
            let times = woke.map(\.ms).sorted()
            func percentile(_ p: Double) -> Int { times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * p))] }
            let later = extraSeconds.indices.map { index in
                "\(woke.filter { $0.later.count > index && $0.contains($0.later[index]) }.count) with "
                    + String(format: "%.1f", extraSeconds[index]) + " s more"
            }
            lines.append("\(title): \(subset.count) clips, \(woke.count) wake, \(woke.filter(\.confirmed).count) of those "
                + "confirmed (\(later.joined(separator: ", "))); \(subset.filter(\.confirmed).count) of all transcribed with "
                + "the phrase. Confirmation of the wakes: min \(times.first ?? 0) ms, median \(percentile(0.5)) ms, "
                + "90th \(percentile(0.9)) ms, max \(times.last ?? 0) ms")
        }
        lines.append("")
        summary("fixture", rows.filter { $0.clip.hasPrefix("Fixtures/") })
        summary("positives", rows.filter { $0.clip.hasPrefix("positives/") })
        summary("confusables", rows.filter { $0.clip.hasPrefix("confusables/") })
        summary("other", rows.filter { !$0.clip.hasPrefix("Fixtures/") && !$0.clip.hasPrefix("positives/")
            && !$0.clip.hasPrefix("confusables/") })
        return lines.joined(separator: "\n")
    }
}
