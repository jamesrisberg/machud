import SpeakFreeLib
import XCTest
@testable import VoiceHostCore

/// A wake's audio goes to SpeakFree's engine straight from memory, and why it could not is one of
/// three answers. The engine is a fake: no model loads, no microphone opens.
@MainActor
final class WakeAudioTranscriptionTests: XCTestCase {
    func testWithoutASpeechModelThereIsNothingToConfirmWith() async {
        let answer = await transcribe([0.1], with: nil)
        XCTAssertEqual(answer, .failure(.noModel))
    }

    func testAModelStillLoadingSaysSoAndIsLoaded() async {
        let engine = FakeEngine(loaded: false)
        let answer = await transcribe([0.1], with: Transcriber(engine: engine, modelID: "parakeet-tdt-0.6b-v2", language: "en"))
        XCTAssertEqual(answer, .failure(.loading))
        await waitUntil { engine.loads == ["parakeet-tdt-0.6b-v2"] }
        XCTAssertTrue(engine.transcribed.isEmpty, "nothing is transcribed by a model that is not loaded")
    }

    func testTheAudioIsTranscribedAsItIs() async {
        let engine = FakeEngine(loaded: true)
        engine.words = "Hey, Jarvis."
        let audio: [Float] = [0.1, -0.2, 0.3]
        let answer = await transcribe(audio, with: Transcriber(engine: engine, modelID: "m", language: "fr"), language: "fr")
        XCTAssertEqual(answer, .success("Hey, Jarvis."))
        XCTAssertEqual(engine.transcribed, [audio])
        XCTAssertEqual(engine.languages, ["fr"])
    }

    func testAnEngineThatFailsSaysSo() async {
        let engine = FakeEngine(loaded: true)
        engine.failure = TranscriptionEngineError.transcriptionFailed
        let answer = await transcribe([0.1], with: Transcriber(engine: engine, modelID: "m", language: "en"))
        XCTAssertEqual(answer, .failure(.failed))
    }

    private func transcribe(_ audio: [Float], with transcriber: Transcriber?,
                            language: String = "en") async -> Result<String, WakeConfirmFailure> {
        await withCheckedContinuation { continuation in
            WakeAudioTranscription.transcribe(audio, with: transcriber, language: language) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// A transcription engine that loads nothing and says what it is told.
private final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Bool
    private var _loads: [String] = []
    private var _transcribed: [[Float]] = []
    private var _languages: [String] = []
    var words = ""
    var failure: Error?

    init(loaded: Bool) { self.loaded = loaded }

    var loads: [String] { lock.withLock { _loads } }
    var transcribed: [[Float]] { lock.withLock { _transcribed } }
    var languages: [String] { lock.withLock { _languages } }

    var engineID: String { "parakeet" }
    var isLoaded: Bool { lock.withLock { loaded } }
    var supportsStreaming: Bool { false }
    var supportsPrompt: Bool { false }
    var keepModelLoaded = "auto"

    func loadModel(modelID: String) async throws {
        lock.withLock {
            _loads.append(modelID)
            loaded = true
        }
    }

    func unloadModel() async {}
    func startMemoryPressureMonitoring() {}

    func transcribe(samples: [Float], language: String, prompt: String?, suppressRegex: String?) async throws -> String {
        lock.withLock {
            _transcribed.append(samples)
            _languages.append(language)
        }
        if let failure { throw failure }
        return words
    }

    func transcribeStreaming(samples: [Float], language: String, prompt: String?, suppressRegex: String?,
                             onPartialResult: @escaping (String) -> Void) async throws -> String {
        throw TranscriptionEngineError.streamingUnsupported
    }
}
