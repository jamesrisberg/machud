import HUDKit
import XCTest
@testable import VoiceHostCore

/// `MacHUDSessions` against a stand-in MacHUD control socket answering `sessions`.
@MainActor
final class MacHUDSessionsTests: XCTestCase {
    private var dir: URL!
    private var server: HUDSocketServer!
    private var requests: [[String: String]] = []
    private var providers: [[String: Any]] = []
    private var openReply: [String: Any] = ["ok": true, "app": "Sessions"]

    override func setUp() async throws {
        // Short: socket paths are limited to 103 bytes.
        dir = URL(fileURLWithPath: "/tmp/mhs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        server = HUDSocketServer(path: dir.appendingPathComponent("m.sock").path, label: "machud.test.sessions")
        server.register("sessions") { [unowned self] args, done in
            self.requests.append(args)
            switch args["_"] {
            case "open": done(self.openReply)
            case "providers": done(["ok": true, "providers": self.providers])
            default: done(["ok": false, "error": "sessions takes open or providers"])
            }
        }
        XCTAssertTrue(server.start())
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private var sessions: MacHUDSessions { MacHUDSessions(socketPath: server.path, timeout: 5) }

    func testOpenSendsTheKeyTheWayTheCLIDoes() async {
        let result = await sessions.open(id: "claude:abc")
        XCTAssertEqual(result, .success("Sessions"))
        XCTAssertEqual(requests.last?["_"], "open")
        XCTAssertEqual(requests.last?["id"], "claude:abc")
    }

    func testOpenReportsMacHUDsError() async {
        openReply = ["ok": false, "error": "No app shows agent sessions"]
        let result = await sessions.open(id: "claude:abc")
        XCTAssertEqual(result, .failure(SessionOpenError(message: "No app shows agent sessions")))
    }

    func testMacHUDNotAnswering() async {
        let result = await MacHUDSessions(socketPath: dir.appendingPathComponent("none.sock").path).open(id: "x")
        XCTAssertEqual(result, .failure(SessionOpenError(message: MacHUDSessions.unreachable)))
        let name = await MacHUDSessions(socketPath: dir.appendingPathComponent("none.sock").path).providerName()
        XCTAssertNil(name)
    }

    func testProviderPrefersARunningApp() async {
        providers = [["app": "Installed", "socket": "/a", "running": false], ["app": "Running", "socket": "/b", "running": true]]
        let running = await sessions.providerName()
        XCTAssertEqual(running, "Running")
        providers = [["app": "Installed", "socket": "/a", "running": false]]
        let installed = await sessions.providerName()
        XCTAssertEqual(installed, "Installed")
        providers = []
        let none = await sessions.providerName()
        XCTAssertNil(none)
    }
}
