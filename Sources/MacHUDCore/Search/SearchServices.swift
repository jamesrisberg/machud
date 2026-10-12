import Foundation
import HUDKit

/// The search bar and what feeds it: the app index and launch counts (seeded once from
/// Alfred), Spotlight's files, the offered loadouts (applied and previewed through the loadout
/// menu), Stash's snippets, and the `search` verb. `bar.show(query:)` and `bar.hide()` open
/// and close it. An isolated instance asks no Stash and reads no Alfred history unless
/// `MACHUD_STASH_SOCKET` or `MACHUD_ALFRED_DB` names one.
@MainActor
final class SearchServices {
    let bar: SearchBar
    let control: SearchControl
    private let counts: LaunchCounts
    private let index: AppIndex
    private let performer = SearchPerformer()

    /// Stash's bundle id, whose supervisor record gives its socket.
    static let stashID = "xyz.machud.stash"

    private let alfred: URL?

    init(store: LayoutStore, menu: LoadoutMenu, externals: ExternalPanels,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let counts = LaunchCounts()
        let index = AppIndex()
        let supervisor = externals.supervisor
        let recorded = { [weak supervisor] in supervisor?.record(Self.stashID)?.app.socketPath }
        let snippets: StashSnippets? = Env.isIsolated(in: environment) && Env.value("STASH_SOCKET", in: environment) == nil
            ? nil : StashSnippets(path: { Self.stashSocket(environment: environment, recorded: recorded) })
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
        alfred = Self.alfredDatabase(environment: environment)
        index.refresh()
        seedFromAlfred()
    }

    func registerControl(_ server: HUDSocketServer) {
        control.registerControl(server)
    }

    /// The socket the bar asks for snippets: `MACHUD_STASH_SOCKET`, else the running Stash's as
    /// the supervisor recorded it; none for an isolated instance (it must not reach the real
    /// Stash) or while no Stash is discovered.
    nonisolated static func stashSocket(environment: [String: String], recorded: () -> String?) -> String? {
        if let path = Env.value("STASH_SOCKET", in: environment), !path.isEmpty { return path }
        return Env.isIsolated(in: environment) ? nil : recorded()
    }

    /// The Alfred history to seed from: `MACHUD_ALFRED_DB`, else Alfred's own; none for an
    /// isolated instance.
    nonisolated static func alfredDatabase(environment: [String: String]) -> URL? {
        if let path = Env.value("ALFRED_DB", in: environment), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return Env.isIsolated(in: environment) ? nil : AlfredHistory.defaultURL
    }

    /// Alfred's launch counts, read once off the main thread, if they have not been yet.
    private func seedFromAlfred() {
        guard !counts.alfredSeeded, let url = alfred else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let history = AlfredHistory.launchCounts(at: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.counts.seed(fromAlfred: history) else { return }
                    NSLog("MacHUD: search bar launch counts seeded from Alfred's history (%d apps)", history?.count ?? 0)
                }
            }
        }
    }
}
