import AppKit
import HUDKit

/// A MacHUD-aware app found on disk: its manifest and where its bundle lives.
struct ExternalApp: Equatable {
    var manifest: HUDManifest
    var bundleURL: URL

    var id: String { manifest.id }
    var name: String { manifest.name }
    var socketPath: String { manifest.socketPath }
}

extension HUDManifest {
    /// The panels MacHUD presents (hover and windowed), in manifest order. Widget types and
    /// kinds this MacHUD does not know are never registered, shown or placed as panels.
    var presentedPanels: [Panel] { panels.filter(\.kind.isDockKind) }

    /// The symbol that stands for the app in menus: its first presented panel's, else its
    /// first widget's, else the manifest's icon.
    var appSymbol: String {
        presentedPanels.first?.symbol ?? widgetPanels.first?.symbol ?? iconName ?? "app"
    }
}

/// `"apps"` in layouts.json: where to look for MacHUD-aware apps, which to keep running,
/// and (keyed by bundle id) where each one goes when MacHUD launches it.
///
/// ```json
/// "apps": {"searchPaths": ["~/dev/*/build"], "autoLaunch": ["xyz.viawormhole.wormhole"],
///          "known": ["/tmp/demo/build/Demo.app"],
///          "xyz.machud.sift": {"placement": {"region": "left"}},
///          "JER.wormhole": {"placement": {"mode": "parked", "edge": "right"}}}
/// ```
struct AppsConfig: Codable, Equatable {
    /// Extra directories searched after /Applications and ~/Applications. `~` and glob
    /// patterns (`*`, `?`, `[...]`) are expanded, so dev builds can be included.
    var searchPaths: [String]?
    /// Bundle ids MacHUD launches at startup and relaunches (with backoff) if they quit
    /// unexpectedly.
    var autoLaunch: [String]?
    /// false to skip /Applications and ~/Applications (isolated test instances).
    var standardDirectories: Bool?
    /// Bundles announced with `apps announce path=` (by `hud-build.sh` after a build, or by
    /// the app itself at launch), found even outside the search directories. Deduplicated;
    /// a bundle that is gone is dropped at the next rescan.
    var known: [String]?
    /// Per-app settings, keyed by bundle id (any key other than the ones above).
    var perApp: [String: AppEntryConfig]

    init(searchPaths: [String]? = nil, autoLaunch: [String]? = nil, standardDirectories: Bool? = nil,
         known: [String]? = nil, perApp: [String: AppEntryConfig] = [:]) {
        self.searchPaths = searchPaths
        self.autoLaunch = autoLaunch
        self.standardDirectories = standardDirectories
        self.known = known
        self.perApp = perApp
    }

    func placement(for appID: String) -> AppPlacement? { perApp[appID]?.placement }

    /// Apps whose `"dock": false` keeps them off the tool dock.
    var hiddenFromDock: Set<String> { Set(perApp.filter { $0.value.dock == false }.map(\.key)) }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let searchPaths = Key("searchPaths"), autoLaunch = Key("autoLaunch")
        static let standardDirectories = Key("standardDirectories"), known = Key("known")
        static let reserved: Set<String> = ["searchPaths", "autoLaunch", "standardDirectories", "known"]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        searchPaths = try c.decodeIfPresent([String].self, forKey: .searchPaths)
        autoLaunch = try c.decodeIfPresent([String].self, forKey: .autoLaunch).map { ids in
            var seen: Set<String> = []
            return ids.filter { seen.insert($0).inserted }
        }
        standardDirectories = try c.decodeIfPresent(Bool.self, forKey: .standardDirectories)
        known = try c.decodeIfPresent([String].self, forKey: .known)
        var perApp: [String: AppEntryConfig] = [:]
        for key in c.allKeys where !Key.reserved.contains(key.stringValue) {
            perApp[key.stringValue] = try c.decode(AppEntryConfig.self, forKey: key)
        }
        self.perApp = perApp
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encodeIfPresent(searchPaths, forKey: .searchPaths)
        try c.encodeIfPresent(autoLaunch, forKey: .autoLaunch)
        try c.encodeIfPresent(standardDirectories, forKey: .standardDirectories)
        try c.encodeIfPresent(known, forKey: .known)
        for (id, entry) in perApp.sorted(by: { $0.key < $1.key }) { try c.encode(entry, forKey: Key(id)) }
    }
}

