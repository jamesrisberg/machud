import AppKit
import HUDKit

/// The live sources behind `diagnose`: the window server, AppKit, the displays and desktops, and
/// the apps MacHUD supervises. Reading is all it does.
@MainActor
enum DiagnoseLive {
    /// The service wired to the running app. `externals` names the sibling apps and their pids,
    /// `voice` the voice host's pid and replies.
    static func service(externals: ExternalPanels, toolDock: ToolDock, widgets: WidgetLayer, voice: VoiceServices) -> DiagnoseService {
        func unavailable(_ what: String) -> [String: Any] { ["ok": false, "error": "\(what) is gone"] }
        let sources: [String: DiagnoseService.Source] = [
            "tooldock": { [weak toolDock] done in done(toolDock?.handle(["action": "state"]) ?? unavailable("the tool dock")) },
            "widgets": { [weak widgets] done in
                guard let widgets else { done(unavailable("the widget layer")); return }
                widgets.handle(["action": "list"], done: done)
            },
            "voiceStatus": { [weak voice] done in done(voice?.statusJSON ?? unavailable("the voice service")) },
            "voiceState": { [weak voice] done in
                guard let voice else { done(unavailable("the voice service")); return }
                voice.perform(.forward("state", [:]), done: done)
            },
        ]
        return DiagnoseService(
            sources: sources,
            providers: { [weak externals, weak voice] replies in providers(externals: externals, voice: voice, replies: replies) },
            store: DiagnoseStore(directory: DiagnoseStore.directory()))
    }

    static func providers(externals: ExternalPanels?, voice: VoiceServices?,
                          replies: [String: [String: Any]]) -> DiagnoseSnapshot.Providers {
        DiagnoseSnapshot.Providers(
            now: Date.init, machud: machud, displays: displays, frontmost: frontmost,
            processes: { processes(externals: externals, voice: voice) },
            serverWindows: serverWindows,
            // Read-only `CGSCopySpacesForWindows`; nil when the private symbol is missing.
            spaces: { AllSpacesWindows.spaceIDs($0) },
            appKitWindows: appKitWindows, replies: replies)
    }

    static func machud() -> DiagnoseSnapshot.Machud {
        let info = Bundle.main.infoDictionary
        return .init(version: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                     build: info?["CFBundleVersion"] as? String, pid: getpid(), launchedAt: processStart(pid: getpid()),
                     isolated: Env.isIsolated)
    }

