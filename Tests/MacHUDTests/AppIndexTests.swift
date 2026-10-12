import SQLite3
import XCTest
@testable import MacHUDCore

/// The search bar's app index (folders and Spotlight's app bundles), its launch counts and
/// the one-time seed from Alfred's launch history.
final class AppIndexTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FakeBundles.tempDir("apps")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeApp(_ relative: String) {
        let url = dir.appendingPathComponent(relative, isDirectory: true).appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: Scanning

    func testScanFindsAppsInSubfoldersButNotInsideBundles() {
        makeApp("Safari.app")
        makeApp("Utilities/Terminal.app")
        makeApp("Chrome Apps/Deep/Docs.app")
        makeApp("Xcode.app/Contents/Helpers/Inner.app")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Not an app"), withIntermediateDirectories: true)
        let names = AppIndex.scan(roots: [dir]).map(\.fileName).sorted()
        XCTAssertEqual(names, ["Docs", "Safari", "Terminal", "Xcode"])
    }

    func testScanSkipsMissingRootsAndDuplicates() {
        makeApp("Safari.app")
        let entries = AppIndex.scan(roots: [dir, dir, dir.appendingPathComponent("missing")])
        XCTAssertEqual(entries.count, 1)
    }

    func testDataVolumePathsAreTheSameApp() {
        XCTAssertEqual(AppIndex.normalize("/System/Volumes/Data/Applications/Claude.app"), "/Applications/Claude.app")
        XCTAssertEqual(AppIndex.normalize("/Applications/Claude.app/"), "/Applications/Claude.app")
        XCTAssertEqual(AppIndex.normalize("/System/Applications/Notes.app"), "/System/Applications/Notes.app")
    }

    func testSpotlightAppsAreTheOnesInTheAppFoldersOrYourHome() {
        func keeps(_ path: String) -> Bool { AppIndex.includesSpotlightApp(path, home: "/Users/u") }
        XCTAssertTrue(keeps("/Users/u/dev/machud/build/MacHUD.app"))
        XCTAssertTrue(keeps("/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"))
        XCTAssertTrue(keeps("/Applications/Utilities/Some Tool.app"))
        XCTAssertFalse(keeps("/Applications/Foo.app/Contents/Helpers/Foo Helper.app"), "inside another app")
        XCTAssertFalse(keeps("/Users/u/.Trash/Old.app"))
        XCTAssertFalse(keeps("/Users/u/Library/Application Support/Foo/Updater.app"))
        XCTAssertFalse(keeps("/Library/Application Support/Script Editor/Templates/Droplets/Droplet.app"))
        XCTAssertFalse(keeps("/System/Library/PrivateFrameworks/SoftwareUpdate.framework/Versions/A/Resources/Manager.app"))
        XCTAssertFalse(keeps("/Users/u/dev/shill/node_modules/node-notifier/vendor/terminal-notifier.app"), "a package's")
        XCTAssertFalse(keeps("/Users/u/.cache/tool/Thing.app"))
        XCTAssertFalse(keeps("/Users/u/Downloads/notes.txt"))
    }

    func testMergeKeepsFolderEntriesAndAddsSpotlightOnes() {
        let folder = [AppEntry(path: "/Applications/Safari.app", name: "Safari", fileName: "Safari")]
        let spotlight = [AppEntry(path: "/Applications/Safari.app", name: "Safari", fileName: "Safari"),
                         AppEntry(path: "/Users/u/dev/x/build/X.app", name: "X", fileName: "X")]
        XCTAssertEqual(AppIndex.merge(folder, spotlight).map(\.path), ["/Applications/Safari.app", "/Users/u/dev/x/build/X.app"])
    }

    // MARK: Launch counts

    // Made-up apps: a real one's path may resolve elsewhere (Safari's leads into a cryptex).
    @MainActor
    func testCountsPersist() {
        let url = dir.appendingPathComponent("state/launches.json")
        let counts = LaunchCounts(url: url)
        counts.record("/Applications/Fake Browser.app")
        counts.record("/System/Volumes/Data/Applications/Fake Browser.app")
        XCTAssertEqual(LaunchCounts(url: url).counts, ["/Applications/Fake Browser.app": 2])
    }

    @MainActor
    func testAlfredSeedsOnceAndAddsToCounts() {
        let url = dir.appendingPathComponent("state/launches.json")
        let counts = LaunchCounts(url: url)
        counts.record("/Applications/Fake Browser.app")
        XCTAssertTrue(counts.seed(fromAlfred: ["/Applications/Fake Browser.app": 4, "/Applications/Fake Chat.app": 2]))
        XCTAssertFalse(counts.seed(fromAlfred: ["/Applications/Fake Chat.app": 50]), "seeded once")
        let reloaded = LaunchCounts(url: url)
        XCTAssertEqual(reloaded.counts, ["/Applications/Fake Browser.app": 5, "/Applications/Fake Chat.app": 2])
        XCTAssertTrue(reloaded.alfredSeeded)
    }

    @MainActor
    func testNoAlfredLeavesItUnseeded() {
        let counts = LaunchCounts(url: dir.appendingPathComponent("state/launches.json"))
        XCTAssertFalse(counts.seed(fromAlfred: nil))
        XCTAssertFalse(counts.alfredSeeded)
    }

