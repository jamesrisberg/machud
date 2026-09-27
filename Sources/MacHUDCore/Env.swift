import Foundation

/// Environment overrides, mainly so several instances can run side by side
/// during development/testing without fighting over the socket, config or hotkeys.
/// Each variable is `MACHUD_<NAME>`.
enum Env {
    static let prefix = "MACHUD_"

    /// `MACHUD_<name>`, else nil.
    static func value(_ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[prefix + name]
    }

    static var configURL: URL? {
        value("CONFIG").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
    static var socketPath: String? { value("SOCKET") }
    static var noHotkeys: Bool { value("NO_HOTKEYS") != nil }

    /// A side-by-side dev/test instance (its own socket or config): it leaves the default
    /// instance's contract socket and permission prompts alone.
    static var isIsolated: Bool { socketPath != nil || configURL != nil }
    /// Watch window drags for snapping. An isolated instance (`MACHUD_NO_HOTKEYS`) leaves
    /// global drags to the real one unless `MACHUD_DRAG=1`: two instances watching the
    /// same drag both react to it (an empty test config used to open its editor).
    static var dragMonitor: Bool { !noHotkeys || value("DRAG") != nil }
}
