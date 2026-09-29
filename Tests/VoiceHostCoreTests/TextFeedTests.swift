import HUDKit
import XCTest
@testable import VoiceHostCore

/// Finished dictations (and, when asked, agent replies) going to MacHUD's text feed.
@MainActor
final class TextFeedTests: XCTestCase {
    private var dictation: FakeDictation!
    private var brain: FakeBrain!
    private var feed: FakeFeed!

    override func setUp() async throws {
        dictation = FakeDictation()
        brain = FakeBrain()
        feed = FakeFeed()
    }

    private func makeController(_ settings: VoiceHostSettings = VoiceHostSettings()) -> VoiceHostController {
        let controller = VoiceHostController(
            settings: settings, dictation: dictation, keys: nil, brain: brain, speaker: nil, wake: nil,
            brainStateRoot: URL(fileURLWithPath: "/tmp/voice-tests/Brain"), feed: feed,
            detectRuntimes: FakeRuntimes.detect(), schedule: { _, _ in })
        controller.start()
        return controller
    }

    func testACursorDictationSendsItsTranscript() {
        let controller = makeController()
        controller.perform(.start(.dictation))
        controller.perform(.stop)
        dictation.finish("Hello there!", transcript: "Hello there.")
        XCTAssertEqual(feed.items, [FakeFeed.Item(text: "Hello there.", source: "Dictation", title: nil)])
    }

    func testAnAgentTakeSendsItsTranscriptToo() async {
        let controller = makeController()
        controller.perform(.start(.agent))
        controller.perform(.stop)
        dictation.finish("list my files")
        await controller.pendingWork?.value
        XCTAssertEqual(feed.items.map(\.text), ["list my files"])
        XCTAssertEqual(brain.submitted.map(\.text), ["list my files"])
        // Agent replies are not sent by default.
        brain.push(status: "idle", output: "Here they are.")
        XCTAssertEqual(feed.items.count, 1)
    }

    func testFeedTranscriptsOffSendsNothing() {
        var settings = VoiceHostSettings()
        settings.feedTranscripts = false
        let controller = makeController(settings)
        controller.perform(.start(.dictation))
        dictation.finish("Private note.")
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testAnEmptyTakeSendsNothing() {
        let controller = makeController()
        controller.perform(.start(.dictation))
        dictation.finish("  ")
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testAgentRepliesGoWhenAsked() async {
        var settings = VoiceHostSettings()
        settings.feedAgentReplies = true
        settings.feedTranscripts = false
        let controller = makeController(settings)
        controller.perform(.start(.agent))
        controller.perform(.stop)
        dictation.finish("list my files")
        await controller.pendingWork?.value
        brain.push(status: "running", output: "Looking")
        XCTAssertTrue(feed.items.isEmpty, "only a finished reply")
        brain.push(status: "idle", output: "Here they are.")
        XCTAssertEqual(feed.items, [FakeFeed.Item(text: "Here they are.", source: "Agent", title: "list my files")])
    }

    // MARK: MacHUDFeed

    func testMacHUDFeedSendsFeedAddTheWayTheCLIDoes() throws {
        let dir = URL(fileURLWithPath: "/tmp/mhf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = HUDSocketServer(path: dir.appendingPathComponent("m.sock").path, label: "machud.test.feed")
        let received = expectation(description: "feed add")
        var requests: [[String: String]] = []
        server.register("feed") { args, done in
            requests.append(args)
            done(["ok": true, "delivered": []])
            received.fulfill()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        MacHUDFeed(socketPath: server.path).add(text: "Hello there.", source: "Dictation", title: nil)
        wait(for: [received], timeout: 5)
        XCTAssertEqual(requests.first?["_"], "add")
        XCTAssertEqual(requests.first?["action"], "add")
        XCTAssertEqual(requests.first?["text"], "Hello there.")
        XCTAssertEqual(requests.first?["source"], "Dictation")
        XCTAssertNil(requests.first?["title"])
    }

    func testMacHUDFeedNeverWaitsOnAMacHUDThatIsNotThere() {
        let started = Date()
        MacHUDFeed(socketPath: "/tmp/no-such-machud-\(UUID().uuidString.prefix(6)).sock")
            .add(text: "x", source: "Dictation", title: "t")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertEqual(MacHUDFeed.arguments(text: "x", source: "Agent", title: "t")["title"], "t")
    }
}
