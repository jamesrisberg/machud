import Foundation

/// One runtime from the voice host's `brain status` (`runtimes[]`): a BrainKit built-in or a
/// runtime plugin, as the host detected it. The Brain tab and the onboarding both read it.
struct BrainRuntimeInfo: Equatable, Identifiable {
    var id: String
    /// The built-in's name or the plugin's title.
    var name: String
    var installed: Bool
    /// It can take a turn with the current settings; `reason` says why not.
    var available: Bool
    var plugin: Bool
    var reason: String?
    var path: String?
    var installCommand: String?
    var loginCommand: String?
    var loginTitle: String?
    /// A plugin's one line to show beside it.
    var note: String?
    var summary: String?
    var docsURL: URL?

    init(id: String, name: String? = nil, installed: Bool, available: Bool? = nil, plugin: Bool = false,
         reason: String? = nil, path: String? = nil, installCommand: String? = nil, loginCommand: String? = nil,
         loginTitle: String? = nil, note: String? = nil, summary: String? = nil, docsURL: URL? = nil) {
        self.id = id
        self.name = name ?? id
        self.installed = installed
        self.available = available ?? installed
        self.plugin = plugin
        self.reason = reason
        self.path = path
        self.installCommand = installCommand
        self.loginCommand = loginCommand
        self.loginTitle = loginTitle
        self.note = note
        self.summary = summary
        self.docsURL = docsURL
    }

    /// Nil without an `id`. A reply without `available` (a host from before it was reported)
    /// counts an installed runtime as available.
    init?(_ entry: [String: Any]) {
        guard let id = entry["id"] as? String else { return nil }
        let text = { (key: String) in (entry[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        self.init(id: id, name: text("name"), installed: entry["installed"] as? Bool ?? false,
                  available: entry["available"] as? Bool, plugin: entry["plugin"] as? Bool ?? false,
                  reason: text("reason"), path: text("path"), installCommand: text("installCommand"),
                  loginCommand: text("loginCommand"), loginTitle: text("loginTitle"), note: text("note"),
                  summary: text("summary"), docsURL: text("docsURL").flatMap(URL.init(string:)))
    }

    /// The name with what keeps it from taking a turn: not installed, or unavailable.
    var title: String {
        if available { return name }
        return installed ? "\(name) (unavailable)" : "\(name) (not installed)"
    }
}
