import AppKit
import HUDKit

/// The sibling apps' status menus, fetched live over their sockets (`menu`) for the status
/// menu's Apps section, and performed with `menu-invoke`. Replies are cached for `ttl`
/// seconds so opening the menu twice in a row does not ask again.
@MainActor
final class AppMenus {
    static let ttl: TimeInterval = 3

    struct Entry {
        var items: [HUDMenuBridge.Item]
        var fetchedAt: Date
        /// Why the app gave no menu (`no menu`, an old app without the verb, a socket error).
        var error: String?
    }

    enum Failure: Error, CustomStringConvertible {
        case notRunning(String), refused(String)
        var description: String {
            switch self {
            case .notRunning(let id): return "\(id) is not running"
            case .refused(let why): return why
            }
        }
    }

    let supervisor: AppSupervisor
    private(set) var cache: [String: Entry] = [:]
    private var waiting: [String: [(Result<[HUDMenuBridge.Item], Error>) -> Void]] = [:]
    /// Called on the main thread after an app's menu was (re)fetched.
    var onUpdate: ((String) -> Void)?

    init(supervisor: AppSupervisor) {
        self.supervisor = supervisor
    }

    func entry(_ id: String) -> Entry? { cache[id] }

    func isFresh(_ id: String) -> Bool {
        guard let entry = cache[id] else { return false }
        return supervisor.now().timeIntervalSince(entry.fetchedAt) < Self.ttl
    }

    /// Fetches the app's menu unless a fresh copy is cached (or `force`). Concurrent calls
    /// share one request. Apps that are not reachable fail without a request.
    func refresh(_ id: String, force: Bool = false,
                 completion: ((Result<[HUDMenuBridge.Item], Error>) -> Void)? = nil) {
        if !force, isFresh(id), let entry = cache[id] {
            completion?(entry.error.map { .failure(Failure.refused($0)) } ?? .success(entry.items))
            return
        }
        guard let record = supervisor.record(id), record.health == .running else {
            cache[id] = nil
            completion?(.failure(Failure.notRunning(id)))
            return
        }
        if waiting[id] != nil {
            if let completion { waiting[id]?.append(completion) }
            return
        }
        waiting[id] = completion.map { [$0] } ?? []
        supervisor.connector.request(path: record.app.socketPath, command: "menu", args: [:]) { [weak self] result in
            guard let self else { return }
            let outcome: Result<[HUDMenuBridge.Item], Error>
            switch result {
            case .success(let reply) where reply["ok"] as? Bool == true:
                let items = HUDMenuBridge.Item.list(reply["items"])
                self.cache[id] = Entry(items: items, fetchedAt: self.supervisor.now())
                outcome = .success(items)
            case .success(let reply):
                let why = reply["error"] as? String ?? "menu refused"
                self.cache[id] = Entry(items: [], fetchedAt: self.supervisor.now(), error: why)
                outcome = .failure(Failure.refused(why))
            case .failure(let error):
                self.cache[id] = Entry(items: [], fetchedAt: self.supervisor.now(), error: "\(error)")
                outcome = .failure(error)
            }
            let callbacks = self.waiting.removeValue(forKey: id) ?? []
            for callback in callbacks { callback(outcome) }
            self.onUpdate?(id)
        }
    }

    /// Prefetches every running app whose copy is stale (when the status menu opens).
    func refreshRunning() {
        for record in supervisor.all where record.health == .running && !isFresh(record.app.id) {
            refresh(record.app.id)
        }
    }

    /// Performs `item` in the app. The cached menu is dropped so the next open shows the
    /// result (a toggled check mark).
    func invoke(_ id: String, item: String, title: String? = nil,
                completion: ((Result<[String: Any], Error>) -> Void)? = nil) {
        guard let record = supervisor.record(id), record.health == .running else {
            completion?(.failure(Failure.notRunning(id)))
            return
        }
        var args = ["id": item]
        if let title { args["title"] = title }
        cache[id] = nil
        supervisor.connector.request(path: record.app.socketPath, command: "menu-invoke", args: args) { result in
            switch result {
            case .success(let reply) where reply["ok"] as? Bool == true: completion?(.success(reply))
            case .success(let reply): completion?(.failure(Failure.refused(reply["error"] as? String ?? "menu-invoke refused")))
            case .failure(let error): completion?(.failure(error))
            }
        }
    }

    // MARK: - Building

    /// What an app's reply looks like inside MacHUD's submenu: without the app's own Quit
    /// item (the submenu has one), and without leading, trailing or doubled separators.
    nonisolated static func filtered(_ items: [HUDMenuBridge.Item]) -> [HUDMenuBridge.Item] {
        var out: [HUDMenuBridge.Item] = []
        for item in items {
            if item.kind == .item, item.title.hasPrefix("Quit ") || item.title == "Quit" { continue }
            if item.kind == .separator, out.last?.kind == .separator || out.isEmpty { continue }
            var copy = item
            if let children = item.items { copy.items = filtered(children) }
            out.append(copy)
        }
        while out.last?.kind == .separator { out.removeLast() }
        return out
    }

    /// `NSMenuItem`s for `items`, each sending `action` to `target` with an `AppMenuRef`.
    static func menuItems(_ items: [HUDMenuBridge.Item], appID: String, target: AnyObject, action: Selector) -> [NSMenuItem] {
        items.map { item in
            switch item.kind {
            case .separator:
                return .separator()
            case .submenu:
                let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.autoenablesItems = false
                for child in menuItems(item.items ?? [], appID: appID, target: target, action: action) { sub.addItem(child) }
                parent.submenu = sub
                parent.isEnabled = item.enabled
                return parent
            case .item:
                let mi = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent ?? "")
                if item.keyEquivalent != nil { mi.keyEquivalentModifierMask = item.modifierFlags }
                mi.target = target
                mi.isEnabled = item.enabled
                mi.state = item.state == .on ? .on : item.state == .mixed ? .mixed : .off
                mi.representedObject = AppMenuRef(appID: appID, item: item)
                return mi
            }
        }
    }
}

/// What an Apps-section item carries: which app and which of its menu items.
final class AppMenuRef: NSObject {
    let appID: String
    let item: HUDMenuBridge.Item
    init(appID: String, item: HUDMenuBridge.Item) {
        self.appID = appID
        self.item = item
    }
}
