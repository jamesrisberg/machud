import AppKit
import ApplicationServices

/// What macOS lets MacHUD do: Accessibility (move other apps' windows) and
/// Automation per target app (Apple Events for desktop switching, browser
/// windows, and opening a window in a freshly launched app).
@MainActor
enum Permissions {
    enum Status: String { case granted, denied, notAsked, notRunning, unknown }

    struct Target {
        let bundleID: String
        let name: String
        let why: String
        /// Safe to launch just to ask (System Events); browsers are only checked when running.
        let launchable: Bool
    }

    static let targets: [Target] = [
        Target(bundleID: "com.apple.systemevents", name: "System Events", why: "switch desktops for loadouts", launchable: true),
        Target(bundleID: "company.thebrowser.Browser", name: "Arc", why: "open and capture Arc windows", launchable: false),
        Target(bundleID: "com.apple.Safari", name: "Safari", why: "open and capture Safari windows", launchable: false),
    ]

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Current Automation status for `bundleID`; never prompts.
    static func automation(_ bundleID: String) -> Status {
        determine(bundleID, ask: false)
    }

    /// Ask macOS for Automation access to `bundleID` (shows the system prompt if
    /// it has not been answered yet). The target must be running for the prompt to appear.
    @discardableResult
    static func requestAutomation(_ bundleID: String) -> Status {
        determine(bundleID, ask: true)
    }

    private static func determine(_ bundleID: String, ask: Bool) -> Status {
        guard let desc = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return .unknown }
        var addr = desc.pointee
        let status = AEDeterminePermissionToAutomateTarget(&addr, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied              // errAEEventNotPermitted
        case -1744: return .notAsked            // errAEEventWouldRequireUserConsent
        case -600: return .notRunning           // procNotFound
        default: return .unknown
        }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    struct Report {
        var accessibility: Bool
        var automation: [(target: Target, status: Status)]

        var json: [String: Any] {
            ["ok": true, "accessibility": accessibility,
             "automation": automation.map { ["app": $0.target.name, "bundleID": $0.target.bundleID,
                                             "status": $0.status.rawValue, "for": $0.target.why] }]
        }
    }

    static func report() -> Report {
        Report(accessibility: accessibility,
               automation: targets.filter { isInstalled($0.bundleID) }.map { ($0, automation($0.bundleID)) })
    }

    /// Prompt for everything still missing. Launches System Events if needed;
    /// browsers are asked only when already running, so nothing pops open uninvited.
    static func requestAll() -> Report {
        if !accessibility { Accessibility.requestTrust() }
        for t in targets where isInstalled(t.bundleID) {
            if !isRunning(t.bundleID) {
                guard t.launchable, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) else { continue }
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                let deadline = Date().addingTimeInterval(3)
                while !isRunning(t.bundleID), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            }
            if automation(t.bundleID) != .granted { requestAutomation(t.bundleID) }
        }
        return report()
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    static func menuItems() -> [NSMenuItem] {
        let r = report()
        var lines: [String] = [r.accessibility ? "Accessibility: granted" : "Accessibility: missing"]
        for (t, s) in r.automation {
            let word: String
            switch s {
            case .granted: word = "granted"
            case .denied: word = "denied"
            case .notAsked: word = "not asked yet"
            case .notRunning: word = "app not running"
            case .unknown: word = "unknown"
            }
            lines.append("Automate \(t.name): \(word)")
        }
        let parent = NSMenuItem(title: r.accessibility ? "Permissions" : "⚠︎ Permissions", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !r.accessibility {
            let warn = NSMenuItem(title: "⚠︎ Grant Accessibility Access…", action: #selector(PermissionsMenuTarget.openAccessibility), keyEquivalent: "")
            warn.target = PermissionsMenuTarget.shared
            sub.addItem(warn)
            sub.addItem(.separator())
        }
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let ask = NSMenuItem(title: "Request Missing Permissions…", action: #selector(PermissionsMenuTarget.request), keyEquivalent: "")
        ask.target = PermissionsMenuTarget.shared
        sub.addItem(ask)
        let open = NSMenuItem(title: "Open Automation Settings", action: #selector(PermissionsMenuTarget.openSettings), keyEquivalent: "")
        open.target = PermissionsMenuTarget.shared
        sub.addItem(open)
        parent.submenu = sub
        return [parent]
    }
}

@MainActor
final class PermissionsMenuTarget: NSObject {
    @objc func openAccessibility() { Accessibility.openSettings() }
    static let shared = PermissionsMenuTarget()

    @objc func request() {
        let r = Permissions.requestAll()
        let missing = r.automation.filter { $0.status != .granted }.map { $0.target.name }
        let detail = missing.isEmpty ? "Everything MacHUD needs is granted."
            : "Still missing: \(missing.joined(separator: ", ")). Browsers are asked when they are running; System Settings › Privacy & Security › Automation lists what was answered."
        Toast.show(r.accessibility ? "Permissions checked" : "Accessibility is required", detail: detail, seconds: 5)
    }

    @objc func openSettings() { Permissions.openAutomationSettings() }
}
