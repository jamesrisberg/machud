import Foundation

/// What a search bar row is.
enum SearchKind: String, CaseIterable {
    case app, loadout, snippet, file

    /// The row's caption.
    var label: String {
        switch self {
        case .app: "Application"
        case .loadout: "Loadout"
        case .snippet: "Snippet"
        case .file: "File"
        }
    }

    /// Between equal scores, apps come first, then loadouts, then snippets.
    fileprivate var tieOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One row of the search bar. `id` is what running it needs: the bundle or file path, the
/// loadout's name, or Stash's snippet id.
struct SearchResult: Equatable, Identifiable {
    var kind: SearchKind
    var id: String
    var title: String
    var subtitle: String
    var score: Int

    /// Unique across kinds (a loadout and a snippet may share a name).
    var key: String { "\(kind.rawValue):\(id)" }

    /// As `search query` reports it.
    var json: [String: Any] {
        ["kind": kind.rawValue, "id": id, "title": title, "subtitle": subtitle, "score": score]
    }
}

/// An application bundle the bar can launch. `name` is the name Finder shows; `fileName` is
/// the bundle's file name without `.app`, which may differ ("Code" is Visual Studio Code.app).
/// `countKey` is the path its launches are counted under (`AppIndex.canonical`).
/// `foundBySpotlight`: outside the app folders (a build folder's copy).
struct AppEntry: Equatable {
    var path: String
    var name: String
    var fileName: String
    var countKey: String
    var foundBySpotlight: Bool

    init(path: String, name: String, fileName: String, countKey: String? = nil, foundBySpotlight: Bool = false) {
        self.path = path
        self.name = name
        self.fileName = fileName
        self.countKey = countKey ?? path
        self.foundBySpotlight = foundBySpotlight
    }
}

/// A snippet as Stash lists it (`snippets list`).
struct SnippetHit: Equatable {
    var id: String
    var name: String
    var keyword: String
    var collection: String
    var preview: String
}

/// A file Spotlight found by name; `lastUsed` is when you last opened it, if ever.
struct FileHit: Equatable {
    var path: String
    var name: String
    var lastUsed: Date?

    init(path: String, name: String, lastUsed: Date? = nil) {
        self.path = path
        self.name = name
        self.lastUsed = lastUsed
    }
}

/// Turns each source's matches into scored rows and merges them into the bar's list: apps,
/// loadouts and snippets ranked together by score, then files below them.
enum SearchRanking {
    /// Rows above the files.
    static let maxRanked = 8
    /// File rows.
    static let maxFiles = 5

    /// How much launching an app from the bar lifts it: more with every doubling of its count
    /// but always less than `FuzzyMatch.tierGap` (31 for one launch, 73 for 120, never 95).
    /// Frequency orders apps within a match tier and can pass a weaker match in the next tier
    /// up, never one two tiers up: an exact name beats a part of a name however often launched.
    static func launchBoost(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let doublings = log2(Double(count) + 1)
        return Int(95 * doublings / (doublings + 2))
    }

    /// Best first; equal scores keep their order.
    static func ranked(_ results: [SearchResult]) -> [SearchResult] {
        results.enumerated().sorted { a, b in
            a.element.score != b.element.score ? a.element.score > b.element.score : a.offset < b.offset
        }.map(\.element)
    }

    /// Of several copies of an app outside the app folders (builds, old checkouts), only the
    /// best-ranked shows: the one you launch most, else the first found. The apps in the app
    /// folders always show.
    static func apps(_ apps: [AppEntry], query: String, counts: [String: Int],
                     home: String = NSHomeDirectory()) -> [SearchResult] {
        let copies = Set(apps.filter(\.foundBySpotlight).map(\.path))
        var shownCopies = Set<String>()
        return ranked(apps.compactMap { app -> SearchResult? in
            let match = [FuzzyMatch.score(query, app.name), FuzzyMatch.score(query, app.fileName)].compactMap { $0 }.max()
            guard let match else { return nil }
            let folder = abbreviate((app.path as NSString).deletingLastPathComponent, home: home)
            return SearchResult(kind: .app, id: app.path, title: app.name, subtitle: folder,
                                score: match + launchBoost(counts[app.countKey] ?? 0))
        }).filter { r in !copies.contains(r.id) || shownCopies.insert(r.title).inserted }
    }

    static func loadouts(_ names: [String], query: String) -> [SearchResult] {
        ranked(names.compactMap { name in
            FuzzyMatch.score(query, name).map { SearchResult(kind: .loadout, id: name, title: name, subtitle: "", score: $0) }
        })
    }

    /// Stash has already filtered by the query (it may match the snippet's text, which the bar
    /// never sees), so every hit is kept; a typed keyword ranks like an exact name.
    static func snippets(_ hits: [SnippetHit], query: String) -> [SearchResult] {
        let q = FuzzyMatch.fold(query).trimmingCharacters(in: .whitespaces)
        return ranked(hits.map { hit in
            let keyword = FuzzyMatch.fold(hit.keyword)
            let byKeyword: Int? = keyword.isEmpty ? nil : keyword == q ? FuzzyMatch.exact : keyword.hasPrefix(q) ? 850 : nil
            let score = [FuzzyMatch.score(query, hit.name), byKeyword].compactMap { $0 }.max() ?? 200
            let detail = [hit.keyword, hit.collection, hit.preview].filter { !$0.isEmpty }.joined(separator: " · ")
            return SearchResult(kind: .snippet, id: hit.id, title: hit.name.isEmpty ? hit.keyword : hit.name,
                                subtitle: detail, score: score)
        })
    }

    /// Files you have opened before the ones you never have (a build's or a package's), then
    /// the best name match; Spotlight's order (most recently used) between equals. A file whose
    /// name does not match the query (Spotlight matches more loosely) is left out.
    static func files(_ hits: [FileHit], query: String, home: String = NSHomeDirectory()) -> [SearchResult] {
        let rows = hits.compactMap { hit in
            FuzzyMatch.score(query, hit.name).map {
                SearchResult(kind: .file, id: hit.path, title: hit.name,
                             subtitle: abbreviate((hit.path as NSString).deletingLastPathComponent, home: home), score: $0)
            }
        }
        let opened = Set(hits.filter { $0.lastUsed != nil }.map(\.path))
        return ranked(rows.filter { opened.contains($0.id) }) + ranked(rows.filter { !opened.contains($0.id) })
    }

    static func merge(_ ranked: [SearchResult], files: [SearchResult]) -> [SearchResult] {
        let top = ranked.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.kind != b.kind { return a.kind.tieOrder < b.kind.tieOrder }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        return Array(top.prefix(maxRanked)) + Array(files.prefix(maxFiles))
    }

    /// `path` with the home folder written as `~`.
    static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
