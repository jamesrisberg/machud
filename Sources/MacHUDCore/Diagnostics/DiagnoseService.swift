import Foundation
import HUDKit

/// The `diagnose` verb's one path: gather the replies of the verbs the snapshot embeds, build the
/// snapshot from the providers, write it and report the file and what looks wrong. It changes no
/// window and no setting.
@MainActor
final class DiagnoseService {
    /// Produces one verb's reply, now or later, exactly once.
    typealias Source = @MainActor (_ done: @escaping ([String: Any]) -> Void) -> Void

    private let sources: [String: Source]
    private let providers: ([String: [String: Any]]) -> DiagnoseSnapshot.Providers
    private let store: DiagnoseStore

    /// - Parameters:
    ///   - sources: the replies to embed, by the key the snapshot files them under (`tooldock`,
    ///     `widgets`, `voiceStatus`, `voiceState`).
    ///   - providers: everything else the snapshot reads, given the gathered replies.
    init(sources: [String: Source], providers: @escaping ([String: [String: Any]]) -> DiagnoseSnapshot.Providers,
         store: DiagnoseStore) {
        self.sources = sources
        self.providers = providers
        self.store = store
    }

    /// `diagnose`: `{"ok": true, "path": ..., "anomalies": [...]}`.
    func registerControl(_ control: HUDSocketServer) {
        control.register("diagnose") { [weak self] _, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            self.run(done: done)
        }
    }

    /// Gathers the replies, then reads the windows (so the snapshot is as recent as the slowest
    /// reply), writes the file and answers. A failed write still reports the anomalies.
    func run(done: @escaping ([String: Any]) -> Void) {
        gather { [self] replies in
            let providers = providers(replies)
            let result = DiagnoseSnapshot.build(providers)
            do {
                let url = try store.write(result.document, at: providers.now())
                done(["ok": true, "path": url.path, "anomalies": result.anomalies])
            } catch {
                done(["ok": false, "error": "could not write the snapshot to \(store.directory.path): \(error.localizedDescription)",
                      "anomalies": result.anomalies])
            }
        }
    }

    private final class Gathering {
        var replies: [String: [String: Any]] = [:]
        var pending: Set<String>
        init(_ keys: Set<String>) { pending = keys }
    }

    private func gather(_ done: @escaping ([String: [String: Any]]) -> Void) {
        guard !sources.isEmpty else { done([:]); return }
        let state = Gathering(Set(sources.keys))
        for (key, source) in sources {
            source { reply in
                // A source that answers twice counts once.
                guard state.pending.remove(key) != nil else { return }
                state.replies[key] = reply
                if state.pending.isEmpty { done(state.replies) }
            }
        }
    }
}
