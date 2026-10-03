import AppKit
import Foundation

/// Where the window server and AppKit say every MacHUD-family window is, as one JSON document
/// with a short list of what looks wrong. A relaunch clears a vanished window and the evidence
/// with it, so `diagnose` saves this first.
///
/// Everything is read through `Providers`, so the builder is a pure function and its tests need
/// no live windows. Frames are Cocoa screen points (origin bottom-left of the primary display),
/// the same space AppKit and the other verbs use; the window server's own top-left bounds are
/// flipped once, in `ServerWindow.init(info:primaryHeight:)`.
enum DiagnoseSnapshot {
    struct Display: Equatable {
        var name: String
        var displayID: UInt32
        var persistentID: String?
        var isPrimary: Bool
        var frame: CGRect
        var visibleFrame: CGRect
        /// The display's key in `com.apple.spaces` (its UUID, or `Main`).
        var spaceIdentifier: String?
        /// Every desktop of the display in Mission Control order, including full-screen ones.
        var spaceIDs: [UInt64]
        var currentSpaceID: UInt64?
        var fullScreenSpaceIDs: [UInt64] = []

        var currentIndex: Int? { currentSpaceID.flatMap { spaceIDs.firstIndex(of: $0) }.map { $0 + 1 } }
        var currentIsFullScreen: Bool { currentSpaceID.map { fullScreenSpaceIDs.contains($0) } ?? false }
    }

    /// One entry of `CGWindowListCopyWindowInfo(.optionAll)`. The window's title is never read:
    /// other apps' titles need Screen Recording and a title can hold anything the user typed.
    struct ServerWindow: Equatable {
        var id: Int
        var pid: Int32
        var ownerName: String
        /// The window server's layer, which is the window's `level`.
        var level: Int
        var alpha: Double
        var isOnScreen: Bool
        var frame: CGRect

        init(id: Int, pid: Int32, ownerName: String, level: Int, alpha: Double, isOnScreen: Bool, frame: CGRect) {
            self.id = id; self.pid = pid; self.ownerName = ownerName; self.level = level
            self.alpha = alpha; self.isOnScreen = isOnScreen; self.frame = frame
        }

