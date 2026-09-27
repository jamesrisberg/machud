import AppKit

/// Browsers that are driven by Apple events instead of a command line. Arc has no
/// usable `--app=` mode, so a web occupant hosted there gets a real browser window
/// which MacHUD then places like any other window.
enum BrowserWindow {
    enum Kind: String, CaseIterable {
        case arc, safari

        var bundleID: String {
            switch self {
            case .arc: return "company.thebrowser.Browser"
            case .safari: return "com.apple.Safari"
            }
        }

        /// The name AppleScript addresses the app by.
        var scriptName: String {
            switch self {
            case .arc: return "Arc"
            case .safari: return "Safari"
            }
        }

        var host: WebHost {
            switch self {
            case .arc: return .arc
            case .safari: return .safari
            }
        }

        init?(host: WebHost) {
            switch host {
            case .arc: self = .arc
            case .safari: self = .safari
            case .chromeApp, .builtin: return nil
            }
        }

        init?(bundleID: String?) {
            guard let match = Kind.allCases.first(where: { $0.bundleID.caseInsensitiveCompare(bundleID ?? "") == .orderedSame })
            else { return nil }
            self = match
        }
    }

    // MARK: - Script sources

    /// Open one new window on `url`.
    ///
    /// Arc's `make new window` makes an empty window and offers no way to give it a
    /// url; `make new tab` at the application level is the form that reliably yields
    /// exactly one new, placeable window showing the page. Safari's `make new
    /// document` does the same in one step.
    static func openSource(kind: Kind, url: String) -> String {
        let literal = AppleScriptRunner.quote(url)
        switch kind {
        case .arc:
            return AppleScriptRunner.withTimeout(20,
                "tell application \"Arc\" to make new tab with properties {URL:\(literal)}")
        case .safari:
            return AppleScriptRunner.withTimeout(20,
                "tell application \"Safari\" to make new document with properties {URL:\(literal)}")
        }
    }

    /// The title and front-tab url of every window, front to back, one per line.
    static func tabWindowsSource(kind: Kind) -> String {
        let tab: String
        switch kind {
        case .arc: tab = "active tab"
        case .safari: tab = "current tab"
        }
        // `tab` is a class name inside a browser's tell block, so the separator is
        // bound to a variable outside it.
        let body = """
        set gsSep to (character id 9)
        set gsOut to ""
        tell application "\(kind.scriptName)"
        \trepeat with gsI from 1 to (count of windows)
        \t\tset gsName to ""
        \t\tset gsURL to ""
        \t\ttry
        \t\t\tset gsName to (name of window gsI) as text
        \t\tend try
        \t\ttry
        \t\t\tset gsURL to (URL of \(tab) of window gsI) as text
        \t\tend try
        \t\tset gsOut to gsOut & gsName & gsSep & gsURL & linefeed
        \tend repeat
        end tell
        return gsOut
        """
        return AppleScriptRunner.withTimeout(5, body)
    }

    /// One window as AppleScript sees it.
    struct TabWindow: Equatable {
        var name: String
        var url: String
    }

    static func parseTabWindows(_ output: String) -> [TabWindow] {
        output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let separator = line.firstIndex(of: "\t") else { return nil }
            return TabWindow(name: String(line[line.startIndex..<separator]),
                             url: String(line[line.index(after: separator)...]))
        }
    }

    /// The page an on-screen window is showing. AppleScript's window list and the
    /// accessibility one are separate views of the same windows with nothing in
    /// common but the title, and a browser can leave stale entries in the
    /// AppleScript one — Arc does — so front-to-back position is not an identity.
    /// Anything short of an unambiguous title match is answered with nothing, and
    /// the caller falls back to matching the app's window by title instead.
    static func url(forWindowTitled title: String, in windows: [TabWindow]) -> String? {
        guard !title.isEmpty else { return nil }
        let named = windows.filter { $0.name == title && !$0.url.isEmpty }
        guard let first = named.first, named.allSatisfy({ $0.url == first.url }) else { return nil }
        return first.url
    }

    // MARK: - Driving the browser

    static func isInstalled(_ kind: Kind) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleID) != nil
    }

    static func runningApps(_ kind: Kind) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleID).filter { !$0.isTerminated }
    }

    /// Ask the browser for a window on `url`. The window itself is found by diffing
    /// the browser's window list, so the reply only says whether the ask worked.
    static func open(url: String, kind: Kind, completion: @escaping (AppleScriptRunner.Failure?) -> Void) {
        AppleScriptRunner.run(openSource(kind: kind, url: url)) { result in
            switch result {
            case .success: completion(nil)
            case .failure(let failure): completion(failure)
            }
        }
    }
}

