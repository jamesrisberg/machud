import BrainKit
import Foundation

/// One brain runtime as this Mac has it: whether its tool is installed and where.
public struct BrainRuntimeDetection: Equatable, Sendable {
    /// The settings value (`brain.runtime`): `codex`, `claude`, `hermes` or `mclaude`.
    public var id: String
    public var name: String
    public var installed: Bool
    /// The executable found (or the override given), nil when none is.
    public var path: String?
    /// Hermes only: `~/.hermes/.env` turns on the API server the companion talks to.
    public var apiServerEnabled: Bool?

    public init(id: String, name: String, installed: Bool, path: String? = nil,
                apiServerEnabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.installed = installed
        self.path = path
        self.apiServerEnabled = apiServerEnabled
    }

    /// The `brain status` entry.
    var json: [String: Any] {
        var entry: [String: Any] = ["id": id, "name": name, "installed": installed]
        if let path { entry["path"] = path }
        if let apiServerEnabled { entry["apiServer"] = apiServerEnabled }
        return entry
    }
}

/// The runtimes the Brain settings offer, detected the way BrainKit looks tools up
/// (`ExecutableLocator`: PATH, then the usual install folders; a path override wins).
public enum BrainRuntimes {
    static let mclaude = "mclaude"
    /// In the order the Brain tab lists them.
    public static let ids = ["codex", "claude", "hermes", mclaude]

    public static func name(for id: String) -> String {
        switch id {
        case "codex": return "Codex"
        case "claude": return "Claude"
        case "hermes": return "Hermes"
        case mclaude: return "mclaude"
        default: return id
        }
    }

    /// Every runtime in `ids`, with the path overrides in `brain`.
    public static func detect(_ brain: BrainSettings, locator: ExecutableLocator = .live,
                              readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> [BrainRuntimeDetection] {
        ids.map { id in
            if id == mclaude {
                let path = locator.locate("mclaude", override: brain.mclaude.executablePath)
                return BrainRuntimeDetection(id: id, name: name(for: id), installed: path != nil, path: path)
            }
            guard let runtime = AgentRuntime(rawValue: id) else {
                return BrainRuntimeDetection(id: id, name: name(for: id), installed: false)
            }
            let override: String
            switch id {
            case "codex": override = brain.codex.executablePath
            case "claude": override = brain.claude.executablePath
            default: override = ""
            }
            let found = BrainCatalog.detect(runtime, locator: locator, override: override, readFile: readFile)
            return BrainRuntimeDetection(id: id, name: name(for: id), installed: found.isInstalled,
                                         path: found.executable, apiServerEnabled: found.apiServerEnabled)
        }
    }

    /// Why the chosen runtime cannot take a turn on this Mac, or nil.
    static func problem(runtime id: String, brain: BrainSettings, detections: [BrainRuntimeDetection]) -> String? {
        guard let detection = detections.first(where: { $0.id == id }) else { return nil }
        if id == "hermes" {
            // The companion reaches Hermes over HTTP: a URL given in the settings needs nothing local.
            guard brain.hermes.url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            if !detection.installed { return "Hermes is not installed." }
            if detection.apiServerEnabled == false {
                return "Hermes' API server is off: set API_SERVER_ENABLED=true in ~/.hermes/.env."
            }
            return nil
        }
        return detection.installed ? nil : "\(detection.name) is not installed."
    }
}
