import AppKit

/// The apps the bar can launch.
@MainActor
protocol AppSource: AnyObject {
    var apps: [AppEntry] { get }
    /// Rebuilds the list in the background when it is old; `apps` changes when that is done.
    func refreshIfStale()
}

/// Finds application bundles anywhere on the Mac (Spotlight).
@MainActor
protocol AppBundleFinding: AnyObject {
    /// Calls back once, on the main thread, with the bundles' paths, unless cancelled first.
    func find(_ done: @escaping ([String]) -> Void) -> SearchCancellable
}

/// The applications in /Applications, /System/Applications and ~/Applications (and their
/// subfolders, never inside a bundle), plus the application bundles Spotlight knows (a build
/// folder's app, Xcode's Simulator). Built in the background at launch and again on a show
/// once it is a minute old, so a newly installed app shows up the next time the bar opens. A
/// Spotlight gather that has not finished after `spotlightTimeout` is stopped; the folders'
/// apps (and Spotlight's from last time) stay, and a later show tries again.
@MainActor
final class AppIndex: AppSource {
    nonisolated static let defaultRoots: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    private(set) var apps: [AppEntry] = []
    private(set) var isBuilding = false
    var maxAge: TimeInterval = 60
    var spotlightTimeout: TimeInterval = 10
    private let roots: [URL]
    private let spotlight: AppBundleFinding?
    private var builtAt: Date?
    private var awaitingSpotlight = false
    private var finding: SearchCancellable?
    private var findTimer: Timer?

    init(roots: [URL] = AppIndex.defaultRoots, spotlight: AppBundleFinding? = SpotlightAppFinder()) {
        self.roots = roots
        self.spotlight = spotlight
    }

    func refreshIfStale() {
        guard !isBuilding, builtAt.map({ Date().timeIntervalSince($0) > maxAge }) ?? true else { return }
        refresh()
    }

