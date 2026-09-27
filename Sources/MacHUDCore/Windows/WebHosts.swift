import AppKit

extension WebHost {
    /// Browsers that take a `--app=<url>` command line.
    static let chromiumBundleIDs: Set<String> = [
        "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta",
        "com.brave.browser", "com.brave.browser.nightly", "com.brave.browser.beta",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "org.chromium.chromium",
        "com.vivaldi.vivaldi", "com.operasoftware.opera",
    ]

    /// How MacHUD opens a window in a given browser, or nil for one it cannot drive.
    init?(browserBundleID id: String) {
        let key = id.lowercased()
        if let kind = BrowserWindow.Kind.allCases.first(where: { $0.bundleID.lowercased() == key }) {
            self = kind.host
        } else if WebHost.chromiumBundleIDs.contains(key) {
            self = .chromeApp
        } else {
            return nil
        }
    }

    /// The host a newly created web occupant should use: the configured browser
    /// when MacHUD can drive it, else the system's default browser, else a
    /// Chromium app-mode window (which falls back to the built-in panel at apply
    /// time if no Chromium is installed).
    static func preferred(configuredBrowser: String?, defaultHandler: String?) -> WebHost {
        for id in [configuredBrowser, defaultHandler] {
            guard let id, !id.isEmpty, let host = WebHost(browserBundleID: id) else { continue }
            return host
        }
        return .chromeApp
    }

    /// Which host actually opens a `.chromeApp` occupant. Configs may name Arc or
    /// Safari as the browser, and neither has an app mode worth using.
    static func chromeAppFallback(configuredBrowser: String?) -> WebHost? {
        guard let configuredBrowser, !configuredBrowser.isEmpty,
              let host = WebHost(browserBundleID: configuredBrowser), host != .chromeApp else { return nil }
        return host
    }

    var label: String {
        switch self {
        case .chromeApp: return "Chrome App"
        case .arc: return "Arc"
        case .safari: return "Safari"
        case .builtin: return "Built-in"
        }
    }
}

enum SystemDefaultBrowser {
    /// Bundle id of whatever opens `http://` links.
    static var bundleID: String? {
        guard let probe = URL(string: "http://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return Bundle(url: app)?.bundleIdentifier
    }
}
