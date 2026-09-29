import VoiceKit
import XCTest
@testable import VoiceHostCore

/// The "Keep dictation history" setting: how it resolves on a Mac with or without SpeakFree,
/// how a finished take is filed in SpeakFree's layout, and `history status`.
@MainActor
final class DictationHistoryTests: XCTestCase {
    private var root: URL!
    private var machud: URL { root.appendingPathComponent("MacHUD/Voice/History", isDirectory: true) }
    private var speakFree: URL { root.appendingPathComponent("speakfree", isDirectory: true) }
    private var scratch: URL { root.appendingPathComponent("Dictation/recordings", isDirectory: true) }
    private var installed = false

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        installed = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var locator: DictationHistoryLocator {
        let installed = self.installed
        return DictationHistoryLocator(machudFolder: machud, speakFreeConfigDirectory: speakFree,
                                       isSpeakFreeInstalled: { installed })
    }

    /// SpeakFree's `config.json` with its own `saveRecordings` choice.
    private func speakFreeSaves(_ value: Any) throws {
        try FileManager.default.createDirectory(at: speakFree, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["language": "en", "saveRecordings": value])
        try data.write(to: speakFree.appendingPathComponent("config.json"))
    }

    // MARK: Setting

    func testSettingDecodesLenientlyAndStaysAbsentWhenNotSaved() throws {
        let decoded = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(#"{"enabled": true}"#.utf8))
        XCTAssertNil(decoded.history)
        XCTAssertTrue(decoded.feedTranscripts)
        XCTAssertFalse(decoded.feedAgentReplies)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["history"], "absent stays absent, so the default rule keeps applying")

        let json = #"{"history": {"mode": "text", "shareWithSpeakFree": true}, "feedTranscripts": false, "feedAgentReplies": true}"#
        let saved = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(json.utf8))
        XCTAssertEqual(saved.history, DictationHistorySettings(mode: .text, shareWithSpeakFree: true))
        XCTAssertFalse(saved.feedTranscripts)
        XCTAssertTrue(saved.feedAgentReplies)

        let odd = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(#"{"history": {"mode": "loud"}}"#.utf8))
        XCTAssertEqual(odd.history, DictationHistorySettings(mode: .off, shareWithSpeakFree: false))
    }

    // MARK: Default rule

    func testWithoutSpeakFreeTheDefaultIsOffInMacHUDsFolder() {
        let plan = locator.plan(for: nil)
        XCTAssertEqual(plan, DictationHistoryPlan(mode: .off, shareWithSpeakFree: false, speakFreeInstalled: false,
                                                  folder: machud, isDefault: true))
        XCTAssertFalse(plan.keeps)
    }

    func testWithSpeakFreeSavingTheDefaultFollowsItIntoItsFolder() throws {
        installed = true
        try speakFreeSaves(true)
        let plan = locator.plan(for: nil)
        XCTAssertEqual(plan.mode, .textAndAudio)
        XCTAssertTrue(plan.shareWithSpeakFree)
        XCTAssertEqual(plan.folder, speakFree.appendingPathComponent("recordings", isDirectory: true))
        XCTAssertTrue(plan.isDefault)
    }

    func testWithSpeakFreeNotSavingTheDefaultIsOff() throws {
        installed = true
        try speakFreeSaves("false")
        XCTAssertEqual(locator.plan(for: nil).mode, .off)
        try FileManager.default.removeItem(at: speakFree.appendingPathComponent("config.json"))
        XCTAssertEqual(locator.plan(for: nil).mode, .off, "no config: SpeakFree's own default, nothing kept")
    }

    func testAChoiceWinsAndSharingNeedsSpeakFree() {
        let choice = DictationHistorySettings(mode: .text, shareWithSpeakFree: true)
        var plan = locator.plan(for: choice)
        XCTAssertEqual(plan.mode, .text)
        XCTAssertFalse(plan.shareWithSpeakFree, "SpeakFree is not installed")
        XCTAssertEqual(plan.folder, machud)
        XCTAssertFalse(plan.isDefault)
        installed = true
        plan = locator.plan(for: choice)
        XCTAssertTrue(plan.shareWithSpeakFree)
        XCTAssertEqual(plan.folder, locator.speakFreeRecordings)
    }

    func testSpeakFreeCountsAsInstalledWithItsConfig() throws {
        let live = DictationHistoryLocator.live(machudFolder: machud, speakFreeConfigDirectory: speakFree)
        let before = live.isSpeakFreeInstalled()
        try speakFreeSaves(true)
        XCTAssertTrue(live.isSpeakFreeInstalled())
        _ = before   // LaunchServices may know the real app; the config alone is enough.
    }

    // MARK: Filing