        /// nil for an entry without a number, owner, layer or bounds. `kCGWindowIsOnscreen` is
        /// absent, not false, for a window that is not on screen.
        init?(info: [String: Any], primaryHeight: CGFloat) {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let level = info[kCGWindowLayer as String] as? Int,
                  let bounds = (info[kCGWindowBounds as String] as? [String: Any])
                    .flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            self.init(id: id, pid: pid, ownerName: info[kCGWindowOwnerName as String] as? String ?? "", level: level,
                      alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                      isOnScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                      frame: CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height))
        }
    }

    /// What AppKit believes about one of MacHUD's own windows.
    struct AppKitWindow: Equatable {
        var number: Int
        var identifier: String?
        var title: String?
        var className: String
        var isVisible: Bool
        var isOnActiveSpace: Bool
        var alpha: Double
        var level: Int
        var collectionBehavior: UInt
        var frame: CGRect

        var joinsAllSpaces: Bool { NSWindow.CollectionBehavior(rawValue: collectionBehavior).contains(.canJoinAllSpaces) }
        /// What names the window in a sentence: its identifier, else its title, else its class.
        var label: String {
            if let identifier, !identifier.isEmpty { return identifier }
            if let title, !title.isEmpty { return title }
            return className
        }
    }

    struct FamilyProcess: Equatable {
        enum Role: String { case machud, voiceHost, sibling }
        var role: Role
        var name: String
        var bundleID: String?
        var pid: Int32
    }

    struct App: Equatable {
        var name: String
        var pid: Int32
    }

    struct Machud: Equatable {
        var version: String
        var build: String?
        var pid: Int32
        var launchedAt: Date?
        var isolated: Bool
    }

    struct Providers {
        var now: () -> Date
        var machud: () -> Machud
        var displays: () -> [Display]
        var frontmost: () -> App?
        var processes: () -> [FamilyProcess]
        var serverWindows: () -> [ServerWindow]
        /// The desktops (ManagedSpaceIDs) a window is on; nil when the window server cannot say.
        var spaces: (_ window: Int) -> [UInt64]?
        var appKitWindows: () -> [AppKitWindow]
        /// The replies of `tooldock`, `widgets list`, `voice status` and `voice state` under
        /// `tooldock`, `widgets`, `voiceStatus` and `voiceState`; a key is absent when its reply
        /// could not be gathered.
        var replies: [String: [String: Any]]
    }

    struct Result {
        var document: [String: Any]
        var anomalies: [String]
    }

    /// Keys of `voice state` that hold what the user dictated or the agent answered. They are
    /// left out of the snapshot: it is meant to be read, pasted and attached.
    static let redactedVoiceStateKeys = ["card", "partialTranscript"]
    /// How far a window's frame may be from a screen's and still fill it. The window server
    /// rounds, which is the tolerance `HUDFullscreenObserver` allows.
    static let fillTolerance: CGFloat = 1

    // MARK: - Building

    static func build(_ p: Providers) -> Result {
        let displays = p.displays()
        let machud = p.machud()
        let front = p.frontmost()
        let processes = ordered(p.processes())
        let listed = p.serverWindows()

        let rows = familyRows(processes: processes, listed: listed, displays: displays, spaces: p.spaces)
        let fullFrame = fullFrameWindows(listed, displays: displays, frontmost: front)
        let appKit = p.appKitWindows()
        let ownListed = Dictionary(listed.filter { $0.pid == machud.pid }.map { ($0.id, $0) }) { a, _ in a }
        let anomalies = findAnomalies(rows: rows, appKit: appKit, ownListed: ownListed,
                                      ownName: processes.first { $0.role == .machud }?.name ?? "MacHUD",
                                      fullFrame: fullFrame, frontmost: front, processes: processes, replies: p.replies)

        let appKitByNumber = Dictionary(appKit.map { ($0.number, $0) }) { a, _ in a }
        let document: [String: Any] = [
            "createdAt": iso(p.now()),
            "machud": machudJSON(machud),
            "displays": displays.map(displayJSON),
            "frontmostApp": front.map { ["name": $0.name, "pid": Int($0.pid)] as [String: Any] } ?? NSNull(),
            "processes": processes.map { process in
                processJSON(process, rows: rows.filter { $0.process.pid == process.pid },
                            appKit: process.pid == machud.pid ? appKitByNumber : [:],
                            unlisted: process.pid == machud.pid ? appKit.filter { ownListed[$0.number] == nil } : [])
            },
            "fullFrameWindows": fullFrame.map { fullFrameJSON($0, frontmost: front) },
            "replies": repliesJSON(p.replies),
            "anomalies": anomalies,
        ]
        return Result(document: document, anomalies: anomalies)
    }

    /// The machud process first, then the voice host, then the siblings by name.
    private static func ordered(_ processes: [FamilyProcess]) -> [FamilyProcess] {
        func rank(_ p: FamilyProcess) -> Int { p.role == .machud ? 0 : p.role == .voiceHost ? 1 : 2 }
        return processes.sorted {
            (rank($0), $0.name.lowercased(), $0.pid) < (rank($1), $1.name.lowercased(), $1.pid)
        }
    }

    /// One family window with what the anomaly rules and the JSON both need.
    private struct Row {
        var process: FamilyProcess
        var window: ServerWindow
        var spaces: [UInt64]?
        var display: Display?
    }

    private static func familyRows(processes: [FamilyProcess], listed: [ServerWindow], displays: [Display],
                             spaces: (Int) -> [UInt64]?) -> [Row] {
        processes.flatMap { process in
            listed.filter { $0.pid == process.pid }.sorted { $0.id < $1.id }.map { window in
                Row(process: process, window: window, spaces: spaces(window.id)?.sorted(), display: display(of: window.frame, in: displays))
            }
        }
    }

    /// The display holding the window's centre; nil for a window off every display.
    private static func display(of frame: CGRect, in displays: [Display]) -> Display? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return displays.first { $0.frame.contains(centre) }
    }

    // MARK: - Full-frame windows

    private struct FullFrame {
        var window: ServerWindow
        var display: Display
    }

    /// On-screen layer-0 windows of any app that fill a display: what a full-screen app looks like
    /// to the window server, and what the voice orb's full-screen check reacts to.
    private static func fullFrameWindows(_ listed: [ServerWindow], displays: [Display], frontmost: App?) -> [FullFrame] {
        listed.filter { $0.isOnScreen && $0.level == 0 }.sorted { $0.id < $1.id }.compactMap { window in
            displays.first { fills(window.frame, $0.frame) }.map { FullFrame(window: window, display: $0) }
        }
    }

    private static func fills(_ window: CGRect, _ screen: CGRect) -> Bool {
        abs(window.minX - screen.minX) <= fillTolerance && abs(window.minY - screen.minY) <= fillTolerance
            && abs(window.width - screen.width) <= fillTolerance && abs(window.height - screen.height) <= fillTolerance
    }

    // MARK: - Anomalies

    private static func findAnomalies(rows: [Row], appKit: [AppKitWindow], ownListed: [Int: ServerWindow], ownName: String,
                                  fullFrame: [FullFrame], frontmost: App?, processes: [FamilyProcess],
                                  replies: [String: [String: Any]]) -> [String] {
        var out: [String] = []

        // AppKit has the window ordered in and visible, so a user on the window's desktop should
        // see it; the window server disagrees. A window that is simply on another desktop is not
        // a fault, so it counts only when AppKit also says it belongs here.
        // Only windows that have a window-server number: a window never ordered in has none, and the
        // menu bar's status item windows carry proxy numbers beyond a `CGWindowID` that the window
        // server never lists under them.
        for window in appKit.sorted(by: { $0.number < $1.number })
        where window.isVisible && window.alpha > 0 && !window.frame.isEmpty && (1...Int(UInt32.max)).contains(window.number) {
            let named = "\(ownName) window #\(window.number) (\(window.label))"
            guard let server = ownListed[window.number] else {
                out.append("\(named) is visible to AppKit but the window server does not list it at all")
                continue
            }
            if !server.isOnScreen, window.isOnActiveSpace || window.joinsAllSpaces {
                out.append("\(named) is visible to AppKit but the window server does not list it as on screen")
            }
        }

        // On some desktops of its display but not the one showing: the window server dropped part
        // of an all-desktops window's membership. A layer-0 window on one other desktop is an
        // ordinary window, and a full-screen app's desktop is skipped because windows without
        // `.fullScreenAuxiliary` (the widgets) are not on it.
        for row in rows {
            let window = row.window
            guard window.alpha > 0, !window.frame.isEmpty, let spaces = row.spaces, let display = row.display,
                  let current = display.currentSpaceID, let currentIndex = display.currentIndex,
                  !display.currentIsFullScreen, !spaces.contains(current) else { continue }
            let here = display.spaceIDs.enumerated().filter { spaces.contains($0.element) }.map { $0.offset + 1 }
            guard !here.isEmpty, here.count >= 2 || window.level != 0 else { continue }
            let appKitLabel = appKit.first { $0.number == window.id && row.process.role == .machud }?.label
            let detail = ([appKitLabel] + ["level \(window.level)"]).compactMap { $0 }.joined(separator: ", ")
            let list = (here.count == 1 ? "desktop " : "desktops ") + here.map(String.init).joined(separator: ", ")
            out.append("\(row.process.name) window #\(window.id) (\(detail)) is on \(list) of \(display.spaceIDs.count) on \(display.name) "
                       + "but not on the one showing (desktop \(currentIndex))")
        }

        let voiceState = replies["voiceState"]
        let hidden = voiceState?["ok"] as? Bool == true
            && (voiceState?["state"] as? [String: Any])?["hiddenForFullScreen"] as? Bool == true
        if hidden { out.append(hiddenForFullScreen(fullFrame: fullFrame, frontmost: frontmost)) }

        out.append(contentsOf: voiceHostAnomalies(rows: rows, processes: processes, replies: replies, hidden: hidden))
        return out
    }

    private static func hiddenForFullScreen(fullFrame: [FullFrame], frontmost: App?) -> String {
        let lead = "The voice host reports the orb hidden for a full-screen app"
        func name(_ f: FullFrame) -> String { "\(f.window.ownerName) (pid \(f.window.pid)) window #\(f.window.id)" }
        let candidates = frontmost.map { front in fullFrame.filter { $0.window.pid == front.pid } } ?? fullFrame
        if !candidates.isEmpty {
            return lead + ": " + candidates.map { "\(name($0)) fills \($0.display.name)" }.joined(separator: "; ")
        }
        guard let frontmost else { return lead + ", but no layer-0 window fills a screen (frontmost app unknown)" }
        let who = "\(frontmost.name), pid \(frontmost.pid)"
        if fullFrame.isEmpty { return lead + ", but no layer-0 window fills a screen (frontmost app: \(who))" }
        return lead + ", but no window of the frontmost app (\(who)) fills a screen; full-frame windows of other apps: "
            + fullFrame.map(name).joined(separator: ", ")
    }

    private static func voiceHostAnomalies(rows: [Row], processes: [FamilyProcess], replies: [String: [String: Any]],
                                           hidden: Bool) -> [String] {
        guard let status = replies["voiceStatus"] else { return ["The voice host's status was not available"] }
        let statusName = status["status"] as? String ?? "unknown"
        // Voice turned off, or a build without the host, is a choice, not a fault.
        guard !["disabled", "notInstalled"].contains(statusName) else { return [] }
        guard status["connected"] as? Bool == true else { return ["The voice host is not connected (status: \(statusName))"] }
        let state = replies["voiceState"]
        guard state?["ok"] as? Bool == true else {
            return ["The voice host did not answer `voice state`: \(state?["error"] as? String ?? "no reply")"]
        }
        // The orb is the voice host's one window that is always on screen. Hidden for a full-screen
        // app is already explained above.
        guard !hidden, let host = processes.first(where: { $0.role == .voiceHost }) else { return [] }
        let windows = rows.filter { $0.process.pid == host.pid }
        guard !windows.isEmpty, !windows.contains(where: { $0.window.isOnScreen && $0.window.alpha > 0.05 }) else { return [] }
        return ["No \(host.name) window is on screen (the voice host has \(windows.count) window\(windows.count == 1 ? "" : "s"), none showing)"]
    }

    // MARK: - JSON

    /// A JSON number, or null for one JSON cannot hold (`JSONSerialization` raises on NaN).
    private static func num(_ value: Double) -> Any { value.isFinite ? (value * 100).rounded() / 100 : NSNull() }

    private static func rect(_ r: CGRect) -> [String: Any] {
        ["x": num(r.minX), "y": num(r.minY), "w": num(r.width), "h": num(r.height)]
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private static func machudJSON(_ m: Machud) -> [String: Any] {
        var d: [String: Any] = ["version": m.version, "pid": Int(m.pid), "isolated": m.isolated]
        if let build = m.build { d["build"] = build }
        if let launched = m.launchedAt { d["launchedAt"] = iso(launched) }
        return d
    }

    private static func displayJSON(_ d: Display) -> [String: Any] {
        var spaces: [String: Any] = [
            "identifier": d.spaceIdentifier ?? NSNull(),
            "all": d.spaceIDs.map { Int(clamping: $0) },
            "current": d.currentSpaceID.map { Int(clamping: $0) } ?? NSNull(),
            "currentIndex": d.currentIndex ?? NSNull(),
        ]
        if d.currentSpaceID != nil { spaces["currentIsFullScreen"] = d.currentIsFullScreen }
        var json: [String: Any] = ["name": d.name, "id": Int(d.displayID), "primary": d.isPrimary,
                                   "frame": rect(d.frame), "visibleFrame": rect(d.visibleFrame), "spaces": spaces]
        if let persistent = d.persistentID { json["persistentID"] = persistent }
        return json
    }

    private static func processJSON(_ process: FamilyProcess, rows: [Row], appKit: [Int: AppKitWindow],
                                    unlisted: [AppKitWindow]) -> [String: Any] {
        var json: [String: Any] = ["role": process.role.rawValue, "name": process.name, "pid": Int(process.pid),
                                   "windows": rows.map { windowJSON($0, appKit: appKit[$0.window.id]) }]
        if let bundle = process.bundleID { json["bundleID"] = bundle }
        if !unlisted.isEmpty { json["appKitWindowsNotListedByTheServer"] = unlisted.map(appKitJSON) }
        return json
    }

    private static func windowJSON(_ row: Row, appKit: AppKitWindow?) -> [String: Any] {
        let w = row.window
        var json: [String: Any] = [
            "id": w.id, "level": w.level, "alpha": num(w.alpha), "onScreen": w.isOnScreen, "frame": rect(w.frame),
            "spaces": row.spaces.map { $0.map { Int(clamping: $0) } } ?? NSNull(),
            "display": row.display?.name ?? NSNull(),
        ]
        if let appKit { json["appKit"] = appKitJSON(appKit) }
        return json
    }

    private static func appKitJSON(_ w: AppKitWindow) -> [String: Any] {
        var json: [String: Any] = [
            "number": w.number, "class": w.className, "isVisible": w.isVisible, "isOnActiveSpace": w.isOnActiveSpace,
            "alpha": num(w.alpha), "level": w.level, "collectionBehavior": Int(clamping: w.collectionBehavior),
            "collectionBehaviorNames": collectionBehaviorNames(w.collectionBehavior), "frame": rect(w.frame),
        ]
        if let identifier = w.identifier, !identifier.isEmpty {
            json["identifier"] = identifier
        } else if let title = w.title, !title.isEmpty {
            json["title"] = title
        }
        return json
    }

    private static func fullFrameJSON(_ f: FullFrame, frontmost: App?) -> [String: Any] {
        ["app": f.window.ownerName, "pid": Int(f.window.pid), "id": f.window.id, "alpha": num(f.window.alpha),
         "frame": rect(f.window.frame), "display": f.display.name,
         "ownedByFrontmost": frontmost.map { $0.pid == f.window.pid } ?? NSNull()]
    }

    private static let behaviorNames: [(NSWindow.CollectionBehavior, String)] = [
        (.canJoinAllSpaces, "canJoinAllSpaces"), (.moveToActiveSpace, "moveToActiveSpace"), (.managed, "managed"),
        (.transient, "transient"), (.stationary, "stationary"), (.participatesInCycle, "participatesInCycle"),
        (.ignoresCycle, "ignoresCycle"), (.fullScreenPrimary, "fullScreenPrimary"), (.fullScreenAuxiliary, "fullScreenAuxiliary"),
        (.fullScreenNone, "fullScreenNone"), (.fullScreenAllowsTiling, "fullScreenAllowsTiling"),
        (.fullScreenDisallowsTiling, "fullScreenDisallowsTiling"), (.primary, "primary"), (.auxiliary, "auxiliary"),
        (.canJoinAllApplications, "canJoinAllApplications"),
    ]

    static func collectionBehaviorNames(_ raw: UInt) -> [String] {
        let behavior = NSWindow.CollectionBehavior(rawValue: raw)
        return behaviorNames.filter { behavior.contains($0.0) }.map(\.1)
    }

    /// The four verb replies as they are, minus dictated and spoken text. A reply that was not
    /// gathered is null, so the file says what is missing.
    private static func repliesJSON(_ replies: [String: [String: Any]]) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in ["tooldock", "widgets", "voiceStatus", "voiceState"] {
            guard var reply = replies[key] else { out[key] = NSNull(); continue }
            if key == "voiceState" { reply = redactingVoiceState(reply) }
            out[key] = jsonSafe(reply)
        }
        return out
    }

    private static func redactingVoiceState(_ reply: [String: Any]) -> [String: Any] {
        guard var state = reply["state"] as? [String: Any] else { return reply }
        let removed = redactedVoiceStateKeys.filter { state.removeValue(forKey: $0) != nil }
        guard !removed.isEmpty else { return reply }
        var out = reply
        out["state"] = state
        out["redacted"] = removed
        return out
    }

    /// `value` with everything JSON cannot hold made safe: non-finite numbers become null and any
    /// other foreign value (a `Date`, say) its description, so writing the file cannot raise.
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case is NSNull: return value
        case let string as String: return string
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() || number.doubleValue.isFinite ? number : NSNull()
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case let date as Date: return iso(date)
        default: return String(describing: value)
        }
    }
}
