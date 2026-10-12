import Foundation

/// A search in progress that can be stopped; a stopped one never calls back.
@MainActor
protocol SearchCancellable: AnyObject {
    func cancel()
}

/// Finds files by name for the bar's file rows.
@MainActor
protocol FileSearching: AnyObject {
    /// Calls back once, on the main thread, with up to `limit` files, unless cancelled first.
    func search(_ query: String, limit: Int, completion: @escaping ([FileHit]) -> Void) -> SearchCancellable
}

/// Spotlight (`NSMetadataQuery`) over the home folder, by display name, most recently used
/// first. Leaves out apps (the bar lists those itself), anything under ~/Library (mail, caches),
/// hidden files and folders, and packages' `node_modules`. Answers once Spotlight has gathered
/// its matches, once it has plenty, or after `timeout` with whatever it has by then.
@MainActor
final class SpotlightFileSearch: FileSearching {
    var timeout: TimeInterval = 1.5
    /// Enough to choose the best few by name from.
    static let gatherLimit = 60

    func search(_ query: String, limit: Int, completion: @escaping ([FileHit]) -> Void) -> SearchCancellable {
        let task = Query(query: query, limit: limit, timeout: timeout, completion: completion)
        task.start()
        return task
    }

    /// A `LIKE` pattern matching `query` anywhere: its own `*`, `?` and `\` are literal.
    nonisolated static func pattern(_ query: String) -> String {
        var escaped = ""
        for ch in query {
            if ch == "*" || ch == "?" || ch == "\\" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "*\(escaped)*"
    }

    /// Whether a file Spotlight found belongs in the bar.
    nonisolated static func keeps(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        if path.hasPrefix(home + "/Library/") { return false }
        return !path.contains("/.") && !path.contains("/node_modules/")
    }

    @MainActor
    final class Query: SearchCancellable {
        private let query = NSMetadataQuery()
        private let limit: Int
        private let timeout: TimeInterval
        private var completion: (([FileHit]) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var timer: Timer?

        init(query text: String, limit: Int, timeout: TimeInterval, completion: @escaping ([FileHit]) -> Void) {
            self.limit = limit
            self.timeout = timeout
            self.completion = completion
            query.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND NOT (%K == %@)",
                                          NSMetadataItemDisplayNameKey, SpotlightFileSearch.pattern(text),
                                          "kMDItemContentType", "com.apple.application-bundle")
            query.searchScopes = [NSMetadataQueryUserHomeScope]
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
            query.notificationBatchingInterval = 0.1
        }

        func start() {
            let center = NotificationCenter.default
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryGatheringProgress] {
                observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if note.name == .NSMetadataQueryDidFinishGathering || self.query.resultCount >= SpotlightFileSearch.gatherLimit {
                            self.finish()
                        }
                    }
                })
            }
            timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            if !query.start() { finish() }
        }

        private func finish() {
            guard let completion else { return }
            query.disableUpdates()
            let count = min(query.resultCount, SpotlightFileSearch.gatherLimit)
            var hits: [FileHit] = []
            for i in 0..<count {
                guard let item = query.result(at: i) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                      SpotlightFileSearch.keeps(path) else { continue }
                // The file's name, extension included (the display name may hide it).
                hits.append(FileHit(path: path, name: (path as NSString).lastPathComponent,
                                    lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
                if hits.count == limit { break }
            }
            stop()
            completion(hits)
        }

        func cancel() { stop() }

        private func stop() {
            completion = nil
            timer?.invalidate()
            timer = nil
            query.stop()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }
}
