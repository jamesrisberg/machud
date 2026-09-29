import BrainKit
import XCTest
@testable import VoiceHostCore

final class BrainRuntimesTests: XCTestCase {
    private func locator(_ executables: Set<String>) -> ExecutableLocator {
        ExecutableLocator(path: "/opt/tools", home: "/Users/test", isExecutable: { executables.contains($0) },
                          contentsOfDirectory: { _ in [] })
    }

    func testDetectsEachRuntime() {
        let found = BrainRuntimes.detect(
            BrainSettings(), locator: locator(["/opt/tools/codex", "/Users/test/.local/bin/mclaude"]),
            readFile: { _ in nil })
        XCTAssertEqual(found.map(\.id), ["codex", "claude", "hermes", "mclaude"])
        XCTAssertEqual(found[0], BrainRuntimeDetection(id: "codex", name: "Codex", installed: true, path: "/opt/tools/codex"))
        XCTAssertFalse(found[1].installed)
        XCTAssertFalse(found[2].installed)
        XCTAssertEqual(found[2].apiServerEnabled, false)
        XCTAssertEqual(found[3].path, "/Users/test/.local/bin/mclaude")
    }

    func testAnOverrideWins() {
        var brain = BrainSettings()
        brain.claude.executablePath = "/custom/claude"
        let found = BrainRuntimes.detect(brain, locator: locator(["/custom/claude", "/opt/tools/claude"]), readFile: { _ in nil })
        XCTAssertEqual(found[1].path, "/custom/claude")
    }

    func testProblems() {
        let brain = BrainSettings()
        let detections = BrainRuntimes.detect(brain, locator: locator(["/opt/tools/hermes"]),
                                              readFile: { _ in "API_SERVER_ENABLED=false" })
        XCTAssertEqual(BrainRuntimes.problem(runtime: "codex", brain: brain, detections: detections), "Codex is not installed.")
        XCTAssertEqual(BrainRuntimes.problem(runtime: "mclaude", brain: brain, detections: detections), "mclaude is not installed.")
        XCTAssertEqual(BrainRuntimes.problem(runtime: "hermes", brain: brain, detections: detections),
                       "Hermes' API server is off: set API_SERVER_ENABLED=true in ~/.hermes/.env.")
        var withURL = brain
        withURL.hermes.url = "http://127.0.0.1:8642"
        XCTAssertNil(BrainRuntimes.problem(runtime: "hermes", brain: withURL, detections: detections))
        XCTAssertNil(BrainRuntimes.problem(runtime: "unknown", brain: brain, detections: detections))
    }

    @MainActor
    func testServiceStatesMapToHealth() {
        XCTAssertEqual(BrainConnection.health(.unavailable("No node"), clientConnected: false), .unavailable("No node"))
        XCTAssertEqual(BrainConnection.health(.running, clientConnected: false), .connecting)
        XCTAssertEqual(BrainConnection.health(.running, clientConnected: true), .ready)
        XCTAssertEqual(BrainConnection.health(.backingOff(attempt: 2, delay: 4, reason: "exit 1"), clientConnected: false),
                       .restarting("exit 1"))
        XCTAssertEqual(BrainConnection.health(.failed("exit 1"), clientConnected: false), .failed("exit 1"))
        XCTAssertEqual(BrainConnection.health(.starting, clientConnected: false), .starting)
    }
}
