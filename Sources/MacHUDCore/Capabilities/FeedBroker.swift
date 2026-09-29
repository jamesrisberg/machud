import HUDKit

/// Brokers HUDKit's `text-feed` capability: finds the discovered sibling apps that declare it on
/// a panel and serves `feed add text= source= [title=] [date=]`, so a client (the voice host) can
/// send finished text (a dictation transcript, an agent reply, ...) without naming an app. See
/// `../hudkit/docs/CONTRACT.md` § Text feed.
///
/// Unlike `sessions open`, `feed add` never launches an app just to feed it: it fans out to
/// every provider that is already running and reports which ones accepted the item.
@MainActor
final class FeedBroker {
    /// The manifest capability a panel lists to accept fed text.
    // HUDKit's `text-feed` capability (`HUDTextFeed.capability`) is still on
    // wave/voice-5/feed; machud builds against hudkit main until it merges, so this stays a
    // literal until a follow-up commit switches it to the constant.
    static let capability = "text-feed"
    private static let command = "feed"
    private static let addAction = "add"

    let externals: ExternalPanels
    private let router: CapabilityRouter

    init(externals: ExternalPanels) {
        self.externals = externals
        router = CapabilityRouter(capability: Self.capability, externals: externals)
    }

    /// Discovered apps with a panel declaring the capability, in discovery order.
    var providers: [ExternalApp] { router.providers }

    /// `feed add text= source= [title=] [date=]`: forwards `feed action=add ...` to every
    /// provider whose process is already up (never launches one), waits for each provider's
    /// reply, and reports which ones accepted it. `{"ok": true, "delivered": []}` when none run.
    func add(text: String, source: String, title: String?, date: String?, done: @escaping ([String: Any]) -> Void) {
        let targets = router.runningProviders
        guard !targets.isEmpty else { done(["ok": true, "delivered": []]); return }
        var args = [
            "action": Self.addAction,
            "text": text,
            "source": source,
        ]
        if let title { args["title"] = title }
        if let date { args["date"] = date }
        // Every completion arrives back on the main actor (like every other supervisor
        // callback), so a plain counter is enough to know when the fan-out is done; no queue
        // hop needed, and the reply comes back in discovery order rather than arrival order.
        var remaining = targets.count
        var delivered: Set<String> = []
        for app in targets {
            externals.supervisor.send(app.id, command: Self.command, args: args) { result in
                if case .success(let reply) = result, (reply["ok"] as? Bool) == true { delivered.insert(app.id) }
                remaining -= 1
                guard remaining == 0 else { return }
                done(["ok": true, "delivered": targets.map(\.id).filter(delivered.contains)])
            }
        }
    }

    // MARK: - Control

    /// `feed add text= source= [title=] [date=]` (default action `add`, the only one so far).
    func registerControl(_ control: HUDSocketServer) {
        control.register(Self.command) { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            let action = args["action"] ?? Self.addAction
            guard action == Self.addAction else {
                done(["ok": false, "error": "feed action must be add"]); return
            }
            guard let text = args["text"], !text.isEmpty else {
                done(["ok": false, "error": "feed add needs text="]); return
            }
            guard let source = args["source"], !source.isEmpty else {
                done(["ok": false, "error": "feed add needs source="]); return
            }
            self.add(text: text, source: source, title: args["title"], date: args["date"], done: done)
        }
    }
}
