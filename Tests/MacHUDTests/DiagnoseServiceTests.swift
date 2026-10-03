import XCTest
import HUDKit
@testable import MacHUDCore

/// The `diagnose` verb: it gathers the four replies, builds the snapshot, writes it and answers
/// with the path and the anomalies.
@MainActor
final class DiagnoseServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnose-service-\(getpid())-\(Int.random(in: 0..<100_000))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshotProviders(_ replies: [String: [String: Any]]) -> DiagnoseSnapshot.Providers {
        DiagnoseSnapshot.Providers(
            now: { Date(timeIntervalSince1970: 1_790_000_000) },
            machud: { .init(version: "0.3.1", build: nil, pid: 1, launchedAt: nil, isolated: true) },
            displays: { [] }, frontmost: { nil }, processes: { [] }, serverWindows: { [] }, spaces: { _ in nil },
            appKitWindows: { [] }, replies: replies)
    }

    private func service(sources: [String: DiagnoseService.Source]) -> DiagnoseService {
        DiagnoseService(sources: sources, providers: { [unowned self] in self.snapshotProviders($0) },
                        store: DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!))
    }

    private func run(_ service: DiagnoseService) -> [String: Any] {
        var reply: [String: Any]?
        service.run { reply = $0 }
        XCTAssertTrue(spin(until: { reply != nil }), "no reply")
        return reply ?? [:]
    }

    func testItReplaysTheFourVerbsRepliesIntoTheFileAndAnswersWithItsPath() throws {
        let service = service(sources: [
            "tooldock": { $0(["ok": true, "position": "bottom"]) },
            "widgets": { $0(["ok": true, "instances": []]) },
            "voiceStatus": { $0(["ok": true, "status": "disabled", "connected": false]) },
            // The voice host answers later, over its socket.
            "voiceState": { done in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { done(["ok": true, "state": ["phase": ["name": "idle"]]]) }
            },
        ])
        let reply = run(service)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(Set(reply.keys), ["ok", "path", "anomalies"])
        XCTAssertEqual(reply["anomalies"] as? [String], [])
        let path = try XCTUnwrap(reply["path"] as? String)
        XCTAssertTrue(path.hasSuffix("/diagnose-20260921-141320.json"), path)

        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let replies = try XCTUnwrap(file["replies"] as? [String: Any])
        XCTAssertEqual((replies["tooldock"] as? [String: Any])?["position"] as? String, "bottom")
        XCTAssertEqual(((replies["voiceState"] as? [String: Any])?["state"] as? [String: Any])?["phase"] as? [String: String], ["name": "idle"],
                       "the slow reply was waited for")
    }

    func testASourceThatAnswersTwiceIsCountedOnce() {
        var builds = 0
        let service = DiagnoseService(
            sources: ["tooldock": { $0(["ok": true]); $0(["ok": false]) },
                      "voiceState": { done in DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done(["ok": true]) } }],
            providers: { [unowned self] in builds += 1; return self.snapshotProviders($0) },
            store: DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!))
        _ = run(service)
        XCTAssertEqual(builds, 1)
    }

    func testAnUnwritableFolderIsReportedNotSwallowed() throws {
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        let broken = DiagnoseService(sources: [:], providers: { [unowned self] in self.snapshotProviders($0) },
                                     store: DiagnoseStore(directory: file.appendingPathComponent("inside")))
        let reply = run(broken)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").hasPrefix("could not write the snapshot to "), "\(reply)")
    }

    func testItAnswersOverTheControlSocket() throws {
        let service = service(sources: ["tooldock": { $0(["ok": true]) }])
        let path = "/tmp/diag-\(getpid())-\(Int.random(in: 0..<100_000)).sock"
        let server = HUDSocketServer(path: path, label: "machud.test.diagnose")
        service.registerControl(server)
        XCTAssertTrue(server.commands.contains("diagnose"))
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var reply: [String: Any]?
        DispatchQueue.global().async {
            let r = try? HUDSocketClient(path: path, timeout: 10).request("diagnose", args: [:])
            DispatchQueue.main.async { reply = r ?? ["failed": true] }
        }
        XCTAssertTrue(spin(until: { reply != nil }, timeout: 10))
        XCTAssertEqual(reply?["ok"] as? Bool, true, "\(reply ?? [:])")
        let written = try XCTUnwrap(reply?["path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: written))
    }

    // MARK: - Full-screen desktops

    func testFullScreenDesktopsAreReadFromThePlistByDisplay() {
        let plist: [String: Any] = ["SpacesDisplayConfiguration": ["Management Data": ["Monitors": [
            ["Display Identifier": "Main", "Spaces": [["ManagedSpaceID": 4, "type": 0], ["ManagedSpaceID": 9, "type": 4]]],
            ["Display Identifier": "ABC", "Spaces": [["ManagedSpaceID": 21, "type": 0]]],
            ["Display Identifier": "OLD"],
        ]]]]
        XCTAssertEqual(DiagnoseLive.fullScreenSpaceIDs(in: plist), ["Main": [9]])
        XCTAssertEqual(DiagnoseLive.fullScreenSpaceIDs(in: [:]), [:])
    }
}