/// Finding the window a browser just opened. Window-server numbers are the
/// identity to diff on: accessibility elements go stale when a window closes and
/// drop out of the list for a moment while a browser is busy or on another space.
enum NewWindow {
    /// Every window the app owns, including ones on other spaces and ones that
    /// have just closed — so neither can be mistaken for a window we asked for.
    static func baseline(bundleID: String) -> Set<Int> {
        numbers(bundleID: bundleID, options: [.optionAll, .excludeDesktopElements])
    }

    /// The window the app opened since `baseline`, with the window-server number it
    /// keeps for the rest of its life. Only windows actually on screen count.
    static func since(_ baseline: Set<Int>, bundleID: String) -> (window: AXWindow, number: Int)? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier))
        for entry in WindowList.onScreen()
        where pids.contains(entry.pid) && !baseline.contains(entry.number) {
            let match = AXWindow.all(pid: entry.pid).first {
                $0.isPlaceable && $0.cocoaFrame.map { Geometry.matches($0, entry.frame, tolerance: 3) } == true
            }
            if let match { return (match, entry.number) }
        }
        return nil
    }

    /// Whether the window server still has this window. Accessibility goes quiet for
    /// a window on another desktop, which is not the same as the window being closed.
    static func stillExists(number: Int, bundleID: String) -> Bool {
        baseline(bundleID: bundleID).contains(number)
    }

    /// True when the browser did open a window but on another desktop — Arc puts a
    /// new window wherever its own window already is. Accessibility cannot reach a
    /// window on another desktop, so there is nothing to place until it is switched to.
    static func isOnAnotherDesktop(_ known: Set<Int>, bundleID: String) -> Bool {
        !baseline(bundleID: bundleID).subtracting(known).isEmpty
    }

    private static func numbers(bundleID: String, options: CGWindowListOption) -> Set<Int> {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier))
        guard !pids.isEmpty,
              let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var numbers: Set<Int> = []
        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid) else { continue }
            numbers.insert(number)
        }
        return numbers
    }
}

/// AppleScript's view of the browsers' windows, read at most once per browser per
/// capture (each read is an Apple event round trip).
@MainActor
final class BrowserTabs {
    private var cache: [BrowserWindow.Kind: [BrowserWindow.TabWindow]] = [:]

    func windows(of kind: BrowserWindow.Kind) -> [BrowserWindow.TabWindow] {
        if let cached = cache[kind] { return cached }
        var result: [BrowserWindow.TabWindow] = []
        if !BrowserWindow.runningApps(kind).isEmpty,
           case .success(let output) = AppleScriptRunner.run(BrowserWindow.tabWindowsSource(kind: kind), timeout: 6) {
            result = BrowserWindow.parseTabWindows(output)
        }
        cache[kind] = result
        return result
    }

    /// The url a browser window shows, for a window MacHUD did not open itself.
    func url(forWindowOf kind: BrowserWindow.Kind, title: String) -> String? {
        BrowserWindow.url(forWindowTitled: title, in: windows(of: kind))
    }
}

/// The browser windows MacHUD opened, so `clear` closes only those and `capture`
/// turns them back into the `.web` occupant that made them.
@MainActor
final class BrowserWindows {
    struct Entry {
        var url: String
        var host: WebHost
        var window: AXWindow
        /// Window-server number: stable identity even while accessibility cannot
        /// reach the window because it is on another desktop.
        var number: Int
        var bundleID: String
    }

