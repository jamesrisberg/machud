import XCTest
@testable import MacHUDCore

/// Where `diagnose` writes its snapshots, what they are called and how many are kept.
final class DiagnoseStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnose-store-\(getpid())-\(Int.random(in: 0..<100_000))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC

    // MARK: - Where

    func testTheDefaultFolderIsTheUsersMacHUDLogs() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(DiagnoseStore.directory(environment: [:], home: home).path, "/Users/me/Library/Logs/MacHUD")
    }

    func testAnIsolatedInstanceKeepsItsSnapshotsBesideItsConfig() {
        let home = URL(fileURLWithPath: "/Users/me")
        let env = ["MACHUD_CONFIG": "/tmp/try/layouts.json", "MACHUD_SOCKET": "/tmp/try.sock"]
        XCTAssertEqual(DiagnoseStore.directory(environment: env, home: home).path, "/tmp/try/diagnostics", "the config wins")
        XCTAssertEqual(DiagnoseStore.directory(environment: ["MACHUD_CONFIG": "~/try/layouts.json"], home: home).path,
                       NSString(string: "~/try").expandingTildeInPath + "/diagnostics")
    }

    func testAnInstanceWithOnlyASocketKeepsThemBesideTheSocketNotInTheRealLogs() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(DiagnoseStore.directory(environment: ["MACHUD_SOCKET": "/tmp/try.sock"], home: home).path,
                       "/tmp/try-diagnostics")
    }

    // MARK: - What

    func testTheFileNameIsTheLocalTime() throws {
        XCTAssertEqual(DiagnoseStore.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!), "diagnose-20260921-141320.json")
        XCTAssertEqual(DiagnoseStore.fileName(for: date, timeZone: TimeZone(secondsFromGMT: 2 * 3600)!), "diagnose-20260921-161320.json")
    }

    func testWritingCreatesTheFolderAndAPrivateJSONFile() throws {
        let folder = root.appendingPathComponent("a/b")
        let store = DiagnoseStore(directory: folder, timeZone: TimeZone(identifier: "UTC")!)
        let url = try store.write(["anomalies": ["x"], "n": 1], at: date)
        XCTAssertEqual(url.lastPathComponent, "diagnose-20260921-141320.json")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["anomalies"] as? [String], ["x"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "the snapshot names the user's apps and widgets: owner only")
    }

    func testASecondSnapshotInTheSameSecondDoesNotReplaceTheFirst() throws {
        let store = DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!)
        let first = try store.write(["n": 1], at: date)
        let second = try store.write(["n": 2], at: date)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "diagnose-20260921-141320-2.json")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])?["n"] as? Int, 1)
    }

    // MARK: - How many

    func testTheNewestTwentyAreKept() throws {
        let store = DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!)
        for i in 0..<25 {
            let url = root.appendingPathComponent(String(format: "diagnose-20260901-0000%02d.json", i))
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 60)],
                                                  ofItemAtPath: url.path)
        }
        let unrelated = root.appendingPathComponent("orbwatch.log")
        try Data("keep me".utf8).write(to: unrelated)
        let notes = root.appendingPathComponent("diagnose-notes.txt")
        try Data("keep me too".utf8).write(to: notes)

        let written = try store.write([:], at: date)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("diagnose-") && $0.hasSuffix(".json") }
        XCTAssertEqual(kept.count, DiagnoseStore.keep)
        XCTAssertEqual(DiagnoseStore.keep, 20)
        XCTAssertTrue(kept.contains(written.lastPathComponent), "the new one is among the newest")
        XCTAssertFalse(kept.contains("diagnose-20260901-000000.json"), "the oldest went")
        XCTAssertTrue(kept.contains("diagnose-20260901-000024.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "only diagnose-*.json files are ever removed")
    }

    func testWhichFilesToRemoveGoesByAgeThenName() {
        let names = (1...5).map { "diagnose-\($0).json" }
        let ages: [String: Date] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, Date(timeIntervalSince1970: Double($0))) })
        XCTAssertEqual(DiagnoseStore.surplus(names, modified: { ages[$0]! }, keep: 3), ["diagnose-1.json", "diagnose-2.json"])
        XCTAssertEqual(DiagnoseStore.surplus(names, modified: { ages[$0]! }, keep: 10), [])
        let same = DiagnoseStore.surplus(["b.json", "a.json", "c.json"], modified: { _ in Date(timeIntervalSince1970: 5) }, keep: 1)
        XCTAssertEqual(same, ["a.json", "b.json"], "ties go by name")
    }

    // MARK: - Failure

    func testAFolderThatCannotBeMadeThrows() throws {
        let file = root.appendingPathComponent("not-a-folder")
        try Data().write(to: file)
        let store = DiagnoseStore(directory: file.appendingPathComponent("inside"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertThrowsError(try store.write([:], at: date))
    }
}
