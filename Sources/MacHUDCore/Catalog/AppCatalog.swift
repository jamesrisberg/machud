import AppKit
import HUDKit

/// `"catalog"` in layouts.json: where the app catalog comes from and where apps install.
///
/// ```json
/// "catalog": {"url": "https://jamesrisberg.github.io/machud/catalog.json",
///             "installDir": "~/Applications", "refreshHours": 6}
/// ```
struct CatalogConfig: Codable, Equatable {
    /// The catalog to read (https or file). Absent means `defaultURL`.
    var url: String?
    /// Where apps install. Absent means /Applications when writable, else ~/Applications.
    /// A configured directory is also searched for MacHUD apps.
    var installDir: String?
    /// How often the catalog is fetched again (default 6).
    var refreshHours: Double?

    static let defaultURL = "https://jamesrisberg.github.io/machud/catalog.json"

    var catalogURL: URL? {
        let raw = url ?? Self.defaultURL
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return URL(string: raw)
    }

    var refreshInterval: TimeInterval { max(0.25, refreshHours ?? 6) * 3600 }

    var installDirectory: URL? {
        installDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
}

extension Config {
    /// `apps` with the configured install directory added to its search paths, so apps
    /// installed there are discovered.
    var discoveryApps: AppsConfig {
        var apps = self.apps ?? AppsConfig()
        if let dir = catalog?.installDir, !(apps.searchPaths ?? []).contains(dir) {
            apps.searchPaths = (apps.searchPaths ?? []) + [dir]
        }
        return apps
    }
}

/// One app in the catalog (`catalog.json` → `apps[]`), as published by `hud-release.sh`.
struct CatalogEntry: Codable, Equatable, Identifiable {
    /// Bundle id (e.g. `xyz.machud.sift`).
    var id: String
    /// `owner/name` on GitHub.
    var repo: String?
    var name: String
    /// `windowed`, `hover` or `umbrella` (MacHUD itself).
    var kind: String
    var summary: String?
    var version: String
    var minOS: String?
    /// The notarized zip.
    var download: String?
    var sha256: String?
    var size: Int?
    var publishedAt: String?
    /// Icon URL (absolute, or relative to the catalog).
    var icon: String?
    var homepage: String?
    /// Installed by "Install bundled tools" and pre-selected on first run.
    var bundled: Bool?

    var isUmbrella: Bool { kind == "umbrella" }
    var isBundled: Bool { bundled ?? false }

    /// The release page: `<homepage>/releases/latest` when the homepage is a GitHub repo,
    /// else the repo's (`repo` is `name` under jamesrisberg, or `owner/name`), else `homepage`.
    var releasePage: URL? {
        if let homepage, let url = URL(string: homepage), url.host == "github.com",
           url.pathComponents.filter({ $0 != "/" }).count == 2 {
            return url.appendingPathComponent("releases/latest")
        }
        if let repo, !repo.isEmpty {
            let path = repo.contains("/") ? repo : "jamesrisberg/\(repo)"
            return URL(string: "https://github.com/\(path)/releases/latest")
        }
        return homepage.flatMap(URL.init(string:))
    }

    /// Whether `key` names this entry: its id, name, repo name, or the last component of its id.
    func matches(_ key: String) -> Bool {
        let k = key.lowercased()
        return id.lowercased() == k || name.lowercased() == k
            || repo?.split(separator: "/").last.map({ $0.lowercased() == k }) == true
            || id.split(separator: ".").last.map({ $0.lowercased() == k }) == true
    }

