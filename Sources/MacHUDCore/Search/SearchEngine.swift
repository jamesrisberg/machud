import Foundation

/// The bar's sources behind one interface: apps and loadouts answer at once, snippets (Stash)
/// and files (Spotlight) a moment later.
@MainActor
final class SearchEngine {
    let apps: AppSource
    private let counts: () -> [String: Int]
    private let loadouts: () -> [String]
    let snippets: SnippetSource?
    let files: FileSearching?

    static let snippetLimit = 8
    /// Files asked of Spotlight; the best `SearchRanking.maxFiles` by name are shown.
    static let fileLimit = 20
    /// One letter would match most of the disk.
    static let minFileQuery = 2

    init(apps: AppSource, counts: @escaping () -> [String: Int], loadouts: @escaping () -> [String],
         snippets: SnippetSource?, files: FileSearching?) {
        self.apps = apps
        self.counts = counts
        self.loadouts = loadouts
        self.snippets = snippets
        self.files = files
    }

    static func isEmpty(_ query: String) -> Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Apps and loadouts matching `query`, scored.
    func immediate(_ query: String) -> [SearchResult] {
        guard !Self.isEmpty(query) else { return [] }
        return SearchRanking.apps(apps.apps, query: query, counts: counts()) + SearchRanking.loadouts(loadouts(), query: query)
    }

    /// Stash's snippets for `query`; none without Stash.
    func listSnippets(_ query: String, done: @escaping ([SnippetHit]) -> Void) {
        guard let snippets, !Self.isEmpty(query) else { done([]); return }
        snippets.list(query: query, limit: Self.snippetLimit, completion: done)
    }

    /// Spotlight's files for `query`; nil (and no call back) when the query is too short.
    func searchFiles(_ query: String, done: @escaping ([FileHit]) -> Void) -> SearchCancellable? {
        guard let files, query.trimmingCharacters(in: .whitespaces).count >= Self.minFileQuery else { return nil }
        return files.search(query, limit: Self.fileLimit, completion: done)
    }

    /// Every source's results for `query`, ranked as the bar shows them, once all have answered
    /// or `timeout` has passed (a source still out by then is left out). For `search query`.
    func collect(_ query: String, files includeFiles: Bool = true, timeout: TimeInterval,
                 done: @escaping ([SearchResult]) -> Void) {
        let ranked = immediate(query)
        var snippetHits: [SnippetHit]?
        var fileHits: [FileHit]?
        var fileTask: SearchCancellable?
        var finished = false
        var timer: Timer?
        func finish() {
            guard !finished else { return }
            finished = true
            timer?.invalidate()
            fileTask?.cancel()
            done(SearchRanking.merge(ranked + SearchRanking.snippets(snippetHits ?? [], query: query),
                                     files: SearchRanking.files(fileHits ?? [], query: query)))
        }
        func check() {
            if snippetHits != nil && (fileHits != nil || fileTask == nil) { finish() }
        }
        if includeFiles {
            fileTask = searchFiles(query) { hits in
                fileHits = hits
                fileTask = nil
                check()
            }
        }
        listSnippets(query) { hits in
            snippetHits = hits
            check()
        }
        guard !finished else { return }
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated { finish() }
        }
    }
}
