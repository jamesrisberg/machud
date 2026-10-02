import AppKit
import HUDKit

/// One running process of a sibling app: when it started and the bundle it runs from.
struct AppProcess: Equatable {
    var pid: pid_t
    var launchDate: Date?
    var bundleURL: URL?
    var executableURL: URL?
}

/// What an app said about itself in `hello`.
struct AppHello: Equatable {
    /// The HUDKit contract it was built against (`hudkit`).
    var contract: String?
    /// Its own version (`version`, its bundle's `CFBundleShortVersionString` when it started).
    var version: String?

    init(contract: String? = nil, version: String? = nil) {
        self.contract = contract
        self.version = version
    }

    init(reply: [String: Any]) {
        contract = reply["hudkit"] as? String
        version = reply["version"] as? String
    }
}

/// Whether a running app is behind: its build on disk or the contract MacHUD speaks. Pure,
/// so it is unit tested; `AppSupervisor.buildStatus` gathers the inputs.
struct AppBuildStatus: Equatable {
    /// Why the running process is older than its bundle on disk; nil when it is not.
    var outdated: String?
    /// The app's and MacHUD's contract, when the app said `hello`.
    var contract: Contract?
    /// Another bundle declaring the same id with a newer build than the one running.
    /// Informational: a relaunch restarts the bundle the app runs from.
    var newerCopy: Copy?

    struct Copy: Equatable {
        var path: String
        var version: String?
        var built: Date
    }

    /// Contracts as `major.minor`; `older` when the app's is behind MacHUD's.
    struct Contract: Equatable {
        var app: String
        var machud: String
        var older: Bool
    }

    /// A build finishing within this of the launch counts as the build that launched.
    static let tolerance: TimeInterval = 2

    /// - Parameters:
    ///   - launched: when the oldest running process started.
    ///   - built: when the executable it runs from was last written.
    ///   - running: the version the process reported in `hello`.
    ///   - onDisk: the bundle's `CFBundleShortVersionString` now.
    static func outdatedReason(launched: Date?, built: Date?, running: String?, onDisk: String?) -> String? {
        var reasons: [String] = []
        if let running, let onDisk, running != onDisk {
            reasons.append("running \(running), \(onDisk) on disk")
        }
        if let launched, let built, built.timeIntervalSince(launched) > tolerance {
            reasons.append("rebuilt after it started")
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    /// `major.minor` of a version string (`"0.2.1"` → `"0.2"`), nil unless it starts with two numbers.
    static func minor(_ version: String) -> (Int, Int)? {
        let parts = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return nil }
        return (major, minor)
    }

    /// Compares contracts by `major.minor`: a patch adds no contract. nil when either is unreadable.
    static func contract(app: String, machud: String) -> Contract? {
        guard let a = minor(app), let m = minor(machud) else { return nil }
        return Contract(app: "\(a.0).\(a.1)", machud: "\(m.0).\(m.1)", older: a < m)
    }

    nonisolated(unsafe) static let dateFormat = ISO8601DateFormatter()

    var json: [String: Any] {
        var d: [String: Any] = ["outdated": outdated != nil]
        if let outdated { d["outdatedReason"] = outdated }
        if let contract { d["contract"] = ["app": contract.app, "machud": contract.machud, "older": contract.older] }
        if let newerCopy {
            d["newerCopy"] = newerCopy.path
            d["newerCopyBuilt"] = Self.dateFormat.string(from: newerCopy.built)
            if let version = newerCopy.version { d["newerCopyVersion"] = version }
        }
        return d
    }
}

/// Where a panel MacHUD showed actually is, judged from its app's windows.
enum ShowOutcome: Equatable {
    case onScreen
    /// `"another desktop"` or `"off screen"`.
    case elsewhere(String)

    static let anotherDesktop = ShowOutcome.elsewhere("another desktop")
    static let offScreen = ShowOutcome.elsewhere("off screen")

    var isOnScreen: Bool { self == .onScreen }
}

/// The window server's view of one app's windows, for show verification.
enum WindowPresence {
    struct Window: Equatable {
        /// Cocoa screen coordinates.
        var frame: CGRect
        /// Ordered in on a desktop that is showing now.
        var onScreen: Bool
        /// How many desktops it is on (0: ordered out); nil when the private call is unavailable.
        var spaces: Int?
    }

    /// Any window on screen and over a display wins; else one on another desktop; else the
    /// panel is off screen (ordered out, or placed beyond every display).
    static func classify(_ windows: [Window], screens: [CGRect]) -> ShowOutcome {
        if windows.contains(where: { w in w.onScreen && screens.contains { $0.intersects(w.frame) } }) { return .onScreen }
        if windows.contains(where: { !$0.onScreen && ($0.spaces ?? 0) > 0 }) { return .anotherDesktop }
        return .offScreen
    }

    /// The windows of `pids` at or above the normal layer (a widget on the desktop layer or a
    /// status item does not count as a shown panel), minus slivers and invisible ones.
    static func windows(pids: Set<pid_t>) -> [Window] {
        guard !pids.isEmpty,
              let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        return raw.compactMap { info -> Window? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let number = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowLayer as String] as? Int ?? 0) >= 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  b.width >= WindowList.minimumSize.width, b.height >= WindowList.minimumSize.height,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            return Window(frame: CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height),
                          onScreen: onScreen, spaces: onScreen ? nil : AllSpacesWindows.spaceCount(number))
        }
    }

    /// Where the app's panel is now; nil without a process to look at.
    @MainActor
    static func probe(_ pids: Set<pid_t>) -> ShowOutcome? {
        guard !pids.isEmpty else { return nil }
        return classify(windows(pids: pids), screens: NSScreen.screens.map(\.frame))
    }
}