    var json: [String: Any] {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// `catalog.json`. Keys it does not know (`hudkit`) are ignored.
struct CatalogDocument: Codable, Equatable {
    var schemaVersion: Int
    var updatedAt: String?
    var apps: [CatalogEntry]

    static func decode(_ data: Data) throws -> CatalogDocument {
        let doc = try JSONDecoder().decode(CatalogDocument.self, from: data)
        guard doc.schemaVersion == 1 else { throw CatalogError.unsupportedSchema(doc.schemaVersion) }
        return doc
    }
}

enum CatalogError: Error, CustomStringConvertible {
    case unsupportedSchema(Int)
    case http(Int)
    case noURL(String)

    var description: String {
        switch self {
        case .unsupportedSchema(let v): return "catalog schemaVersion \(v) is not supported (expected 1)"
        case .http(let code): return "catalog request failed with HTTP \(code)"
        case .noURL(let raw): return "catalog.url is not a URL: \(raw)"
        }
    }
}

/// Dotted version comparison: `1.10.0` > `1.9`, a leading `v` is ignored, and a
/// pre-release suffix (`1.0.0-beta`) sorts before the release.
enum CatalogVersion {
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func split(_ s: String) -> (nums: [Int], pre: String?) {
            var s = s.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            let parts = s.split(separator: "-", maxSplits: 1)
            let nums = (parts.first ?? "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            return (nums, parts.count > 1 ? String(parts[1]) : nil)
        }
        let (x, y) = (split(a), split(b))
        for i in 0..<max(x.nums.count, y.nums.count) {
            let p = i < x.nums.count ? x.nums[i] : 0, q = i < y.nums.count ? y.nums[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        switch (x.pre, y.pre) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (p?, q?): return p == q ? .orderedSame : (p < q ? .orderedAscending : .orderedDescending)
        }
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }
}

/// An app bundle on disk and the version its Info.plist says.
struct InstalledCopy: Equatable {
    var bundleURL: URL
    var bundleID: String?
    var version: String?

    /// Reads Info.plist directly (`Bundle` caches, so it would miss an update in place).
    static func read(_ bundleURL: URL) -> InstalledCopy? {
        let plist = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return InstalledCopy(bundleURL: bundleURL, bundleID: info["CFBundleIdentifier"] as? String,
                             version: info["CFBundleShortVersionString"] as? String)
    }
}

/// A catalog entry against what is installed.
struct CatalogAppStatus: Equatable {
    enum State: String { case notInstalled, installed, updateAvailable, newerInstalled }

    var entry: CatalogEntry
    var installed: InstalledCopy?
    var running: Bool

    var state: State {
        guard let installed else { return .notInstalled }
        guard let version = installed.version else { return .updateAvailable }
        switch CatalogVersion.compare(entry.version, version) {
        case .orderedDescending: return .updateAvailable
        case .orderedAscending: return .newerInstalled
        case .orderedSame: return .installed
        }
    }

    var json: [String: Any] {
        var d = entry.json
        d["state"] = state.rawValue
        d["running"] = running
        if let installed {
            d["installed"] = ["path": installed.bundleURL.path, "version": installed.version ?? NSNull(),
                              "bundleID": installed.bundleID ?? NSNull()] as [String: Any]
        }
        return d
    }

    /// Matches each entry with `<Name>.app` in `directories` (the install directories)
    /// whose bundle id matches, else a discovered app (by bundle id, else name). An installed
    /// copy wins over a dev build discovered with the same id.
    static func compare(_ entries: [CatalogEntry], discovered: [ExternalApp], directories: [URL],
                        running: (String, URL) -> Bool) -> [CatalogAppStatus] {
        entries.map { entry in
            var copy: InstalledCopy?
            for dir in directories {
                let url = dir.appendingPathComponent("\(entry.name).app", isDirectory: true)
                if let c = InstalledCopy.read(url), c.bundleID == nil || c.bundleID == entry.id { copy = c; break }
            }
            if copy == nil, let app = discovered.first(where: { $0.id == entry.id })
                ?? discovered.first(where: { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }) {
                copy = InstalledCopy.read(app.bundleURL) ?? InstalledCopy(bundleURL: app.bundleURL, bundleID: app.id)
            }
            return CatalogAppStatus(entry: entry, installed: copy,
                                    running: copy.map { running($0.bundleID ?? entry.id, $0.bundleURL) } ?? false)
        }
    }
}

/// The app catalog: fetched from `catalog.url`, cached at `state/catalog.json` (so it is
/// there offline and at launch), refreshed every `refreshHours` and on demand.
@MainActor
final class AppCatalog {
    var config: () -> CatalogConfig
    let cacheURL: URL
    private(set) var document: CatalogDocument?
    /// When the cached copy was fetched (the cache file's modification date).
    private(set) var fetchedAt: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    var now: () -> Date = Date.init
    var onChange: (() -> Void)?
    private var waiting: [(String?) -> Void] = []
    private var timer: Timer?

    nonisolated static var defaultCacheURL: URL { LayoutStore.configDirectory.appendingPathComponent("state/catalog.json") }

    init(cacheURL: URL = AppCatalog.defaultCacheURL, config: @escaping () -> CatalogConfig) {
        self.cacheURL = cacheURL
        self.config = config
        loadCache()
    }

    var apps: [CatalogEntry] { document?.apps ?? [] }
    /// MacHUD's own entry.
    var umbrella: CatalogEntry? { apps.first(where: \.isUmbrella) }
    /// Everything MacHUD can install (not itself).
    var installable: [CatalogEntry] { apps.filter { !$0.isUmbrella } }

    func entry(matching key: String) -> CatalogEntry? {
        apps.first { $0.id == key } ?? apps.first { $0.matches(key) }
    }

    /// Resolves the entry's `icon`/`download` against the catalog URL when relative.
    func resolve(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        return config().catalogURL.flatMap { URL(string: raw, relativeTo: $0)?.absoluteURL }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL), let doc = try? CatalogDocument.decode(data) else { return }
        document = doc
        fetchedAt = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    var isStale: Bool {
        guard let fetchedAt else { return true }
        return now().timeIntervalSince(fetchedAt) >= config().refreshInterval
    }

    /// Fetches the catalog; `completion` gets the error, or nil. Concurrent calls share one fetch.
    func refresh(completion: ((String?) -> Void)? = nil) {
        if let completion { waiting.append(completion) }
        guard !isRefreshing else { return }
        let config = self.config()
        guard let url = config.catalogURL else {
            finish(.failure(CatalogError.noURL(config.url ?? ""))); return
        }
        isRefreshing = true
        onChange?()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("MacHUD", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Data, Error>
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { result = .failure(CatalogError.http(http.statusCode)) }
            else { result = .success(data ?? Data()) }
            let box = UncheckedBox(result)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(box.value) } }
        }.resume()
    }

    private func finish(_ result: Result<Data, Error>) {
        isRefreshing = false
        do {
            let data = try result.get()
            let doc = try CatalogDocument.decode(data)
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
            document = doc
            fetchedAt = now()
            lastError = nil
        } catch {
            let ns = error as NSError
            lastError = ns.domain == NSURLErrorDomain || ns.domain == NSCocoaErrorDomain ? "\(ns.localizedDescription) (\(config().catalogURL?.absoluteString ?? ""))" : "\(error)"
            NSLog("MacHUD: catalog refresh failed: %@", "\(error)")
        }
        let callbacks = waiting
        waiting = []
        onChange?()
        callbacks.forEach { $0(lastError) }
    }

    func refreshIfStale() { if isStale { refresh() } }

    /// Checks hourly whether the catalog is older than `refreshHours`; fetches now if it is.
    func start() {
        refreshIfStale()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["url": config().catalogURL?.absoluteString ?? "", "cache": cacheURL.path,
                                "refreshing": isRefreshing, "count": apps.count]
        if let fetchedAt { d["fetchedAt"] = ISO8601DateFormatter().string(from: fetchedAt) }
        if let updatedAt = document?.updatedAt { d["updatedAt"] = updatedAt }
        if let lastError { d["error"] = lastError }
        return d
    }
}
