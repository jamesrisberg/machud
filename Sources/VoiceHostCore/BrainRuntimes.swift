import BrainKit
import Foundation

/// One brain runtime as this Mac has it, built-in or runtime plugin: BrainKit's
/// `BrainCatalog.Detection` in the form `brain status` reports it.
public struct BrainRuntimeDetection: Equatable, Sendable {
    /// The settings value (`brain.runtime`): `codex`, `hermes`, `claude` or a plugin's id.
    public var id: String
    /// The name to show: a built-in's name or the plugin's title.
    public var name: String
    public var installed: Bool
    /// The executable found (or the override given), nil when none is.
    public var path: String?
    /// Hermes only: `~/.hermes/.env` turns on the API server the companion talks to.
    public var apiServerEnabled: Bool?
    /// BrainKit's reason it cannot be used (not installed, a tool it requires is missing, a
    /// plugin refused or not found); nil when it can.
    public var unavailableReason: String?
    /// A runtime plugin rather than one of BrainKit's built-ins.
    public var plugin: Bool
    public var installCommand: String?
    public var loginCommand: String?
    public var loginTitle: String?
    /// A plugin's one line to show beside it.
    public var note: String?
    public var summary: String?
    public var docsURL: URL?

    public init(id: String, name: String, installed: Bool, path: String? = nil, apiServerEnabled: Bool? = nil,
                unavailableReason: String? = nil, plugin: Bool = false, installCommand: String? = nil,
                loginCommand: String? = nil, loginTitle: String? = nil, note: String? = nil,
                summary: String? = nil, docsURL: URL? = nil) {
        self.id = id
        self.name = name
        self.installed = installed
        self.path = path
        self.apiServerEnabled = apiServerEnabled
        self.unavailableReason = unavailableReason
        self.plugin = plugin
        self.installCommand = installCommand
        self.loginCommand = loginCommand
        self.loginTitle = loginTitle
        self.note = note
        self.summary = summary
        self.docsURL = docsURL
    }

    public init(_ detection: BrainCatalog.Detection) {
        self.init(id: detection.runtime.rawValue, name: detection.title, installed: detection.isInstalled,
                  path: detection.executable, apiServerEnabled: detection.apiServerEnabled,
                  unavailableReason: detection.unavailableReason, plugin: !detection.runtime.isBuiltIn,
                  installCommand: detection.installCommand, loginCommand: detection.loginCommand,
                  loginTitle: detection.loginTitle, note: detection.note, summary: detection.summary,
                  docsURL: detection.docsURL)
    }

    /// The `brain status` entry; `problem` is why it cannot take a turn with the current
    /// settings (`BrainRuntimes.problem`).
    func json(problem: String?) -> [String: Any] {
        var entry: [String: Any] = ["id": id, "name": name, "installed": installed, "plugin": plugin,
                                    "available": problem == nil]
        if let problem { entry["reason"] = problem }
        if let path { entry["path"] = path }
        if let apiServerEnabled { entry["apiServer"] = apiServerEnabled }
        if let installCommand { entry["installCommand"] = installCommand }
        if let loginCommand { entry["loginCommand"] = loginCommand }
        if let loginTitle { entry["loginTitle"] = loginTitle }
        if let note { entry["note"] = note }
        if let summary { entry["summary"] = summary }
        if let docsURL { entry["docsURL"] = docsURL.absoluteString }
        return entry
    }
}

/// The runtimes the Brain settings offer: BrainKit's built-ins and every runtime plugin
/// installed, detected the way BrainKit looks tools up (`ExecutableLocator`: PATH, then the
/// usual install folders; a path override wins), in BrainKit's order.
public enum BrainRuntimes {
    /// Every runtime BrainKit finds, with the path overrides in `brain`. A chosen runtime
    /// BrainKit does not list (a plugin that is not installed) is added with BrainKit's reason,
    /// so it shows as unavailable rather than disappearing.
    public static func detect(_ brain: BrainSettings, locator: ExecutableLocator = .live,
                              readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> [BrainRuntimeDetection] {
        var overrides: [AgentRuntime: String] = [.codex: brain.codex.executablePath, .claude: brain.claude.executablePath]
        for (id, options) in brain.plugins {
            if let runtime = AgentRuntime(rawValue: id), !runtime.isBuiltIn { overrides[runtime] = options.executablePath }
        }
        var found = BrainCatalog.detectAll(locator: locator, overrides: overrides, readFile: readFile)
        if !found.contains(where: { $0.runtime == brain.runtime }) {
            found.append(BrainCatalog.detect(brain.runtime, locator: locator, override: overrides[brain.runtime] ?? "",
                                             readFile: readFile))
        }
        return found.map(BrainRuntimeDetection.init)
    }

    /// Why the chosen runtime cannot take a turn on this Mac, or nil.
    static func problem(runtime id: String, brain: BrainSettings, detections: [BrainRuntimeDetection]) -> String? {
        detections.first { $0.id == id }.flatMap { problem(of: $0, brain: brain) }
    }

    /// Why `detection` cannot take a turn with these settings, or nil.
    static func problem(of detection: BrainRuntimeDetection, brain: BrainSettings) -> String? {
        guard detection.id == AgentRuntime.hermes.rawValue else { return detection.unavailableReason }
        // The companion reaches Hermes over HTTP: a URL given in the settings needs nothing local.
        guard brain.hermes.url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let reason = detection.unavailableReason { return reason }
        if detection.apiServerEnabled == false {
            return "Hermes' API server is off: set API_SERVER_ENABLED=true in ~/.hermes/.env."
        }
        return nil
    }

    /// `brain status`'s `runtimes`: each one's entry, available or with its reason.
    static func status(_ detections: [BrainRuntimeDetection], brain: BrainSettings) -> [[String: Any]] {
        detections.map { $0.json(problem: problem(of: $0, brain: brain)) }
    }
}