    /// When the process started, from the kernel's process table.
    static func processStart(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// Each attached display with its desktops. The desktop list comes from `com.apple.spaces`,
    /// which the Dock rewrites as desktops change; which one is showing is read live.
    static func displays() -> [DiagnoseSnapshot.Display] {
        let plist = Spaces.readDomain("com.apple.spaces")
        let monitors = plist.map { Spaces.monitors(from: $0) } ?? []
        let fullScreen = plist.map(fullScreenSpaceIDs(in:)) ?? [:]
        return NSScreen.screens.map { screen in
            let monitor = Spaces.monitor(for: screen, in: monitors)
            return DiagnoseSnapshot.Display(
                name: screen.localizedName, displayID: screen.displayID, persistentID: screen.persistentID,
                isPrimary: screen.displayID == CGMainDisplayID(), frame: screen.frame, visibleFrame: screen.visibleFrame,
                spaceIdentifier: monitor?.identifier, spaceIDs: monitor?.spaceIDs ?? [], currentSpaceID: monitor?.currentSpaceID,
                fullScreenSpaceIDs: monitor.flatMap { fullScreen[$0.identifier] } ?? [])
        }
    }

    /// `ManagedSpaceID`s of full-screen apps' desktops (`type` 4) per display identifier in a
    /// decoded `com.apple.spaces` plist.
    static func fullScreenSpaceIDs(in plist: [String: Any]) -> [String: [UInt64]] {
        let monitors = ((plist["SpacesDisplayConfiguration"] as? [String: Any])?["Management Data"] as? [String: Any])?["Monitors"]
            as? [[String: Any]] ?? []
        var out: [String: [UInt64]] = [:]
        for monitor in monitors {
            guard let identifier = monitor["Display Identifier"] as? String, let spaces = monitor["Spaces"] as? [[String: Any]] else { continue }
            let ids = spaces.compactMap { space -> UInt64? in
                guard (space["type"] as? NSNumber)?.intValue == 4 else { return nil }
                return (space["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (space["id64"] as? NSNumber)?.uint64Value
            }
            if !ids.isEmpty { out[identifier] = ids }
        }
        return out
    }

    static func frontmost() -> DiagnoseSnapshot.App? {
        NSWorkspace.shared.frontmostApplication.map {
            .init(name: $0.localizedName ?? $0.bundleIdentifier ?? "unknown", pid: $0.processIdentifier)
        }
    }

    struct RunningApp: Equatable {
        var bundleID: String?
        var name: String
        var pid: Int32
    }

    /// The bundle identifier prefix of the MacHUD family's apps.
    static let familyBundlePrefix = "xyz.machud."

    /// MacHUD, its voice helper while it runs, the apps MacHUD discovered, and every other running
    /// application of the family (`xyz.machud.*`), once each by pid: a family app outside MacHUD's
    /// search paths is still one whose windows matter.
    static func familyProcesses(ownPID: Int32, ownBundleID: String?, voicePID: Int32?, discovered: [DiagnoseSnapshot.FamilyProcess],
                                running: [RunningApp]) -> [DiagnoseSnapshot.FamilyProcess] {
        var out = [DiagnoseSnapshot.FamilyProcess(role: .machud, name: "MacHUD", bundleID: ownBundleID, pid: ownPID)]
        if let voicePID, voicePID != ownPID { out.append(.init(role: .voiceHost, name: "MacHUDVoice", bundleID: nil, pid: voicePID)) }
        for process in discovered where !out.contains(where: { $0.pid == process.pid }) { out.append(process) }
        for app in running where app.bundleID?.hasPrefix(familyBundlePrefix) == true && !out.contains(where: { $0.pid == app.pid }) {
            out.append(.init(role: .sibling, name: app.name, bundleID: app.bundleID, pid: app.pid))
        }
        return out
    }

    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "unknown", pid: $0.processIdentifier)
        }
    }

    static func processes(externals: ExternalPanels?, voice: VoiceServices?,
                          running: (() -> [RunningApp])? = nil) -> [DiagnoseSnapshot.FamilyProcess] {
        var discovered: [DiagnoseSnapshot.FamilyProcess] = []
        if let supervisor = externals?.supervisor {
            for record in supervisor.all {
                // What the app itself reports: a hover panel shown and not parked.
                let hover = Set(record.app.manifest.presentedPanels.filter { $0.kind == .hover }.map(\.id))
                let shown = record.panels.contains { hover.contains($0.key) && $0.value.visible && $0.value.mode != .parked }
                for pid in supervisor.livePIDs(record.app.id) {
                    discovered.append(.init(role: .sibling, name: record.app.name, bundleID: record.app.id, pid: pid, showsHoverPanel: shown))
                }
            }
        }
        return familyProcesses(ownPID: getpid(), ownBundleID: Bundle.main.bundleIdentifier, voicePID: voice?.supervisor.pid,
                               discovered: discovered, running: running?() ?? runningApps())
    }

    /// Every window the window server lists, on every desktop and ordered out ones included.
    /// Desktop-level windows (the widgets) are in `.optionAll`; a title is never read.
    static func serverWindows() -> [DiagnoseSnapshot.ServerWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        return raw.compactMap { DiagnoseSnapshot.ServerWindow(info: $0, primaryHeight: primaryHeight) }
    }

    static func appKitWindows() -> [DiagnoseSnapshot.AppKitWindow] {
        NSApplication.shared.windows.map { window in
            DiagnoseSnapshot.AppKitWindow(
                number: window.windowNumber, identifier: window.identifier?.rawValue, title: window.title,
                className: String(describing: type(of: window)), isVisible: window.isVisible,
                isOnActiveSpace: window.isOnActiveSpace, alpha: Double(window.alphaValue), level: window.level.rawValue,
                collectionBehavior: window.collectionBehavior.rawValue, frame: window.frame)
        }
    }
}
