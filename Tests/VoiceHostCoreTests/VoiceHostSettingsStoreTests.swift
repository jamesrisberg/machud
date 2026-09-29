import SpeakFreeLib
import XCTest
@testable import VoiceHostCore

final class VoiceHostSettingsStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileLoadsDefaults() {
        let store = VoiceHostSettingsStore(directory: directory)
        XCTAssertEqual(store.load(), VoiceHostSettings())
        XCTAssertEqual(store.url.lastPathComponent, "voice.json")
    }

    func testSaveThenLoadRoundTrips() throws {
        let store = VoiceHostSettingsStore(directory: directory)
        var settings = VoiceHostSettings()
        settings.keyMode = .toggle
        settings.brainEnabled = false
        settings.voice.speakReplies = true
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
    }

    func testUnreadableFileLoadsDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("voice.json"))
        XCTAssertEqual(VoiceHostSettingsStore(directory: directory).load(), VoiceHostSettings())
    }

    func testEnvironmentReadsIsolationVariables() {
        let env = VoiceHostEnvironment(environment: [
            "MACHUD_CONFIG": "/tmp/cfg/layouts.json", "MACHUD_VOICE_SOCKET": "/tmp/v.sock",
            "MACHUD_VOICE_NO_MIC": "1", "MACHUD_NO_HOTKEYS": "1", "MACHUD_VOICE_NO_BRAIN": "1",
            "MACHUD_VOICE_PARENT_PIPE": "1", "MACHUD_VOICE_NO_SPEECH": "1", "MACHUD_VOICE_MODELS_DIR": "/tmp/models",
            "MACHUD_VOICE_HISTORY_DIR": "/tmp/history", "SPEAKFREE_CONFIG_DIR": "/tmp/sf",
        ])
        XCTAssertEqual(env.configDirectory.path, "/tmp/cfg")
        XCTAssertEqual(env.socketPath, "/tmp/v.sock")
        XCTAssertTrue(env.noMicrophone)
        XCTAssertTrue(env.noHotkeys)
        XCTAssertTrue(env.noBrain)
        XCTAssertTrue(env.parentPipe)
        XCTAssertTrue(env.noSpeech)
        XCTAssertEqual(env.modelsDirectory?.path, "/tmp/models")
        XCTAssertEqual(env.historyDirectory?.path, "/tmp/history")
        XCTAssertEqual(env.speakFreeConfigDirectory.path, "/tmp/sf")
    }

    func testAnyNoHotkeysValueDisablesTheTap() {
        XCTAssertTrue(VoiceHostEnvironment(environment: ["MACHUD_NO_HOTKEYS": ""]).noHotkeys)
    }

    func testKeychainServiceCanBeIsolated() {
        XCTAssertEqual(VoiceHostEnvironment(environment: [:]).keychainService, "com.jrisberg.machud.voice")
        XCTAssertEqual(VoiceHostEnvironment(environment: ["MACHUD_VOICE_KEYCHAIN_SERVICE": "test.voice"]).keychainService,
                       "test.voice")
        XCTAssertEqual(VoiceHostEnvironment(environment: ["MACHUD_VOICE_KEYCHAIN_SERVICE": ""]).keychainService,
                       "com.jrisberg.machud.voice")
    }

    func testMacHUDSocketFollowsMACHUD_SOCKET() {
        XCTAssertEqual(VoiceHostEnvironment(environment: [:]).machudSocketPath, "/tmp/machud-\(getuid()).sock")
        XCTAssertEqual(VoiceHostEnvironment(environment: ["MACHUD_SOCKET": "/tmp/test.sock"]).machudSocketPath,
                       "/tmp/test.sock")
    }

    func testEnvironmentDefaults() {
        let env = VoiceHostEnvironment(environment: [:])
        XCTAssertTrue(env.configDirectory.path.hasSuffix("/.config/machud"))
        XCTAssertTrue(env.socketPath.hasSuffix("/machud-voice.sock"))
        XCTAssertFalse(env.noMicrophone || env.noHotkeys || env.noBrain || env.parentPipe || env.noSpeech)
        XCTAssertNil(env.modelsDirectory)
        XCTAssertNil(env.historyDirectory)
        XCTAssertTrue(env.speakFreeConfigDirectory.path.hasSuffix("/.config/speakfree"))
    }
}

@MainActor
final class DictationLeftoversTests: XCTestCase {
    func testRetentionKeepsNothingWhileTheHistoryIsOff() {
        let config = SpeakFreeDictation.retentionConfig(keep: false)
        XCTAssertEqual(config.saveRecordings?.value, false)
    }

    func testLeftoverRecordingsAndMarkerAreRemoved() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("voice-dictation-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let recordings = dir.appendingPathComponent("recordings")
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: recordings.appendingPathComponent("recording-1.wav"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".recording-in-progress.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        SpeakFreeDictation.removeLeftovers(in: dir)
        XCTAssertFalse(fm.fileExists(atPath: recordings.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(".recording-in-progress.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    }
}
