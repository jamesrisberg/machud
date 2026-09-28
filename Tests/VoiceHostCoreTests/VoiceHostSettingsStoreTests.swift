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
            "MACHUD_CONFIG": "/tmp/cfg", "MACHUD_VOICE_SOCKET": "/tmp/v.sock",
            "MACHUD_VOICE_NO_MIC": "1", "MACHUD_NO_HOTKEYS": "1", "MACHUD_VOICE_NO_BRAIN": "1",
            "MACHUD_VOICE_PARENT_PIPE": "1",
        ])
        XCTAssertEqual(env.configDirectory.path, "/tmp/cfg")
        XCTAssertEqual(env.socketPath, "/tmp/v.sock")
        XCTAssertTrue(env.noMicrophone)
        XCTAssertTrue(env.noHotkeys)
        XCTAssertTrue(env.noBrain)
        XCTAssertTrue(env.parentPipe)
    }

    func testEnvironmentDefaults() {
        let env = VoiceHostEnvironment(environment: [:])
        XCTAssertTrue(env.configDirectory.path.hasSuffix("/.config/machud"))
        XCTAssertTrue(env.socketPath.hasSuffix("/machud-voice.sock"))
        XCTAssertFalse(env.noMicrophone || env.noHotkeys || env.noBrain || env.parentPipe)
    }
}
