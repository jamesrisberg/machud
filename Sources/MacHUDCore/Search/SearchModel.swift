import Foundation

/// The search bar's state: the query, the ranked rows and the selection, and what the keys do.
/// Apps and loadouts are ranked on every keystroke; Stash's snippets join when Stash answers,
/// and Spotlight's files once typing pauses. A reply to an older query is dropped. Until the
/// new replies come, the previous snippets and files that still match stay listed, so the
/// list does not flicker as you type.
@MainActor
final class SearchModel: ObservableObject {
    @Published private(set) var query = ""
    @Published private(set) var results: [SearchResult] = []
    @Published private(set) var selection = 0

    let engine: SearchEngine

    /// Hides the bar; called before a row runs, so the app you were in has the keyboard back.
    var onHide: () -> Void = {}
    /// Runs a row (launch, open, apply, insert).
    var perform: (SearchAction) -> Void = { _ in }
    /// Counts an app launched from the bar.
    var recordLaunch: (String) -> Void = { _ in }
    /// Runs `work` after a delay on the main thread (a test runs it by hand).
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
    }
    /// After `results` changes (the bar fits its height to them).
    var onResultsChange: () -> Void = {}

    /// How long typing must pause before Spotlight is asked.
    var fileDebounce: TimeInterval = 0.15
    /// How long after the bar hides a snippet is inserted: ordering the bar out hands the
    /// keyboard back to the previous app's window asynchronously, and the paste must reach it.
    static let snippetDelay: TimeInterval = 0.15

    private var immediate: [SearchResult] = []
    private var snippetHits: [SnippetHit] = []
    private var fileHits: [FileHit] = []
    private var generation = 0
    private var fileTask: SearchCancellable?
    /// The selection was moved by hand since the last keystroke: it then stays on its row as
    /// replies arrive; otherwise it stays on the top row, the best match.
    private var chosen = false

    init(engine: SearchEngine) {
        self.engine = engine
    }

    var selected: SearchResult? { results.indices.contains(selection) ? results[selection] : nil }

    func setQuery(_ text: String) {
        query = text
        chosen = false
        generation += 1
        fileTask?.cancel()
        fileTask = nil
        guard !SearchEngine.isEmpty(text) else {
            immediate = []
            snippetHits = []
            fileHits = []
            update(keepSelection: false)
            return
        }
        immediate = engine.immediate(text)
        snippetHits = snippetHits.filter { hit in
            [hit.name, hit.keyword].contains { FuzzyMatch.score(text, $0) != nil }
        }
        fileHits = fileHits.filter { FuzzyMatch.score(text, $0.name) != nil }
        update(keepSelection: false)

        let current = generation
        engine.listSnippets(text) { [weak self] hits in
            guard let self, self.generation == current else { return }
            self.snippetHits = hits
            self.update(keepSelection: true)
        }
        schedule(fileDebounce) { [weak self] in
            guard let self, self.generation == current else { return }
            self.fileTask = self.engine.searchFiles(text) { [weak self] hits in
                guard let self, self.generation == current else { return }
                self.fileTask = nil
                self.fileHits = hits
                self.update(keepSelection: true)
            }
        }
    }

    /// Shows `results` for `query` as they are, asking no source (snapshots).
    func present(query: String, results: [SearchResult], selection: Int = 0) {
        generation += 1
        self.query = query
        self.results = results
        self.selection = min(max(0, selection), max(0, results.count - 1))
    }

    /// Re-ranks; a reply arriving keeps a chosen selection on the row it was on.
    private func update(keepSelection: Bool) {
        let key = selected?.key
        results = SearchRanking.merge(immediate + SearchRanking.snippets(snippetHits, query: query),
                                      files: SearchRanking.files(fileHits, query: query))
        let kept = keepSelection && chosen ? key.flatMap { k in results.firstIndex { $0.key == k } } : nil
        selection = kept ?? 0
        onResultsChange()
    }


    /// Handles one of the bar's keys; true when it was the bar's (always, for these keys).
    @discardableResult
    func handle(_ command: SearchCommand) -> Bool {
        switch command {
        case .move(let delta):
            selection = results.isEmpty ? 0 : min(max(0, selection + delta), results.count - 1)
            chosen = true
        case .run(let modifier):
            run(row: selection, modifier)
        case .runRow(let row):
            run(row: row, .plain)
        case .close:
            onHide()
        }
        return true
    }

    /// Hides the bar, then runs the row.
    func run(row: Int, _ modifier: SearchModifier) {
        guard results.indices.contains(row) else { return }
        let action = SearchKeys.action(for: results[row], modifier)
        onHide()
        if case .launch(let path) = action { recordLaunch(path) }
        let delay: TimeInterval
        if case .insertSnippet = action { delay = Self.snippetDelay } else { delay = 0 }
        schedule(delay) { [weak self] in self?.perform(action) }
    }

    /// Stops any search still out (the bar closed).
    func stop() {
        generation += 1
        fileTask?.cancel()
        fileTask = nil
    }
}
