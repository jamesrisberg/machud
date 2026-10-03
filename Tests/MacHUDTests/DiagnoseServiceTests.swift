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

    // MARK: - The window server lags AppKit

    /// A voice host that is off, so it is not itself an anomaly.
    private static let quietVoice: [String: DiagnoseService.Source] = ["voiceStatus": { $0(["ok": true, "status": "disabled", "connected": false]) }]

    private let ghost = DiagnoseSnapshot.AppKitWindow(
        number: 4242, identifier: "ghost", title: nil, className: "NSPanel", isVisible: true, isOnActiveSpace: true, alpha: 1, level: 0,
        collectionBehavior: 0, frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    /// A service whose AppKit view shows `ghost` on the readings listed (true) and not (false), in
    /// order, the last one repeating; the window server never lists it. Delays are recorded and run at once.
    private func settling(readings: [Bool], delays: @escaping (TimeInterval) -> Void) -> DiagnoseService {
        var reading = 0
        return DiagnoseService(
            sources: Self.quietVoice,
            providers: { [unowned self] replies in
                var p = self.snapshotProviders(replies)
                p.appKitWindows = {
                    defer { reading += 1 }
                    return readings[min(reading, readings.count - 1)] ? [self.ghost] : []
                }
                return p
            },
            store: DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!),
            schedule: { delay, work in delays(delay); work() })
    }

    private func written() throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted().compactMap {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent($0))) as? [String: Any]
        }
    }

    func testAMismatchThatWentAwayOnTheSecondReadingIsNotReported() throws {
        var delays: [TimeInterval] = []
        let reply = run(settling(readings: [true, false]) { delays.append($0) })
        XCTAssertEqual(delays, [0.3], "one more reading, about 0.3 s later")
        XCTAssertEqual(reply["anomalies"] as? [String], [])
        let files = try written()
        XCTAssertEqual(files.count, 1, "one snapshot is written, after the second reading")
        XCTAssertEqual(files.first?["anomalies"] as? [String], [])
    }

    func testAMismatchThatHoldsIsReportedAfterTheSecondReading() throws {
        var delays: [TimeInterval] = []
        let reply = run(settling(readings: [true, true]) { delays.append($0) })
        XCTAssertEqual(delays, [0.3])
        XCTAssertEqual((reply["anomalies"] as? [String])?.count, 1)
        XCTAssertTrue((reply["anomalies"] as? [String])?.first?.contains("(ghost)") == true)
        XCTAssertEqual(try written().count, 1)
    }

    func testWithoutAMismatchTheReplyDoesNotWait() {
        var delays: [TimeInterval] = []
        let reply = run(settling(readings: [false]) { delays.append($0) })
        XCTAssertEqual(delays, [])
        XCTAssertEqual(reply["anomalies"] as? [String], [])
    }

    func testTheSecondReadingWaitsOnTheRealSchedulerToo() {
        // The default scheduler: the mismatch is read again after the settle delay, not at once.
        var reading = 0
        let service = DiagnoseService(
            sources: Self.quietVoice,
            providers: { [unowned self] replies in
                var p = self.snapshotProviders(replies)
                p.appKitWindows = { reading += 1; return reading == 1 ? [self.ghost] : [] }
                return p
            },
            store: DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!), settle: 0.05)
        let started = Date()
        let reply = run(service)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.05)
        XCTAssertEqual(reply["anomalies"] as? [String], [])
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

    // MARK: - Which processes are the family

    func testARunningFamilyAppOutsideDiscoveryIsStillListed() {
        let discovered = [DiagnoseSnapshot.FamilyProcess(role: .sibling, name: "Scratch", bundleID: "xyz.machud.scratch", pid: 310,
                                                         showsHoverPanel: true)]
        let running: [DiagnoseLive.RunningApp] = [
            .init(bundleID: "xyz.machud.scratch", name: "Scratch (again)", pid: 310),
            .init(bundleID: "xyz.machud.widgethud", name: "widgetHUD", pid: 300),
            .init(bundleID: "com.apple.Safari", name: "Safari", pid: 400),
            .init(bundleID: "com.jrisberg.machud", name: "MacHUD", pid: 100),
            .init(bundleID: nil, name: "Unbundled", pid: 500),
            .init(bundleID: "xyz.machud.stash", name: "Stash", pid: 200),
        ]
        let family = DiagnoseLive.familyProcesses(ownPID: 100, ownBundleID: "com.jrisberg.machud", voicePID: 200,
                                                  discovered: discovered, running: running)
        XCTAssertEqual(family.map(\.pid), [100, 200, 310, 300], "MacHUD, its voice helper, discovery, then the rest of xyz.machud.*")
        XCTAssertEqual(family.map(\.role), [.machud, .voiceHost, .sibling, .sibling])
        XCTAssertEqual(family[2].name, "Scratch", "discovery's own record wins")
        XCTAssertTrue(family[2].showsHoverPanel)
        XCTAssertEqual(family[3].name, "widgetHUD")
        XCTAssertEqual(family[3].bundleID, "xyz.machud.widgethud")
        XCTAssertFalse(family[3].showsHoverPanel, "nothing is known about its panels")
    }

    func testTheVoiceHelperIsOmittedWhileItIsNotRunning() {
        let family = DiagnoseLive.familyProcesses(ownPID: 100, ownBundleID: nil, voicePID: nil, discovered: [], running: [])
        XCTAssertEqual(family.map(\.role), [.machud])
    }
}
