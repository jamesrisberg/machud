import Foundation
import HUDKit

/// What the `search` verb drives: the bar on screen.
@MainActor
protocol SearchBarPresenting: AnyObject {
    var isVisible: Bool { get }
    var query: String { get }
    func show(query: String?)
    func hide()
    /// Renders the bar showing `results` for `query` to a PNG, offscreen.
    func writeSnapshot(to url: URL, query: String, results: [SearchResult]) throws
}

/// The `search` verb: `search [state]`, `search show [query=]`, `search hide`,
/// `search query text= [files=0]` (the ranked results as JSON, the bar untouched) and
/// `search snapshot path= [query=]`.
@MainActor
final class SearchControl {
    static let actions = ["state", "show", "hide", "query", "snapshot"]

    let engine: SearchEngine
    private(set) weak var bar: SearchBarPresenting?
    /// How long `search query` waits for Stash and Spotlight.
    var collectTimeout: TimeInterval = 2

    init(engine: SearchEngine, bar: SearchBarPresenting) {
        self.engine = engine
        self.bar = bar
    }

    func registerControl(_ control: HUDSocketServer) {
        control.register("search") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            self.handle(args, done: done)
        }
    }

    private var state: [String: Any] { ["ok": true, "visible": bar?.isVisible ?? false, "query": bar?.query ?? ""] }

    /// `key=`'s value, unless `key` is the action's own word (`search query` sends `query: 1`).
    private static func value(_ args: [String: String], _ key: String, action: String) -> String? {
        action == key ? nil : args[key]
    }

    func handle(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        // `machud search show query=saf` arrives as `_: show, show: 1, query: saf`.
        let action = args["action"].flatMap { $0 == "1" ? nil : $0 } ?? args["_"]
            ?? Self.actions.first { args[$0] == "1" } ?? "state"
        switch action {
        case "state":
            done(state)
        case "show":
            bar?.show(query: Self.value(args, "query", action: action))
            done(state)
        case "hide":
            bar?.hide()
            done(state)
        case "query":
            guard let text = args["text"], !SearchEngine.isEmpty(text) else {
                done(["ok": false, "error": "search query needs text=<text>"]); return
            }
            let files = !["0", "false", "no", "off"].contains((args["files"] ?? "1").lowercased())
            engine.collect(text, files: files, timeout: collectTimeout) { results in
                done(["ok": true, "query": text, "results": Self.json(results)])
            }
        case "snapshot":
            guard let path = Self.value(args, "path", action: action), !path.isEmpty else {
                done(["ok": false, "error": "search snapshot needs path=<png>"]); return
            }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let query = Self.value(args, "query", action: action) ?? bar?.query ?? ""
            engine.collect(query, timeout: collectTimeout) { [weak bar] results in
                do {
                    guard let bar else { throw CocoaError(.fileWriteUnknown) }
                    try bar.writeSnapshot(to: url, query: query, results: results)
                    done(["ok": true, "path": url.path, "query": query, "results": Self.json(results)])
                } catch {
                    done(["ok": false, "error": "could not write \(url.path): \(error)"])
                }
            }
        default:
            done(["ok": false, "error": "search takes \(Self.actions.joined(separator: ", ")), not \(action)"])
        }
    }

    /// Each result's JSON with its 1-based `rank` (the row it shows on).
    static func json(_ results: [SearchResult]) -> [[String: Any]] {
        results.enumerated().map { i, r in r.json.merging(["rank": i + 1]) { a, _ in a } }
    }
}