    // MARK: Alfred's history

    /// A stand-in for Alfred's knowledge.alfdb with the table Alfred keeps.
    private func makeAlfredDB(_ rows: [String]) throws -> URL {
        let url = dir.appendingPathComponent("knowledge.alfdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE knowledge(item, keyword, ts decimal, hidden integer);", nil, nil, nil), SQLITE_OK)
        for item in rows {
            let sql = "INSERT INTO knowledge VALUES ('\(item.replacingOccurrences(of: "'", with: "''"))', NULL, 810780498, 0);"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    func testAlfredHistoryCountsLaunchesPerApp() throws {
        let url = try makeAlfredDB([
            "features.filecache./System/Applications/Fake Messages.app",
            "features.filecache./System/Applications/Fake Messages.app",
            "features.filecache./System/Volumes/Data/Applications/Fake Claude.app",
            "features.filecache./Users/u/Documents/notes.txt",
            "features.websearch.google",
        ])
        let before = try Data(contentsOf: url)
        XCTAssertEqual(AlfredHistory.launchCounts(at: url),
                       ["/System/Applications/Fake Messages.app": 2, "/Applications/Fake Claude.app": 1])
        XCTAssertEqual(try Data(contentsOf: url), before, "Alfred's database is only read")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["knowledge.alfdb"],
                       "nothing is written beside it")
    }

    func testNoAlfredDatabase() {
        XCTAssertNil(AlfredHistory.launchCounts(at: dir.appendingPathComponent("knowledge.alfdb")))
        try? Data("not sqlite".utf8).write(to: dir.appendingPathComponent("knowledge.alfdb"))
        XCTAssertNil(AlfredHistory.launchCounts(at: dir.appendingPathComponent("knowledge.alfdb")))
    }

    /// Rows enough to fill several pages, so a damaged last page is met while stepping.
    private func bigAlfredDB() throws -> URL {
        try makeAlfredDB((0..<2000).map { "features.filecache./Applications/App \($0) \(String(repeating: "x", count: 80)).app" })
    }

    func testADatabaseThatFailsPartWayIsNoHistory() throws {
        let url = try bigAlfredDB()
        XCTAssertEqual(AlfredHistory.launchCounts(at: url)?.count, 2000)
        // Damage the last page: the header and schema still read, the rows do not.
        let handle = try FileHandle(forUpdating: url)
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size - 4096)
        handle.write(Data(repeating: 0xFF, count: 4096))
        try handle.close()
        XCTAssertNil(AlfredHistory.launchCounts(at: url), "a read that stops early is not a count of zero")
    }

    func testReadsWhatAlfredHasNotCheckpointedYet() throws {
        // Alfred still has the database open in WAL mode with rows only in the journal.
        let url = dir.appendingPathComponent("knowledge.alfdb")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in ["PRAGMA journal_mode=WAL;", "PRAGMA wal_autocheckpoint=0;",
                    "CREATE TABLE knowledge(item, keyword, ts decimal, hidden integer);",
                    "INSERT INTO knowledge VALUES ('features.filecache./Applications/Fake Notes.app', NULL, 1, 0);",
                    "INSERT INTO knowledge VALUES ('features.filecache./Applications/Fake Notes.app', NULL, 2, 0);"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertEqual(AlfredHistory.launchCounts(at: url), ["/Applications/Fake Notes.app": 2])
    }

    func testWhichAlfredHistoryIsRead() {
        XCTAssertEqual(SearchServices.alfredDatabase(environment: [:]), AlfredHistory.defaultURL)
        XCTAssertNil(SearchServices.alfredDatabase(environment: ["MACHUD_CONFIG": "/tmp/t/layouts.json"]),
                     "an isolated instance reads no Alfred history")
        XCTAssertEqual(SearchServices.alfredDatabase(environment: ["MACHUD_SOCKET": "/tmp/t.sock", "MACHUD_ALFRED_DB": "/tmp/k.alfdb"]),
                       URL(fileURLWithPath: "/tmp/k.alfdb"))
    }

    // MARK: Spotlight that never finishes

    @MainActor
    final class SilentFinder: AppBundleFinding {
        var finds = 0
        var cancelled = 0
        final class Find: SearchCancellable {
            let onCancel: () -> Void
            init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
            func cancel() { onCancel() }
        }
        func find(_ done: @escaping ([String]) -> Void) -> SearchCancellable {
            finds += 1
            return Find { [weak self] in self?.cancelled += 1 }
        }
    }

    @MainActor
    func testASpotlightGatherThatNeverEndsStillFinishes() {
        makeApp("Safari.app")
        let finder = SilentFinder()
        let index = AppIndex(roots: [dir], spotlight: finder)
        index.spotlightTimeout = 0.2
        index.maxAge = 0
        index.refreshIfStale()
        XCTAssertTrue(spin { !index.isBuilding }, "gives up on Spotlight")
        XCTAssertEqual(index.apps.map(\.fileName), ["Safari"], "the folders' apps are kept")
        XCTAssertEqual(finder.cancelled, 1, "the query is stopped")
        index.refreshIfStale()
        XCTAssertTrue(spin { finder.finds == 2 }, "a later show refreshes again")
    }
}
