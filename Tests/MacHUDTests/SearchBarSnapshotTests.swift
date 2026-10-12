import AppKit
import XCTest
@testable import MacHUDCore

/// Renders the search bar offscreen for review, at the size it opens: empty, and with a mixed
/// list (apps, a loadout, a snippet, a file). Nothing is ordered on screen. Pictures go to
/// `MACHUD_SEARCH_SNAPSHOT_DIR`; without it they are rendered and checked, and nothing is written.
@MainActor
final class SearchBarSnapshotTests: XCTestCase {
    private var directory: URL? {
        ProcessInfo.processInfo.environment["MACHUD_SEARCH_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    /// What typing "mes" might show: two apps (real bundles, for their icons), a loadout,
    /// a snippet and a file.
    static let mixed: [SearchResult] = [
        SearchResult(kind: .app, id: "/System/Applications/Messages.app", title: "Messages", subtitle: "/System/Applications", score: 1016),
        SearchResult(kind: .loadout, id: "Messaging", title: "Messaging", subtitle: "", score: 894),
        SearchResult(kind: .snippet, id: "s1", title: "Meeting notes", subtitle: "mtg · Default · ## Attendees", score: 850),
        SearchResult(kind: .app, id: "/System/Applications/Mail.app", title: "Mail", subtitle: "/System/Applications", score: 520),
        SearchResult(kind: .file, id: "/Users/me/Documents/message drafts.md", title: "message drafts.md", subtitle: "~/Documents", score: 897),
    ]

    private func shot(_ name: String, query: String, results: [SearchResult], selection: Int = 0) throws {
        let rep = try XCTUnwrap(SearchBarSnapshot.render(query: query, results: results, selection: selection))
        XCTAssertEqual(rep.size.width, SearchBarMetrics.width)
        XCTAssertEqual(rep.size.height, SearchBarMetrics.height(rows: results.count))
        guard let directory else { return }
        try SearchBarSnapshot.write(query: query, results: results, selection: selection,
                                    to: directory.appendingPathComponent("search-\(name).png"))
    }

    func testSnapshots() throws {
        try shot("empty", query: "", results: [])
        try shot("mixed", query: "mes", results: Self.mixed)
        try shot("mixed-loadout-selected", query: "mes", results: Self.mixed, selection: 1)
        try shot("mixed-file-selected", query: "mes", results: Self.mixed, selection: 4)
    }
}
