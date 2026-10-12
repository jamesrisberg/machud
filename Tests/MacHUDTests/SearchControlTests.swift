import XCTest
@testable import MacHUDCore

@MainActor
final class FakeAppSource: AppSource {
    var apps: [AppEntry]
    var refreshes = 0
    init(_ apps: [AppEntry]) { self.apps = apps }
    func refreshIfStale() { refreshes += 1 }
}

@MainActor
final class FakeSnippetSource: SnippetSource {
    var hits: [SnippetHit]
    var queries: [String] = []
    var inserted: [String] = []
    var insertReply: [String: Any] = ["ok": true, "pasted": true]
    init(_ hits: [SnippetHit] = []) { self.hits = hits }
    func list(query: String, limit: Int, completion: @escaping ([SnippetHit]) -> Void) {
        queries.append(query)
        // Stash filters by name, keyword and text.
        let q = query.lowercased()
        let hits = hits.filter { hit in [hit.name, hit.keyword, hit.preview].contains { $0.lowercased().contains(q) } }
        DispatchQueue.main.async { completion(Array(hits.prefix(limit))) }
    }
    func insert(id: String, completion: @escaping ([String: Any]) -> Void) {
        inserted.append(id)
        completion(insertReply)
    }
}

@MainActor
final class FakeFileSearch: FileSearching {
    /// nil: never answers (a Spotlight query that does not finish).
    var hits: [FileHit]?
    var queries: [String] = []
    var cancelled = 0
    init(_ hits: [FileHit]?) { self.hits = hits }

    final class Task: SearchCancellable {
        var onCancel: () -> Void = {}
        func cancel() { onCancel() }
    }

    func search(_ query: String, limit: Int, completion: @escaping ([FileHit]) -> Void) -> SearchCancellable {
        queries.append(query)
        let task = Task()
        task.onCancel = { [weak self] in self?.cancelled += 1 }
        if let hits { DispatchQueue.main.async { completion(Array(hits.prefix(limit))) } }
        return task
    }
}

@MainActor
final class FakeSearchBar: SearchBarPresenting {
    var isVisible = false
    var query = ""
    var shown: [String?] = []
    var snapshots: [(URL, String, [SearchResult])] = []
    func show(query: String?) { isVisible = true; shown.append(query); self.query = query ?? "" }
    func hide() { isVisible = false }
    func writeSnapshot(to url: URL, query: String, results: [SearchResult]) throws { snapshots.append((url, query, results)) }
}

/// The `search` verb: show, hide, state and the ranked reply of `search query`.
@MainActor
final class SearchControlTests: XCTestCase {
    private var apps: FakeAppSource!
    private var snippets: FakeSnippetSource!
    private var files: FakeFileSearch!
    private var bar: FakeSearchBar!
    private var control: SearchControl!

    override func setUp() {
        apps = FakeAppSource([AppEntry(path: "/Applications/Safari.app", name: "Safari", fileName: "Safari"),
                              AppEntry(path: "/Applications/Slack.app", name: "Slack", fileName: "Slack"),
                              AppEntry(path: "/Applications/Safari Technology Preview.app", name: "Safari Technology Preview",
                                       fileName: "Safari Technology Preview")])
        snippets = FakeSnippetSource([SnippetHit(id: "s1", name: "Safari bookmarklet", keyword: "sbm", collection: "Default", preview: "javascript:…")])
        files = FakeFileSearch([FileHit(path: "/Users/u/safari notes.md", name: "safari notes.md")])
        bar = FakeSearchBar()
        makeControl()
    }

    private func makeControl() {
        let engine = SearchEngine(apps: apps, counts: { ["/Applications/Safari Technology Preview.app": 3] },
                                  loadouts: { ["Safari research", "Code"] }, snippets: snippets, files: files)
        control = SearchControl(engine: engine, bar: bar)
    }

    private func handle(_ args: [String: String]) -> [String: Any] {
        var reply: [String: Any]?
        control.handle(args) { reply = $0 }
        XCTAssertTrue(spin { reply != nil })
        return reply ?? [:]
    }

    func testQueryRepliesWithRankedResultsOfEveryKind() throws {
        // `machud search query text=saf` arrives as `_: query, query: 1, text: saf`.
        let reply = handle(["_": "query", "query": "1", "text": "saf"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["query"] as? String, "saf")
        let results = try XCTUnwrap(reply["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["kind"] as? String }, ["app", "app", "loadout", "snippet", "file"])
        XCTAssertEqual(results.map { $0["title"] as? String },
                       ["Safari Technology Preview", "Safari", "Safari research", "Safari bookmarklet", "safari notes.md"],
                       "launch counts lift an equal match; files come last")
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first["id"] as? String, "/Applications/Safari Technology Preview.app")
        XCTAssertEqual(first["subtitle"] as? String, "/Applications")
        XCTAssertNotNil(first["score"] as? Int)
        XCTAssertEqual(first["rank"] as? Int, 1)
        XCTAssertEqual(results.last?["rank"] as? Int, 5)
        XCTAssertEqual(snippets.queries, ["saf"])
        XCTAssertEqual(files.queries, ["saf"])
    }

    func testQueryCanLeaveFilesOut() throws {
        let reply = handle(["action": "query", "text": "saf", "files": "0"])
        let results = try XCTUnwrap(reply["results"] as? [[String: Any]])
        XCTAssertFalse(results.contains { $0["kind"] as? String == "file" })
        XCTAssertEqual(files.queries, [])
    }

    func testASlowSourceIsNotWaitedForForever() throws {
        files.hits = nil
        control.collectTimeout = 0.2
        let reply = handle(["_": "query", "query": "1", "text": "saf"])
        let results = try XCTUnwrap(reply["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 4, "everything but the files")
        XCTAssertEqual(files.cancelled, 1, "the file search is stopped")
    }

    func testQueryNeedsText() {
        let reply = handle(["_": "query", "query": "1"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertNotNil(reply["error"] as? String)
    }

    func testShowAndHideReachTheBar() {
        var reply = handle(["_": "show", "show": "1", "query": "saf"])
        XCTAssertEqual(bar.shown, ["saf"])
        XCTAssertEqual(reply["visible"] as? Bool, true)
        XCTAssertEqual(reply["query"] as? String, "saf")
        reply = handle(["_": "hide", "hide": "1"])
        XCTAssertFalse(bar.isVisible)
        XCTAssertEqual(reply["visible"] as? Bool, false)
        _ = handle(["_": "show", "show": "1"])
        XCTAssertEqual(bar.shown, ["saf", nil], "a show without query= opens an empty bar")
    }

    func testStateIsTheDefault() {
        let reply = handle([:])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["visible"] as? Bool, false)
    }

    func testSnapshotNeedsAPath() {
        XCTAssertEqual(handle(["_": "snapshot", "snapshot": "1"])["ok"] as? Bool, false)
        let reply = handle(["_": "snapshot", "snapshot": "1", "path": "/tmp/x.png", "query": "saf"])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(bar.snapshots.first?.0.path, "/tmp/x.png")
        XCTAssertEqual(bar.snapshots.first?.1, "saf")
        XCTAssertEqual(bar.snapshots.first?.2.first?.title, "Safari Technology Preview", "the bar's results for that query")
    }

    func testUnknownAction() {
        let reply = handle(["_": "launch", "launch": "1"])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertTrue((reply["error"] as? String ?? "").contains("show"))
    }
}
