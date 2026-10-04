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

    /// Where an isolated instance keeps its `layouts.json` (and the state and files beside it):
    /// `MACHUD_CONFIG`, else `<socket path without extension>-config/layouts.json` beside its
    /// `MACHUD_SOCKET`, as the voice socket and the diagnostics folder sit beside it. nil for the
    /// real instance, which keeps its config under the home folder. An instance started with
    /// only a socket must never read or save the real one's.
    static var configURL: URL? { configURL(in: ProcessInfo.processInfo.environment) }
    static func configURL(in environment: [String: String]) -> URL? {
        if let config = value("CONFIG", in: environment) {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
        }
        guard let socket = value("SOCKET", in: environment), !socket.isEmpty else { return nil }
        return URL(fileURLWithPath: (socket as NSString).deletingPathExtension + "-config", isDirectory: true)
            .appendingPathComponent("layouts.json")
    }
    static var socketPath: String? { value("SOCKET") }
    static var noHotkeys: Bool { value("NO_HOTKEYS") != nil }

    /// A side-by-side dev/test instance (its own socket or config): it leaves the default
    /// instance's contract socket and permission prompts alone.
    static var isIsolated: Bool { isIsolated(in: ProcessInfo.processInfo.environment) }
    static func isIsolated(in environment: [String: String]) -> Bool {
        value("SOCKET", in: environment) != nil || value("CONFIG", in: environment) != nil
    }
    /// Act on the user's windows and apps without being asked: apply `startupLoadout` at
    /// launch, re-apply the active loadout when displays change, and launch (and relaunch)
    /// the `apps.autoLaunch` siblings with their default placement. An isolated instance
    /// still moves real windows through Accessibility, so it does none of this unless
    /// `MACHUD_APPLY_STARTUP=1`.
    static var autoApply: Bool { autoApply(in: ProcessInfo.processInfo.environment) }
    static func autoApply(in environment: [String: String]) -> Bool {
        !isIsolated(in: environment) || value("APPLY_STARTUP", in: environment) == "1"
    }
    /// Watch window drags for snapping. An isolated instance (`MACHUD_NO_HOTKEYS`) leaves
    /// global drags to the real one unless `MACHUD_DRAG=1`: two instances watching the
    /// same drag both react to it (an instance with an empty test config would offer to open
    /// its editor).
    static var dragMonitor: Bool { !noHotkeys || value("DRAG") != nil }
}
