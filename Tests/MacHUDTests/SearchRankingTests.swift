import XCTest
@testable import MacHUDCore

/// The search bar's matching and ranking: how well a query matches a name, how launch counts
/// lift an app, and how the kinds merge into one list with files below.
final class SearchRankingTests: XCTestCase {
    private func score(_ query: String, _ name: String) -> Int? { FuzzyMatch.score(query, name) }

    // MARK: Match quality

    func testMatchTiersAreOrdered() throws {
        let exact = try XCTUnwrap(score("safari", "Safari"))
        let prefix = try XCTUnwrap(score("saf", "Safari"))
        let word = try XCTUnwrap(score("code", "Visual Studio Code"))
        let initials = try XCTUnwrap(score("vsc", "Visual Studio Code"))
        let substring = try XCTUnwrap(score("fari", "Safari"))
        let subsequence = try XCTUnwrap(score("sfr", "Safari"))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, initials)
        XCTAssertGreaterThan(initials, substring)
        XCTAssertGreaterThan(substring, subsequence)
    }

    func testLettersSpreadFarApartDoNotMatch() {
        XCTAssertNil(score("saf", "SoftwareUpdateNotificationManager"))
        XCTAssertNotNil(score("sfr", "Safari"))
        XCTAssertNotNil(score("vscode", "Visual Studio Code"))
    }

    func testNoMatch() {
        XCTAssertNil(score("xyz", "Safari"))
        XCTAssertNil(score("", "Safari"))
        XCTAssertNil(score("   ", "Safari"))
        XCTAssertNil(score("safarix", "Safari"))
    }

    func testIgnoresCaseAndDiacritics() {
        XCTAssertNotNil(score("CAFE", "Café Notes"))
        XCTAssertEqual(score("café", "cafe"), score("cafe", "cafe"))
    }

    func testCamelCaseCountsAsWords() throws {
        let camel = try XCTUnwrap(score("hud", "MacHUD"))
        let word = try XCTUnwrap(score("time", "Face Time"))
        XCTAssertEqual(camel, try XCTUnwrap(score("time", "FaceTime")))
        XCTAssertEqual(camel, word, "a camel-case word starts like a spaced one")
    }

    func testEveryWordOfAQueryMustMatch() {
        XCTAssertNotNil(score("vis code", "Visual Studio Code"))
        XCTAssertNil(score("vis xyz", "Visual Studio Code"))
    }

    func testShorterNameWinsTheSamePrefix() throws {
        XCTAssertGreaterThan(try XCTUnwrap(score("note", "Notes")), try XCTUnwrap(score("note", "Notes Archive Tool")))
    }

    // MARK: Apps and launch counts

    private func app(_ name: String, _ path: String? = nil) -> AppEntry {
        AppEntry(path: path ?? "/Applications/\(name).app", name: name, fileName: name)
    }

    func testLaunchCountsOrderEqualMatches() {
        let apps = [app("Terminal"), app("Telegram")]
        let ranked = SearchRanking.apps(apps, query: "te", counts: ["/Applications/Telegram.app": 10])
        XCTAssertEqual(ranked.map(\.title), ["Telegram", "Terminal"])
    }

    func testAStrongMatchBeatsAFrequentWeakOne() {
        let apps = [app("Notion Sketch Studio"), app("Notes")]
        let ranked = SearchRanking.apps(apps, query: "notes", counts: ["/Applications/Notion Sketch Studio.app": 3])
        XCTAssertEqual(ranked.first?.title, "Notes")
    }

    func testAnExactNameBeatsAPartOfNameMatchHoweverOftenLaunched() {
        // Alfred-scale counts: a part-of-name match launched 120 times, an exact one never.
        let apps = [app("Notes Archive"), app("Notes")]
        let ranked = SearchRanking.apps(apps, query: "notes", counts: ["/Applications/Notes Archive.app": 120])
        XCTAssertEqual(ranked.map(\.title), ["Notes", "Notes Archive"])
    }

    func testTheLaunchBoostStaysBelowTheGapBetweenTiers() {
        XCTAssertLessThan(SearchRanking.launchBoost(1_000_000), FuzzyMatch.tierGap)
        XCTAssertEqual(SearchRanking.launchBoost(0), 0)
        XCTAssertLessThan(SearchRanking.launchBoost(3), SearchRanking.launchBoost(10))
        XCTAssertLessThan(SearchRanking.launchBoost(60), SearchRanking.launchBoost(120), "frequency keeps ordering at Alfred's counts")
    }

    func testFrequencyNudgesOnlyBetweenAdjacentTiers() throws {
        let wordStart = try XCTUnwrap(score("code", "Studio Code"))
        let prefixOfLongName = try XCTUnwrap(score("code", "Code Signing Certificate Helper"))
        XCTAssertGreaterThan(wordStart + SearchRanking.launchBoost(120), prefixOfLongName,
                             "a much-launched app passes a weaker match in the next tier up")
        XCTAssertLessThan(wordStart + SearchRanking.launchBoost(1_000_000), try XCTUnwrap(score("code", "Code")),
                          "never one two tiers up")
    }

    func testAppMatchesItsFileNameToo() {
        // The display name can differ from the bundle's file name.
        let apps = [AppEntry(path: "/Applications/Visual Studio Code.app", name: "Code", fileName: "Visual Studio Code")]
        XCTAssertEqual(SearchRanking.apps(apps, query: "visual", counts: [:]).map(\.title), ["Code"])
    }

    func testCopiesSpotlightFoundShowOnceTheMostLaunched() {
        let apps = [AppEntry(path: "/Applications/MacHUD.app", name: "MacHUD", fileName: "MacHUD"),
                    AppEntry(path: "/Users/u/dev/a/build/MacHUD.app", name: "MacHUD", fileName: "MacHUD", foundBySpotlight: true),
                    AppEntry(path: "/Users/u/dev/b/build/MacHUD.app", name: "MacHUD", fileName: "MacHUD", foundBySpotlight: true)]
        let ranked = SearchRanking.apps(apps, query: "machud", counts: ["/Users/u/dev/b/build/MacHUD.app": 4])
        XCTAssertEqual(ranked.map(\.id), ["/Users/u/dev/b/build/MacHUD.app", "/Applications/MacHUD.app"],
                       "the installed app stays; of the build copies, the one you launch")
    }

    func testAppResultCarriesPathAndFolder() throws {
        let r = try XCTUnwrap(SearchRanking.apps([app("Safari")], query: "saf", counts: [:]).first)
        XCTAssertEqual(r.kind, .app)
        XCTAssertEqual(r.id, "/Applications/Safari.app")
        XCTAssertEqual(r.subtitle, "/Applications")
    }

    // MARK: Loadouts and snippets

    func testLoadoutsMatchByName() {
        let ranked = SearchRanking.loadouts(["Messaging", "Code", "Reading"], query: "mess")
        XCTAssertEqual(ranked.map(\.title), ["Messaging"])
        XCTAssertEqual(ranked.first?.kind, .loadout)
        XCTAssertEqual(ranked.first?.id, "Messaging")
    }

    func testSnippetKeywordExactlyTypedRanksFirst() {
        let hits = [SnippetHit(id: "1", name: "Signature", keyword: "sig", collection: "Default", preview: "Best, J"),
                    SnippetHit(id: "2", name: "Sigma notes", keyword: "sgn", collection: "pkm", preview: "…")]
        let ranked = SearchRanking.snippets(hits, query: "sig")
        XCTAssertEqual(ranked.map(\.id), ["1", "2"])
        XCTAssertEqual(ranked.first?.kind, .snippet)
    }

    func testSnippetStashMatchedByContentStillShows() {
        // Stash may match on text the bar does not see; keep it, below the named matches.
        let hits = [SnippetHit(id: "9", name: "Address", keyword: "addr", collection: "Default", preview: "1 Infinite Loop")]
        XCTAssertEqual(SearchRanking.snippets(hits, query: "loop").map(\.id), ["9"])
    }

    // MARK: Merging

    private func result(_ kind: SearchKind, _ title: String, _ score: Int) -> SearchResult {
        SearchResult(kind: kind, id: title, title: title, subtitle: "", score: score)
    }

    func testMergeRanksKindsTogetherAndPutsFilesBelow() {
        let merged = SearchRanking.merge([result(.app, "Slack", 700), result(.loadout, "Messaging", 900),
                                          result(.snippet, "sig", 800)],
                                         files: [result(.file, "Messaging notes.md", 1000)])
        XCTAssertEqual(merged.map(\.title), ["Messaging", "sig", "Slack", "Messaging notes.md"])
    }

    func testTiesPreferAppsThenLoadoutsThenSnippets() {
        let merged = SearchRanking.merge([result(.snippet, "c", 500), result(.loadout, "b", 500), result(.app, "a", 500)], files: [])
        XCTAssertEqual(merged.map(\.kind), [.app, .loadout, .snippet])
    }

    func testMergeCapsEachPart() {
        let many = (0..<20).map { result(.app, "App \($0)", 500 - $0) }
        let files = (0..<20).map { result(.file, "File \($0)", 500) }
        let merged = SearchRanking.merge(many, files: files)
        XCTAssertEqual(merged.filter { $0.kind == .app }.count, SearchRanking.maxRanked)
        XCTAssertEqual(merged.filter { $0.kind == .file }.count, SearchRanking.maxFiles)
        XCTAssertEqual(merged.first?.title, "App 0")
    }

    func testFilesYouHaveOpenedComeFirst() {
        let opened = Date(timeIntervalSince1970: 1_800_000_000)
        let files = SearchRanking.files([FileHit(path: "/Users/u/dev/x/SafeFont.class", name: "SafeFont.class"),
                                         FileHit(path: "/Users/u/Docs/unsafe ideas.md", name: "unsafe ideas.md", lastUsed: opened)],
                                        query: "safe", home: "/Users/u")
        XCTAssertEqual(files.map(\.title), ["unsafe ideas.md", "SafeFont.class"])
    }

    func testSpotlightFilesLeaveOutLibraryHiddenAndPackageFolders() {
        func keeps(_ path: String) -> Bool { SpotlightFileSearch.keeps(path, home: "/Users/u") }
        XCTAssertTrue(keeps("/Users/u/Documents/plan.md"))
        XCTAssertFalse(keeps("/Users/u/Library/Mail/V10/1.emlx"))
        XCTAssertFalse(keeps("/Users/u/.config/machud/layouts.json"))
        XCTAssertFalse(keeps("/Users/u/dev/app/node_modules/es-abstract/helpers/maxSafeInteger.js"))
    }

    func testFilesThatDoNotMatchTheQueryAreDropped() {
        // Spotlight's own matching is looser than the bar's.
        let files = SearchRanking.files([FileHit(path: "/Users/u/unread-markers.js", name: "unread-markers.js", lastUsed: Date())],
                                        query: "term", home: "/Users/u")
        XCTAssertEqual(files, [])
    }

    func testFilesKeepTheirMatchOrder() {
        let files = SearchRanking.files([FileHit(path: "/Users/u/Docs/old plan.txt", name: "old plan.txt"),
                                         FileHit(path: "/Users/u/plan.txt", name: "plan.txt")], query: "plan", home: "/Users/u")
        XCTAssertEqual(files.map(\.title), ["plan.txt", "old plan.txt"])
        XCTAssertEqual(files.last?.subtitle, "~/Docs")
        XCTAssertEqual(files.first?.kind, .file)
    }
}
