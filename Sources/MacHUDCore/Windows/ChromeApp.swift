import AppKit

/// Chromium app-mode windows: a page in its own chromeless window, launched by
/// running the browser executable directly with `--app=<url>`.
enum ChromeApp {
    struct Browser {
        var bundleID: String
        var executable: URL
    }

    /// Browsers tried when the configured one is missing, best first. Arc is not
    /// here: it has no usable app mode, so `WebHost.arc` drives it instead.
    static let knownBundleIDs = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.Chromium",
    ]

    static func resolve(preferred: String?) -> Browser? {
        var ids = knownBundleIDs
        if let preferred, !preferred.isEmpty { ids = [preferred] + ids.filter { $0 != preferred } }
        for id in ids {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                  let executable = Bundle(url: appURL)?.executableURL,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            return Browser(bundleID: id, executable: executable)
        }
        return nil
    }

    /// Start an app-mode window. When the browser is already running its singleton
    /// lock forwards the command line to it and this process exits immediately.
    @discardableResult
    static func open(url: String, browser: Browser) -> Bool {
        let process = Process()
        process.executableURL = browser.executable
        process.arguments = ["--app=\(url)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            NSLog("MacHUD: could not run %@: %@", browser.executable.path, "\(error)")
            return false
        }
    }
}