    /// A take as SpeakFree's `finishRecording(keep: true)` leaves it in the scratch folder.
    private func take(_ stem: String = "recording-2026-09-28-101500-abcd1234") throws -> URL {
        let wav = scratch.appendingPathComponent("\(stem).wav")
        try Data(repeating: 1, count: 2048).write(to: wav)
        try "Hello there.".write(to: scratch.appendingPathComponent("\(stem).txt"), atomically: true, encoding: .utf8)
        try "hello there".write(to: scratch.appendingPathComponent("\(stem).raw.txt"), atomically: true, encoding: .utf8)
        try Data("{}".utf8).write(to: scratch.appendingPathComponent("\(stem).meta.json"))
        return wav
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testTextAndAudioMovesTheRecordingAndItsSidecars() throws {
        let wav = try take()
        let plan = locator.plan(for: DictationHistorySettings(mode: .textAndAudio))
        let written = DictationHistoryFiler.file(recording: wav, plan: plan)
        XCTAssertEqual(written.map(\.lastPathComponent), [
            "recording-2026-09-28-101500-abcd1234.txt", "recording-2026-09-28-101500-abcd1234.raw.txt",
            "recording-2026-09-28-101500-abcd1234.meta.json", "recording-2026-09-28-101500-abcd1234.wav",
        ], "sidecars before the recording")
        XCTAssertEqual(names(in: machud).count, 4)
        XCTAssertEqual(names(in: scratch), [])
        XCTAssertEqual(try String(contentsOf: machud.appendingPathComponent("recording-2026-09-28-101500-abcd1234.txt"),
                                  encoding: .utf8), "Hello there.")
        let attributes = try FileManager.default.attributesOfItem(atPath: machud.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testTextOnlyKeepsTheSidecarsAndDeletesTheRecording() throws {
        installed = true
        let wav = try take()
        let plan = locator.plan(for: DictationHistorySettings(mode: .text, shareWithSpeakFree: true))
        DictationHistoryFiler.file(recording: wav, plan: plan)
        XCTAssertEqual(names(in: locator.speakFreeRecordings), [
            "recording-2026-09-28-101500-abcd1234.meta.json", "recording-2026-09-28-101500-abcd1234.raw.txt",
            "recording-2026-09-28-101500-abcd1234.txt",
        ])
        XCTAssertEqual(names(in: scratch), [])
    }

    func testOffFilesNothing() throws {
        let wav = try take()
        XCTAssertEqual(DictationHistoryFiler.file(recording: wav, plan: locator.plan(for: nil)), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: machud.path))
        XCTAssertEqual(names(in: scratch).count, 4, "the scratch sweep deletes it")
    }

    func testRetentionKeepsWhileTheHistoryDoesAndNeverPrunes() {
        XCTAssertEqual(SpeakFreeDictation.retentionConfig(keep: true).saveRecordings?.value, true)
        XCTAssertEqual(SpeakFreeDictation.retentionConfig(keep: false).saveRecordings?.value, false)
        XCTAssertEqual(SpeakFreeDictation.retentionConfig(keep: true).preserveAllRecordings?.value, true)
    }

    // MARK: history status

    private func commands(_ settings: VoiceHostSettings) -> (VoiceHostCommands, FakeDictation) {
        let dictation = FakeDictation()
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: nil, brain: nil, speaker: nil, wake: nil,
            brainStateRoot: root, detectRuntimes: FakeRuntimes.detect(), schedule: { _, _ in })
        controller.start()
        let commands = VoiceHostCommands(controller: controller, store: VoiceHostSettingsStore(directory: root),
                                         secrets: InMemoryVoiceSecretStore(), version: "dev", history: locator)
        return (commands, dictation)
    }

    func testHistoryStatusReportsTheResolvedPlan() throws {
        installed = true
        try speakFreeSaves(true)
        let (commands, dictation) = commands(VoiceHostSettings())
        XCTAssertEqual(dictation.histories, [nil], "the setting reaches the dictation")
        let reply = commands.handle("history", ["action": "status"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["mode"] as? String, "textAndAudio")
        XCTAssertEqual(reply["shareWithSpeakFree"] as? Bool, true)
        XCTAssertEqual(reply["speakFreeInstalled"] as? Bool, true)
        XCTAssertEqual(reply["folder"] as? String, locator.speakFreeRecordings.path)
        XCTAssertEqual(reply["default"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(reply))
        XCTAssertEqual(commands.handle("history", [:])["ok"] as? Bool, true)
        XCTAssertEqual(commands.handle("history", ["action": "clear"])["ok"] as? Bool, false)
    }

    func testSettingsSetHandsTheHistoryToTheDictation() {
        let (commands, dictation) = commands(VoiceHostSettings())
        let reply = commands.handle("settings", ["action": "set", "settings": #"{"history": {"mode": "text", "shareWithSpeakFree": false}}"#])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(dictation.histories.last, DictationHistorySettings(mode: .text))
        let status = commands.handle("history", ["action": "status"])
        XCTAssertEqual(status["mode"] as? String, "text")
        XCTAssertEqual(status["folder"] as? String, machud.path)
        XCTAssertEqual(status["default"] as? Bool, false)
    }
}