    /// How long one slot may hold a browser's open lock before the next gets a turn.
    static let openTimeout: TimeInterval = 12

    private(set) var entries: [Entry] = []
    /// The slot currently opening a window in each browser, by bundle id: two new
    /// windows in one browser cannot be told apart, but different browsers are
    /// diffed separately and open in parallel.
    private var opening: [String: (regionID: String, since: Date)] = [:]
    /// Reasons an open failed, by region id, so the polling resolver can report them.
    private var failures: [String: String] = [:]
    /// Frame a new window was last seen at, with how many polls it has held it.
    private var settling: [String: (frame: CGRect, ticks: Int)] = [:]

    func prune() { entries.removeAll { !NewWindow.stillExists(number: $0.number, bundleID: $0.bundleID) } }

    func add(url: String, host: WebHost, window: AXWindow, number: Int, bundleID: String) {
        entries.append(Entry(url: url, host: host, window: window, number: number, bundleID: bundleID))
    }

    func window(url: String) -> AXWindow? { entries.first { $0.url == url }?.window }

    /// The occupant a window on screen came from.
    func entry(number: Int) -> Entry? { entries.first { $0.number == number } }

    /// A browser lays out a window a moment after the window server first shows it
    /// — Arc opens one full-screen and then shrinks it to its own default — so a new
    /// window is only adopted once its frame has held still for a few polls.
    /// Otherwise MacHUD's placement is undone by the browser a moment later.
    func hasSettled(_ regionID: String, frame: CGRect) -> Bool {
        let ticks = settling[regionID].map { Geometry.matches($0.frame, frame, tolerance: 1) ? $0.ticks + 1 : 1 } ?? 1
        settling[regionID] = (frame, ticks)
        return ticks >= 3
    }

    func fail(_ regionID: String, _ reason: String) {
        failures[regionID] = reason
        opening = opening.filter { $0.value.regionID != regionID }
    }

    func takeFailure(_ regionID: String) -> String? { failures.removeValue(forKey: regionID) }

    /// Take a browser's one-window-at-a-time lock, or say the slot must wait. A slot
    /// whose window never appears gives the lock up rather than starving the others.
    func claimOpening(_ regionID: String, bundleID: String) -> Bool {
        if let held = opening[bundleID], held.regionID != regionID {
            guard hasTimedOut(regionID: held.regionID, bundleID: bundleID) else { return false }
            finishOpening(bundleID: bundleID)
        }
        if opening[bundleID] == nil { opening[bundleID] = (regionID, Date()) }
        return opening[bundleID]?.regionID == regionID
    }

    func isOpening(_ regionID: String, bundleID: String) -> Bool {
        opening[bundleID]?.regionID == regionID
    }

    func hasTimedOut(regionID: String, bundleID: String) -> Bool {
        guard let held = opening[bundleID], held.regionID == regionID else { return true }
        return Date().timeIntervalSince(held.since) > Self.openTimeout
    }

    func finishOpening(bundleID: String) {
        if let held = opening.removeValue(forKey: bundleID) { settling[held.regionID] = nil }
    }

    func finishOpening() {
        opening.removeAll()
        settling.removeAll()
    }

    /// Close every window MacHUD opened whose url is not wanted any more.
    /// Returns how many were closed. A window that is still there but out of
    /// accessibility's reach — on another desktop — is kept for the next clear
    /// rather than forgotten, which would leave it behind for good.
    func close(keeping urls: Set<String>) -> Int {
        var closed = 0
        var remaining: [Entry] = []
        for entry in entries {
            guard NewWindow.stillExists(number: entry.number, bundleID: entry.bundleID) else { continue }
            if urls.contains(entry.url) {
                remaining.append(entry)
            } else if entry.window.exists {
                entry.window.close()
                closed += 1
            } else {
                remaining.append(entry)
            }
        }
        entries = remaining
        return closed
    }

    func windows(keeping urls: Set<String>) -> [AXWindow] {
        entries.filter { urls.contains($0.url) }.map(\.window)
    }
}
