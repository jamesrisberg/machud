import BrainKit
import XCTest
@testable import VoiceHostCore

final class BrainRuntimesTests: XCTestCase {
    private var runtimes: URL!

    override func setUpWithError() throws {
        runtimes = FileManager.default.temporaryDirectory.appendingPathComponent("runtimes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtimes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: runtimes)
    }

    private func locator(_ executables: Set<String>) -> ExecutableLocator {
        ExecutableLocator(path: "/opt/tools", home: "/Users/test", isExecutable: { executables.contains($0) },
                          contentsOfDirectory: { _ in [] }, runtimesDirectory: runtimes.path)
    }

    /// A runtime plugin folder as BrainKit trusts it: owned by this user, writable by no one else.
    private func writePlugin(_ id: String, _ manifest: [String: Any] = [:]) throws {
        let folder = runtimes.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var value: [String: Any] = ["schema": 1, "id": id, "title": "Example Agent", "version": "1.0.0",
                                    "adapter": "adapter.mjs", "executable": id]
        value.merge(manifest) { $1 }
        try JSONSerialization.data(withJSONObject: value).write(to: folder.appendingPathComponent("runtime.json"))
        try Data("export default () => null;\n".utf8).write(to: folder.appendingPathComponent("adapter.mjs"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        for file in ["runtime.json", "adapter.mjs"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: folder.appendingPathComponent(file).path)
        }
    }

    func testDetectsTheBuiltInsInBrainKitsOrder() {
        let found = BrainRuntimes.detect(BrainSettings(), locator: locator(["/opt/tools/codex"]), readFile: { _ in nil })
        XCTAssertEqual(found.map(\.id), ["codex", "hermes", "claude"])
        XCTAssertEqual(found.map(\.name), ["Codex", "Hermes", "Claude"])
        XCTAssertTrue(found[0].installed)
        XCTAssertEqual(found[0].path, "/opt/tools/codex")
        XCTAssertNil(found[0].unavailableReason)
        XCTAssertFalse(found[0].plugin)
        XCTAssertEqual(found[0].installCommand, BrainCatalog.entry(for: .codex)?.installCommand)
        XCTAssertEqual(found[0].loginCommand, "codex login")
        XCTAssertNotNil(found[0].summary)
        XCTAssertNotNil(found[0].docsURL)
        XCTAssertFalse(found[1].installed)
        XCTAssertEqual(found[1].apiServerEnabled, false)
        XCTAssertEqual(found[2].unavailableReason, "Claude is not installed.")
    }

    func testListsEachRuntimePluginWithWhatItSaysAboutItself() throws {
        try writePlugin("example-agent", ["note": "Runs in its own app too.", "summary": "An example runtime.",
                                          "installCommand": "brew install example-agent",
                                          "docsURL": "https://example.com/agent"])
        let found = BrainRuntimes.detect(BrainSettings(), locator: locator(["/opt/tools/example-agent"]),
                                         readFile: { _ in nil })
        XCTAssertEqual(found.map(\.id), ["codex", "hermes", "claude", "example-agent"])
        let plugin = found[3]
        XCTAssertEqual(plugin.name, "Example Agent")
        XCTAssertTrue(plugin.plugin)
        XCTAssertTrue(plugin.installed)
        XCTAssertEqual(plugin.path, "/opt/tools/example-agent")
        XCTAssertNil(plugin.unavailableReason)
        XCTAssertEqual(plugin.note, "Runs in its own app too.")
        XCTAssertEqual(plugin.summary, "An example runtime.")
        XCTAssertEqual(plugin.installCommand, "brew install example-agent")
        XCTAssertEqual(plugin.docsURL, URL(string: "https://example.com/agent"))
    }

    func testAPluginsPathOverrideWins() throws {
        try writePlugin("example-agent")
        var brain = BrainSettings()
        brain.plugins["example-agent"] = .init(executablePath: "/custom/example-agent")
        let found = BrainRuntimes.detect(brain, locator: locator(["/custom/example-agent", "/opt/tools/example-agent"]),
                                         readFile: { _ in nil })
        XCTAssertEqual(found.first { $0.id == "example-agent" }?.path, "/custom/example-agent")
    }

    func testAnOverrideWins() {
        var brain = BrainSettings()
        brain.claude.executablePath = "/custom/claude"
        let found = BrainRuntimes.detect(brain, locator: locator(["/custom/claude", "/opt/tools/claude"]), readFile: { _ in nil })
        XCTAssertEqual(found.first { $0.id == "claude" }?.path, "/custom/claude")
    }

    /// A saved runtime whose plugin is gone stays listed, unavailable with BrainKit's reason,
    /// rather than being dropped or switched.
    func testAChosenPluginThatIsNotInstalledIsListedWithItsReason() {
        var brain = BrainSettings()
        brain.runtime = AgentRuntime(rawValue: "example-agent")!
        let found = BrainRuntimes.detect(brain, locator: locator([]), readFile: { _ in nil })
        XCTAssertEqual(found.map(\.id), ["codex", "hermes", "claude", "example-agent"])
        XCTAssertFalse(found[3].installed)
        XCTAssertTrue(found[3].plugin)
        let reason = found[3].unavailableReason
        XCTAssertEqual(reason, "The plugin folder \(runtimes.path)/example-agent is missing")
        XCTAssertEqual(BrainRuntimes.problem(runtime: "example-agent", brain: brain, detections: found), reason)
    }

    func testAPluginMissingWhatItRequiresIsUnavailable() throws {
        try writePlugin("example-agent", ["requires": ["example-tool"]])
        let found = BrainRuntimes.detect(BrainSettings(), locator: locator(["/opt/tools/example-agent"]),
                                         readFile: { _ in nil })
        let plugin = try XCTUnwrap(found.first { $0.id == "example-agent" })
        XCTAssertTrue(plugin.installed)
        XCTAssertEqual(plugin.unavailableReason, "Example Agent needs example-tool, which is not installed.")
    }

    func testProblems() {
        let brain = BrainSettings()
        let detections = BrainRuntimes.detect(brain, locator: locator(["/opt/tools/hermes"]),
                                              readFile: { _ in "API_SERVER_ENABLED=false" })
        XCTAssertEqual(BrainRuntimes.problem(runtime: "codex", brain: brain, detections: detections), "Codex is not installed.")
        XCTAssertEqual(BrainRuntimes.problem(runtime: "claude", brain: brain, detections: detections), "Claude is not installed.")
        XCTAssertEqual(BrainRuntimes.problem(runtime: "hermes", brain: brain, detections: detections),
                       "Hermes' API server is off: set API_SERVER_ENABLED=true in ~/.hermes/.env.")
        var withURL = brain
        withURL.hermes.url = "http://127.0.0.1:8642"
        XCTAssertNil(BrainRuntimes.problem(runtime: "hermes", brain: withURL, detections: detections))
        XCTAssertNil(BrainRuntimes.problem(runtime: "unknown", brain: brain, detections: detections))
    }

    /// `brain status`'s entry: availability with the reason, and what the runtime says about itself.
    func testStatusEntries() throws {
        try writePlugin("example-agent", ["note": "Runs in its own app too.", "loginCommand": "example-agent login"])
        let brain = BrainSettings()
        let detections = BrainRuntimes.detect(brain, locator: locator(["/opt/tools/codex", "/opt/tools/example-agent"]),
                                              readFile: { _ in nil })
        let entries = BrainRuntimes.status(detections, brain: brain)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(entries))
        XCTAssertEqual(entries.map { $0["id"] as? String }, ["codex", "hermes", "claude", "example-agent"])
        XCTAssertEqual(entries[0]["available"] as? Bool, true)
        XCTAssertNil(entries[0]["reason"])
        XCTAssertEqual(entries[0]["plugin"] as? Bool, false)
        XCTAssertEqual(entries[1]["available"] as? Bool, false)
        XCTAssertEqual(entries[1]["reason"] as? String, "Hermes is not installed.")
        XCTAssertEqual(entries[1]["apiServer"] as? Bool, false)
        XCTAssertEqual(entries[3]["plugin"] as? Bool, true)
        XCTAssertEqual(entries[3]["name"] as? String, "Example Agent")
        XCTAssertEqual(entries[3]["note"] as? String, "Runs in its own app too.")
        XCTAssertEqual(entries[3]["loginCommand"] as? String, "example-agent login")
        XCTAssertEqual(entries[3]["loginTitle"] as? String, "Log In")
        XCTAssertEqual(entries[3]["available"] as? Bool, true)
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