/// `"apps": {"<bundle id>": {...}}`.
struct AppEntryConfig: Codable, Equatable {
    /// Where the app's panel goes when MacHUD launches the app (`apps launch`,
    /// `autoLaunch`). Loadouts place it themselves and ignore this.
    var placement: AppPlacement?
    /// false keeps the app off the tool dock (the status menu still lists it).
    var dock: Bool?
}

/// A sibling app's default placement: parked at an edge, or in a region of a layout
/// (optionally parked from there).
///
/// ```json
/// {"mode": "parked", "edge": "right", "peek": 12}
/// {"region": "left", "layout": "Halves"}
/// {"region": "right", "mode": "parked", "edge": "right"}
/// ```
struct AppPlacement: Codable, Equatable {
    /// Absent means `parked` when there is no region, `placed` when there is.
    var mode: SlotMode?
    /// Parking edge (default: left without a region, the region's nearest edge with one).
    var edge: HUDEdge?
    var peek: Double?
    /// Region id or name in `layout`.
    var region: String?
    /// Layout name; absent means the active layout.
    var layout: String?
    /// Which of the app's panels (default: its first).
    var panel: String?

    var isParked: Bool { (mode ?? (region == nil ? .parked : .placed)) == .parked }

    /// Rest frame for a placement without a region: the panel's default size against
    /// `edge` of `visible`, centred along it, shrunk to fit.
    static func restFrame(size: CGSize, edge: HUDEdge, visible: CGRect) -> CGRect {
        let w = min(size.width, visible.width), h = min(size.height, visible.height)
        let x: CGFloat, y: CGFloat
        switch edge {
        case .left: x = visible.minX; y = visible.midY - h / 2
        case .right: x = visible.maxX - w; y = visible.midY - h / 2
        case .top: x = visible.midX - w / 2; y = visible.maxY - h
        case .bottom: x = visible.midX - w / 2; y = visible.minY
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(.down), height: h.rounded(.down))
    }

    /// The region this placement names, looked up by id then name (case-insensitive).
    static func region(_ key: String, in layout: Layout) -> Region? {
        layout.regions.first { $0.id == key }
            ?? layout.regions.first { $0.name?.caseInsensitiveCompare(key) == .orderedSame }
    }
}

/// Finds the MacHUD-aware apps MacHUD can drive.
enum ExternalAppCatalog {
    /// The bundle id MacHUD ships with (`Info.plist`, `machud.json`).
    static let ownBundleID = "com.jrisberg.machud"

    /// Ids that name MacHUD itself; its own manifest is found in /Applications too.
    static var ownIDs: Set<String> {
        var ids: Set<String> = [ownBundleID]
        if let bundle = Bundle.main.bundleIdentifier { ids.insert(bundle) }
        if let own = HUDManifest.main?.id { ids.insert(own) }
        return ids
    }

    struct Result {
        var apps: [ExternalApp]
        var failures: [HUDManifestScanner.Failure]
        /// Ids declared by more than one bundle: every bundle, the one in use first.
        var duplicates: [String: [URL]] = [:]
        /// `known` entries whose bundle (or its machud.json) is gone.
        var vanished: [String] = []
    }

