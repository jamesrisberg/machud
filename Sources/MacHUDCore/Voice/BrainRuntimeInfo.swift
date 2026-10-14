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
    /// A plugin that is there but that BrainKit will not use; unavailable, not "not installed".
    var refused: Bool
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
         refused: Bool = false, reason: String? = nil, path: String? = nil, installCommand: String? = nil, loginCommand: String? = nil,
         loginTitle: String? = nil, note: String? = nil, summary: String? = nil, docsURL: URL? = nil) {
        self.id = id
        self.name = name ?? id
        self.installed = installed
        self.available = available ?? installed
        self.plugin = plugin
        self.refused = refused
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
                  refused: entry["refused"] as? Bool ?? false,
                  reason: text("reason"), path: text("path"), installCommand: text("installCommand"),
                  loginCommand: text("loginCommand"), loginTitle: text("loginTitle"), note: text("note"),
                  summary: text("summary"), docsURL: text("docsURL").flatMap(URL.init(string:)))
    }

    enum State: Equatable {
        /// It can take a turn (Hermes reached by its URL is available without being installed).
        case available
        /// Its tool is not on this Mac, or a plugin is not there at all.
        case notInstalled
        /// It is there but cannot be used: a refused plugin, a tool it requires is missing,
        /// Hermes' API server is off. `reason` says which.
        case unavailable
    }

    /// Decided from `available` first, so "not installed" is said only of what really is not.
    var state: State {
        if available { return .available }
        return installed || refused ? .unavailable : .notInstalled
    }

    /// The name with what keeps it from taking a turn.
    var title: String {
        switch state {
        case .available: return name
        case .notInstalled: return "\(name) (not installed)"
        case .unavailable: return "\(name) (unavailable)"
        }
    }

    /// The command worth offering: the install command while it is not installed, the sign-in
    /// command once its tool is here; none for a refused plugin or a runtime reached remotely.
    var command: (title: String, command: String)? {
        switch state {
        case .notInstalled: return installCommand.map { ("Install", $0) }
        case .available, .unavailable: return installed ? loginCommand.map { (loginTitle ?? "Log In", $0) } : nil
        }
    }
}
