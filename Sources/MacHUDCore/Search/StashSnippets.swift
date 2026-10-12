import Foundation
import HUDKit

/// Where the bar's snippet rows come from and how one is inserted.
@MainActor
protocol SnippetSource: AnyObject {
    /// The snippets matching `query`; empty when there are none or no one to ask.
    func list(query: String, limit: Int, completion: @escaping ([SnippetHit]) -> Void)
    /// Expands and pastes the snippet into the frontmost app; `completion` gets the reply.
    func insert(id: String, completion: @escaping ([String: Any]) -> Void)
}

/// Stash's snippets over its socket: `snippets list [query=] [limit=]` →
/// `{snippets: [{id, name, keyword, collection, preview}]}`, and `snippets insert id=` →
/// `{ok: true, pasted: true}` or `{ok: true, pasted: false, hint}`. Asks only a Stash that is
/// already running (MacHUD's supervisor would launch it); a missing Stash, or one without the
/// verb, lists nothing.
@MainActor
final class StashSnippets: SnippetSource {
    private let path: () -> String
    /// Listing answers within a keystroke or two, or not at all.
    private let lister: SocketConnector
    /// Inserting waits for Stash to paste.
    private let inserter: SocketConnector

    init(path: @escaping () -> String, lister: SocketConnector? = nil, inserter: SocketConnector? = nil) {
        self.path = path
        self.lister = lister ?? Self.connector(timeout: 1)
        self.inserter = inserter ?? Self.connector(timeout: 5)
    }

    private static func connector(timeout: TimeInterval) -> HUDSocketConnector {
        let connector = HUDSocketConnector()
        connector.timeout = timeout
        return connector
    }

    /// The arguments `stash snippets <verb> key=value…` sends, so Stash reads them however it
    /// reads its own CLI's.
    nonisolated static func args(_ verb: String, _ args: [String: String]) -> [String: String] {
        args.merging(["_": verb, verb: "1"]) { a, _ in a }
    }

    func list(query: String, limit: Int, completion: @escaping ([SnippetHit]) -> Void) {
        var args = ["limit": String(limit)]
        if !query.isEmpty { args["query"] = query }
        lister.request(path: path(), command: "snippets", args: Self.args("list", args)) { result in
            guard case .success(let reply) = result else { completion([]); return }
            completion(Self.parse(reply))
        }
    }

    func insert(id: String, completion: @escaping ([String: Any]) -> Void) {
        inserter.request(path: path(), command: "snippets", args: Self.args("insert", ["id": id])) { result in
            switch result {
            case .success(let reply): completion(reply)
            case .failure(HUDSocketError.notRunning): completion(["ok": false, "error": "Stash is not running"])
            case .failure(let error): completion(["ok": false, "error": "Stash did not answer: \(error)"])
            }
        }
    }

    /// The snippets in a `snippets list` reply; none for a refusal or an unknown verb.
    nonisolated static func parse(_ reply: [String: Any]) -> [SnippetHit] {
        guard reply["ok"] as? Bool != false, let list = reply["snippets"] as? [[String: Any]] else { return [] }
        return list.compactMap { s in
            guard let id = (s["id"] as? String) ?? (s["id"] as? Int).map(String.init), !id.isEmpty else { return nil }
            return SnippetHit(id: id, name: s["name"] as? String ?? "", keyword: s["keyword"] as? String ?? "",
                              collection: s["collection"] as? String ?? "", preview: s["preview"] as? String ?? "")
        }
    }

    /// What to tell the user after an insert: Stash's hint when it could not paste, the error
    /// when it failed, nil when the text went in.
    nonisolated static func problem(in reply: [String: Any]) -> String? {
        if reply["ok"] as? Bool == false { return reply["error"] as? String ?? "Stash could not insert the snippet" }
        if reply["pasted"] as? Bool == false { return reply["hint"] as? String ?? "Stash could not paste the snippet" }
        return nil
    }
}
