import XCTest
@testable import MacHUDCore

/// The search bar's state as you type and press keys: which results show when, where the
/// selection goes, and what a row runs (the bar hides first).
@MainActor
final class SearchModelTests: XCTestCase {
    private var apps: FakeAppSource!
    private var snippets: FakeSnippetSource!
    private var files: FakeFileSearch!
    private var model: SearchModel!
    private var events: [String] = []
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var launches: [String] = []

    override func setUp() {
        apps = FakeAppSource([AppEntry(path: "/Applications/Safari.app", name: "Safari", fileName: "Safari"),
                              AppEntry(path: "/Applications/Messages.app", name: "Messages", fileName: "Messages")])
        snippets = FakeSnippetSource([SnippetHit(id: "s1", name: "Signature", keyword: "sig", collection: "Default", preview: "Best")])
        files = FakeFileSearch([FileHit(path: "/Users/u/message log.txt", name: "message log.txt")])
        events = []
        scheduled = []
        launches = []
        let engine = SearchEngine(apps: apps, counts: { [:] }, loadouts: { ["Messaging"] }, snippets: snippets, files: files)
        model = SearchModel(engine: engine)
        model.onHide = { [unowned self] in events.append("hide") }
        model.perform = { [unowned self] action in events.append("\(action)") }
        model.recordLaunch = { [unowned self] in launches.append($0) }
        model.schedule = { [unowned self] delay, work in scheduled.append((delay, work)) }
    }

    /// Runs what was scheduled (debounced file searches, deferred actions), in order.
    private func flush() {
        while !scheduled.isEmpty { scheduled.removeFirst().work() }
    }

    private var titles: [String] { model.results.map(\.title) }

    func testAppsAndLoadoutsShowAtOnceSnippetsAndFilesFollow() {
        model.setQuery("mess")
        XCTAssertEqual(titles, ["Messages", "Messaging"], "no wait for the slower sources")
        XCTAssertTrue(spin { self.titles.count == 2 && self.snippets.queries == ["mess"] })
        XCTAssertEqual(files.queries, [], "the file search waits for typing to pause")
        flush()
        XCTAssertTrue(spin { self.titles.contains("message log.txt") })
        XCTAssertEqual(titles.last, "message log.txt")
    }

    func testSnippetsJoinTheRanking() {
        model.setQuery("sig")
        XCTAssertEqual(titles, ["Messaging"], "s-i-g in order")
        XCTAssertTrue(spin { self.titles == ["Signature", "Messaging"] }, "a typed keyword ranks first")
    }

    func testAnOldQuerysRepliesAreDropped() {
        model.setQuery("sig")
        model.setQuery("saf")
        flush()
        XCTAssertTrue(spin { self.files.queries == ["saf"] })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(titles.contains("Signature"), "the reply to `sig` arrived after `saf` was typed")
    }

    func testEmptyQueryShowsNothing() {
        model.setQuery("mess")
        model.setQuery("  ")
        flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(model.results, [])
    }

    // MARK: Selection

    func testArrowsMoveTheSelectionWithinTheList() {
        model.setQuery("mess")
        XCTAssertEqual(model.selection, 0)
        XCTAssertTrue(model.handle(.move(1)))
        XCTAssertEqual(model.selection, 1)
        model.handle(.move(1))
        XCTAssertEqual(model.selection, 1, "stays on the last row")
        model.handle(.move(-5))
        XCTAssertEqual(model.selection, 0)
    }

    func testTheTopRowStaysSelectedUntilYouMove() {
        model.setQuery("sig")
        XCTAssertEqual(model.selected?.title, "Messaging")
        XCTAssertTrue(spin { self.titles.first == "Signature" })
        XCTAssertEqual(model.selected?.title, "Signature", "the better match that arrived is the one Return runs")
    }

    func testAChosenRowStaysSelectedAsResultsArrive() {
        model.setQuery("mess")
        model.handle(.move(1))
        XCTAssertEqual(model.selected?.title, "Messaging")
        flush()
        XCTAssertTrue(spin { self.titles.count == 3 })
        XCTAssertEqual(model.selected?.title, "Messaging")
    }

    // MARK: Running a row

    func testReturnRunsTheSelectedRowAfterHiding() {
        model.setQuery("mess")
        model.handle(.move(1))
        XCTAssertTrue(model.handle(.run(.option)))
        flush()
        XCTAssertEqual(events, ["hide", "\(SearchAction.loadout("Messaging", .preview))"])
    }

    func testCommandDigitRunsThatRow() {
        model.setQuery("mess")
        model.handle(.runRow(1))
        flush()
        XCTAssertEqual(events.last, "\(SearchAction.loadout("Messaging", .apply))")
        events = []
        model.handle(.runRow(8))
        flush()
        XCTAssertEqual(events, [], "no ninth row")
    }

    func testLaunchingAnAppCountsIt() {
        model.setQuery("saf")
        model.handle(.run(.plain))
        flush()
        XCTAssertEqual(launches, ["/Applications/Safari.app"])
        XCTAssertEqual(events, ["hide", "\(SearchAction.launch("/Applications/Safari.app"))"])
        events = []
        launches = []
        model.setQuery("saf")
        model.handle(.run(.command))
        flush()
        XCTAssertEqual(launches, [], "revealing is not launching")
    }

    func testASnippetIsInsertedAfterTheBarHides() throws {
        model.setQuery("sig")
        XCTAssertTrue(spin { self.titles.first == "Signature" })
        scheduled = []
        model.handle(.run(.plain))
        XCTAssertEqual(events, ["hide"], "the bar is gone before anything is pasted")
        let deferred = try XCTUnwrap(scheduled.last)
        XCTAssertEqual(deferred.delay, 0, "Stash waits for the keyboard to come back; MacHUD adds no wait")
        flush()
        XCTAssertEqual(events, ["hide", "\(SearchAction.insertSnippet("s1"))"])
    }

    func testEscapeHides() {
        XCTAssertTrue(model.handle(.close))
        XCTAssertEqual(events, ["hide"])
    }

    func testReturnWithNothingDoesNothing() {
        XCTAssertTrue(model.handle(.run(.plain)), "the key is still the bar's")
        flush()
        XCTAssertEqual(events, [])
    }
}