    /// The bundles of the running instances of an app.
    static func runningBundleURLs(_ id: String) -> [URL] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { !$0.isTerminated }.compactMap(\.bundleURL)
    }

    /// Finds the apps in the standard directories, `searchPaths` and `known` bundles. When
    /// several bundles declare one id (an installed copy and a dev build), the bundle of the
    /// running instance wins, else the most recently modified one, else the first found.
    static func discover(_ config: AppsConfig, excluding own: Set<String> = ownIDs,
                         running: (String) -> [URL] = runningBundleURLs) -> Result {
        let extra = (config.searchPaths ?? []).flatMap(expand)
        var present: [URL] = [], vanished: [String] = []
        for path in config.known ?? [] {
            let bundle = bundleURL(path)
            if FileManager.default.fileExists(atPath: HUDManifest.manifestURL(inBundleAt: bundle).path) {
                present.append(bundle)
            } else {
                vanished.append(path)
            }
        }
        let scanner = HUDManifestScanner(extraDirectories: extra,
                                         includeStandard: config.standardDirectories ?? true, bundles: present)
        let report = scanner.scanReport(keepingDuplicates: true)
        var order: [String] = []
        var byID: [String: [HUDManifestScanner.Entry]] = [:]
        for entry in report.entries where !own.contains(entry.manifest.id) {
            if byID[entry.manifest.id] == nil { order.append(entry.manifest.id) }
            byID[entry.manifest.id, default: []].append(entry)
        }
        var apps: [ExternalApp] = [], duplicates: [String: [URL]] = [:]
        for id in order {
            let entries = byID[id] ?? []
            let winner = preferred(entries.map(\.bundleURL), running: running(id))
            apps.append(ExternalApp(manifest: entries[winner].manifest, bundleURL: entries[winner].bundleURL))
            if entries.count > 1 {
                var urls = entries.map(\.bundleURL)
                urls.insert(urls.remove(at: winner), at: 0)
                duplicates[id] = urls
            }
        }
        return Result(apps: apps, failures: report.failures, duplicates: duplicates, vanished: vanished)
    }

    /// Index of the bundle to use among several declaring one id: a running instance's
    /// bundle, else the most recently modified, else the first (search order).
    static func preferred(_ bundles: [URL], running: [URL]) -> Int {
        let live = Set(running.map(canonicalPath))
        if let i = bundles.firstIndex(where: { live.contains(canonicalPath($0)) }) { return i }
        var best = 0, bestDate = modified(bundles[0])
        for i in bundles.indices.dropFirst() {
            let date = modified(bundles[i])
            if date > bestDate { best = i; bestDate = date }
        }
        return best
    }

    /// When a bundle was last built or installed: the newest of the bundle directory, its
    /// Info.plist and its machud.json (a build rewrites all three).
    static func modified(_ bundle: URL) -> Date {
        let fm = FileManager.default
        return [bundle.path, bundle.appendingPathComponent("Contents/Info.plist").path,
                HUDManifest.manifestURL(inBundleAt: bundle).path]
            .compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            .max() ?? .distantPast
    }

    /// `path` with `~` expanded, as a file URL.
    static func bundleURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// For comparing bundle paths: symlinks resolved (`/tmp` is `/private/tmp`), no trailing slash.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Directories whose entries decide what `discover` finds, for the watcher: the standard
    /// ones, every search path (and, for a glob, the directory above its first wildcard, so a
    /// new match is seen), and the folder holding each known bundle (so a rebuilt one is seen).
    static func watchedDirectories(_ config: AppsConfig) -> [URL] {
        var dirs = (config.standardDirectories ?? true) ? HUDManifestScanner.standardDirectories : []
        for pattern in config.searchPaths ?? [] {
            dirs += expand(pattern)
            let path = (pattern as NSString).expandingTildeInPath
            if path.contains(where: { "*?[".contains($0) }) {
                let fixed = path.split(separator: "/", omittingEmptySubsequences: false)
                    .prefix { !$0.contains(where: { "*?[".contains($0) }) }.joined(separator: "/")
                if !fixed.isEmpty { dirs.append(URL(fileURLWithPath: fixed, isDirectory: true)) }
            }
        }
        dirs += (config.known ?? []).map { bundleURL($0).deletingLastPathComponent() }
        var seen: Set<String> = []
        return dirs.filter { seen.insert(canonicalPath($0)).inserted }
    }

    /// `~` expansion plus glob matching; a pattern that matches nothing yields nothing.
    static func expand(_ pattern: String) -> [URL] {
        let path = (pattern as NSString).expandingTildeInPath
        guard path.contains(where: { "*?[".contains($0) }) else {
            return [URL(fileURLWithPath: path, isDirectory: true)]
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, GLOB_TILDE | GLOB_BRACE, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { i in
            g.gl_pathv[i].map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        }.sorted { $0.path < $1.path }
    }
}
