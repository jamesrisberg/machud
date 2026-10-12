import Foundation
import HUDKit

/// The search bar and what feeds it: the app index and launch counts (seeded once from
/// Alfred), Spotlight's files, the offered loadouts (applied and previewed through the loadout
/// menu), Stash's snippets, and the `search` verb. `bar.show(query:)` and `bar.hide()` open
/// and close it.
@MainActor
final class SearchServices {
    let bar: SearchBar
    let control: SearchControl
    private let counts: LaunchCounts
    private let index: AppIndex
    private let performer = SearchPerformer()

    init(store: LayoutStore, menu: LoadoutMenu) {
        let counts = LaunchCounts()
        let index = AppIndex()
        let snippets = StashSnippets(path: { HUDSocket.path(for: "stash") })
        let engine = SearchEngine(apps: index, counts: { counts.counts }, loadouts: { [weak store] in
            store.map { ExperimentalLoadouts.offered(in: $0.config).map(\.name) } ?? []
        }, snippets: snippets, files: SpotlightFileSearch())
        performer.snippets = snippets
        performer.loadout = { [weak store, weak menu] name, run in
            guard let loadout = store?.loadout(named: name) else { return }
            switch run {
            case .apply: menu?.apply(loadout, clear: false)
            case .clearAndApply: menu?.apply(loadout, clear: true)
            case .preview: menu?.preview(loadout)
            }
        }
        let model = SearchModel(engine: engine)
        model.perform = { [performer] in performer.perform($0) }
        model.recordLaunch = { counts.record($0) }
        bar = SearchBar(model: model)
        control = SearchControl(engine: engine, bar: bar)
        self.counts = counts
        self.index = index
        index.refresh()
        seedFromAlfred()
    }

    func registerControl(_ server: HUDSocketServer) {
        control.registerControl(server)
    }

    /// Alfred's launch counts, read once off the main thread, if they have not been yet.
    private func seedFromAlfred() {
        guard !counts.alfredSeeded else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let alfred = AlfredHistory.launchCounts()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.counts.seed(fromAlfred: alfred) else { return }
                    NSLog("MacHUD: search bar launch counts seeded from Alfred's history (%d apps)", alfred?.count ?? 0)
                }
            }
        }
    }
}
