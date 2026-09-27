import AppKit
import HUDKit

/// Keeps `host.json` (HUDKit's `HUDMenuHost`) saying whether this MacHUD hosts the sibling
/// apps' menus, so their `HUDStatusItemPolicy` hides or shows their own status items: written
/// at launch and every `refreshInterval`, rewritten when `menuBar.consumeSiblings` changes,
/// removed on quit (only if it is still ours).
@MainActor
final class MenuHostPublisher {
    static let refreshInterval: TimeInterval = 60

    /// `MACHUD_HOST_FILE`, else `host.json` beside an isolated
    /// instance's `MACHUD_CONFIG`, else `<socket>.host.json` beside its `MACHUD_SOCKET`, else
    /// the shared `HUDMenuHost.defaultURL`: an isolated instance never tells the real
    /// siblings to hide their icons.
    nonisolated static var fileURL: URL {
        if let path = Env.value("HOST_FILE"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let config = Env.configURL { return config.deletingLastPathComponent().appendingPathComponent("host.json") }
        if let socket = Env.socketPath, !socket.isEmpty {
            return URL(fileURLWithPath: (socket as NSString).expandingTildeInPath + ".host.json")
        }
        return HUDMenuHost.defaultURL
    }

    let url: URL
    let bundleID: String
    let pid: Int32
    private(set) var hostsMenus = false
    private(set) var isPublished = false
    private var timer: Timer?

    init(url: URL = MenuHostPublisher.fileURL,
         bundleID: String = Bundle.main.bundleIdentifier ?? ExternalAppCatalog.ownBundleID,
         pid: Int32 = getpid()) {
        self.url = url
        self.bundleID = bundleID
        self.pid = pid
    }

    /// Publishes now with `hostsMenus` and keeps refreshing it.
    func start(hostsMenus: Bool) {
        self.hostsMenus = hostsMenus
        write()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }
        timer?.tolerance = 5
    }

    /// Follows a config change; writes only when the flag changed.
    func update(hostsMenus: Bool) {
        guard hostsMenus != self.hostsMenus || !isPublished else { return }
        self.hostsMenus = hostsMenus
        write()
    }

    /// Removes the file (quit). The siblings see it vanish and show their icons again.
    func withdraw() {
        timer?.invalidate()
        timer = nil
        HUDMenuHost.remove(at: url, ifOwnedBy: pid)
        isPublished = false
    }

    func write() {
        do {
            try HUDMenuHost(pid: pid, bundleID: bundleID, hostsMenus: hostsMenus).write(to: url)
            isPublished = true
        } catch {
            NSLog("MacHUD: could not write %@: %@", url.path, "\(error)")
        }
    }

    var json: [String: Any] {
        ["file": url.path, "hostsMenus": hostsMenus, "published": isPublished]
    }
}
