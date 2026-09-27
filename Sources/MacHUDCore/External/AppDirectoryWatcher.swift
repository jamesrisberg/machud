import Foundation

/// Watches the directories MacHUD finds apps in (`ExternalAppCatalog.watchedDirectories`) and
/// calls `onChange` once things settle, so a new or replaced `.app` gets its dock button
/// without an `apps rescan`. A `DispatchSource` per directory sees entries added, removed or
/// renamed in it (an install, a `hud-build.sh` rebuild), debounced by `debounce` seconds.
@MainActor
final class AppDirectoryWatcher {
    let debounce: TimeInterval
    var onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?

    init(debounce: TimeInterval = 1, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    /// The directories currently watched.
    var watched: [String] { sources.keys.sorted() }

    /// Watches exactly `directories` (missing ones are skipped until a later call finds them).
    /// A directory that was deleted or renamed is watched afresh.
    func watch(_ directories: [URL]) {
        let wanted = Set(directories.map(\.path))
        for (path, source) in sources where !wanted.contains(path) || !FileManager.default.fileExists(atPath: path) {
            source.cancel()
            sources[path] = nil
        }
        for path in wanted where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                   eventMask: [.write, .rename, .delete, .link],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
    }

    private func changed() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.onChange()
            }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    deinit {
        for source in sources.values { source.cancel() }
    }
}