    /// Scans the folders off the main thread and shows what they hold, then adds Spotlight's.
    func refresh() {
        isBuilding = true
        let roots = roots
        Self.queue.async {
            let folder = Self.scan(roots: roots)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The folders' apps now; the ones Spotlight added last time until it answers.
                    self.apps = Self.merge(folder, self.apps)
                    guard let spotlight = self.spotlight else { self.finish(folder); return }
                    self.gather(spotlight, folder: folder)
                }
            }
        }
    }

    private func gather(_ spotlight: AppBundleFinding, folder: [AppEntry]) {
        let roots = roots
        awaitingSpotlight = true
        findTimer = Timer.scheduledTimer(withTimeInterval: spotlightTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.giveUpOnSpotlight() }
        }
        finding = spotlight.find { [weak self] paths in
            guard let self, self.awaitingSpotlight else { return }
            self.stopGathering()
            Self.queue.async {
                let found = paths.filter { Self.includesSpotlightApp($0) }.map { path in
                    var entry = Self.entry(path)
                    entry.foundBySpotlight = !roots.contains { path.hasPrefix($0.path + "/") }
                    return entry
                }
                let merged = Self.merge(folder, found)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(merged) } }
            }
        }
    }

    private func giveUpOnSpotlight() {
        guard awaitingSpotlight else { return }
        finding?.cancel()
        stopGathering()
        NSLog("MacHUD: search bar: Spotlight listed no apps within %.0f s; keeping the folders' apps", spotlightTimeout)
        finish(apps)
    }

    private func stopGathering() {
        awaitingSpotlight = false
        finding = nil
        findTimer?.invalidate()
        findTimer = nil
    }

    private func finish(_ apps: [AppEntry]) {
        self.apps = apps
        builtAt = Date()
        isBuilding = false
    }

    private nonisolated static let queue = DispatchQueue(label: "machud.search.apps", qos: .userInitiated)

    // MARK: Pure parts

    /// The `.app` bundles under `roots`, descending into ordinary folders up to `maxDepth`
    /// levels but never into a bundle. Each path once, in the order found.
    nonisolated static func scan(roots: [URL], maxDepth: Int = 4) -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [AppEntry] = []
        func walk(_ dir: URL, _ depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    let path = normalize(item.path)
                    if seen.insert(path).inserted { out.append(entry(path)) }
                    continue
                }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                guard depth < maxDepth, values?.isDirectory == true, values?.isPackage != true else { continue }
                walk(item, depth + 1)
            }
        }
        for root in roots { walk(root, 1) }
        return out
    }

    /// The bundle at `path` as a row: Finder's name for it and its file name.
    nonisolated static func entry(_ path: String) -> AppEntry {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name = (name as NSString).deletingPathExtension }
        return AppEntry(path: path, name: name.isEmpty ? fileName : name, fileName: fileName, countKey: canonical(path))
    }

    /// The path as the bar keeps it: without the data volume's `/System/Volumes/Data` prefix
    /// (the same app Spotlight and Alfred sometimes name that way) or a trailing slash.
    nonisolated static func normalize(_ path: String) -> String {
        var p = path
        let data = "/System/Volumes/Data"
        if p.hasPrefix(data + "/") { p.removeFirst(data.count) }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// One key per app on disk however it is reached: /Applications/Safari.app is a link into
    /// a cryptex that Alfred names by its real path.
    nonisolated static func canonical(_ path: String) -> String {
        normalize(URL(fileURLWithPath: normalize(path)).resolvingSymlinksInPath().path)
    }

    /// Spotlight lists every bundle on the Mac: helpers inside apps, droplets and agents in
    /// /Library and /System/Library, packages' bundled tools, the Trash. The bar keeps the apps
    /// in the app folders and in your home folder outside ~/Library, hidden folders and
    /// `node_modules` (a build folder's app), each not inside another app, except Xcode's
    /// Developer/Applications (where Simulator lives).
    nonisolated static func includesSpotlightApp(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        guard path.lowercased().hasSuffix(".app"), !path.contains("/."), !path.contains("/node_modules/") else { return false }
        let inHome = path.hasPrefix(home + "/") && !path.hasPrefix(home + "/Library/")
        guard inHome || path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent.range(of: ".app/", options: .caseInsensitive) != nil else { return true }
        return parent.hasSuffix("/Contents/Developer/Applications")
    }

    /// `folder` as found, then the Spotlight entries that are not the same app.
    nonisolated static func merge(_ folder: [AppEntry], _ spotlight: [AppEntry]) -> [AppEntry] {
        var seen = Set(folder.map(\.path)).union(folder.map(\.countKey))
        var out = folder
        for e in spotlight where !seen.contains(e.path) && !seen.contains(e.countKey) {
            seen.insert(e.path)
            seen.insert(e.countKey)
            out.append(e)
        }
        return out
    }
}

/// Spotlight's application bundles on this Mac (`NSMetadataQuery`); an empty list if the query
/// cannot run.
@MainActor
final class SpotlightAppFinder: AppBundleFinding {
    nonisolated init() {}

    func find(_ done: @escaping ([String]) -> Void) -> SearchCancellable {
        let gather = Gather(done)
        gather.start()
        return gather
    }

    @MainActor
    final class Gather: SearchCancellable {
        private let query = NSMetadataQuery()
        private var done: (([String]) -> Void)?
        private var observer: NSObjectProtocol?

        init(_ done: @escaping ([String]) -> Void) {
            self.done = done
            query.predicate = NSPredicate(format: "%K == %@", "kMDItemContentType", "com.apple.application-bundle")
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
        }

        func start() {
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let done = self.done else { return }
                    self.query.disableUpdates()
                    let paths = (0..<self.query.resultCount).compactMap {
                        (self.query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                    }
                    self.cancel()
                    done(paths)
                }
            }
            if !query.start() {
                let done = self.done
                cancel()
                done?([])
            }
        }

        func cancel() {
            done = nil
            query.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
