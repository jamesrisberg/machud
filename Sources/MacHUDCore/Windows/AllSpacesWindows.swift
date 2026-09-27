import AppKit

/// Every user window on every desktop, and the accessibility elements to act on them.
///
/// `kAXWindowsAttribute` only lists a background app's windows on the current desktop,
/// so windows elsewhere are reached the way AltTab does it: by brute-forcing remote
/// element tokens (`_AXUIElementCreateWithRemoteToken`) and keeping the ones whose
/// window number (`_AXUIElementGetWindow`) the window server listed. Both calls are
/// private, read-only and looked up at run time; without them only the current
/// desktop's windows are reachable.
enum AllSpacesWindows {
    struct Entry: Equatable {
        var number: Int
        var pid: pid_t
        /// Cocoa screen coordinates.
        var frame: CGRect
        /// On a desktop that is showing now.
        var onScreen: Bool
    }

    /// Layer-0 windows of every app on every desktop, minus system chrome and slivers.
    /// Minimized windows are included (they are skipped later by their AX state).
    static func list() -> [Entry] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        var bundleIDs: [pid_t: String?] = [:]
        var out: [Entry] = []
        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= WindowList.minimumSize.width,
                  bounds.height >= WindowList.minimumSize.height else { continue }
            let bundleID = bundleIDs[pid] ?? {
                let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleIDs[pid] = id
                return id
            }()
            if let bundleID, WindowList.excludedBundleIDs.contains(bundleID) { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            // Off screen is either on another desktop or ordered out (hidden panels,
            // closed-but-kept windows). Only the first kind belongs to a desktop.
            if !onScreen, let spaces = spaceCount(number), spaces == 0 { continue }
            out.append(Entry(number: number, pid: pid,
                             frame: CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                           width: bounds.width, height: bounds.height),
                             onScreen: onScreen))
        }
        return out
    }

    /// Which windows a clear should consider, per process: everything but MacHUD's own,
    /// the MacHUD siblings' (their panels are HUD, not clutter) and hidden apps'.
    static func clearTargets(_ entries: [Entry], exempt: Set<pid_t>, hidden: Set<pid_t>) -> [pid_t: [Entry]] {
        Dictionary(grouping: entries.filter { !exempt.contains($0.pid) && !hidden.contains($0.pid) }, by: \.pid)
    }

    /// An app's AX windows paired with their window numbers, including windows on other
    /// desktops as far as `wanted` asks for them.
    static func axWindows(pid: pid_t, wanted: Set<Int>) -> [(window: AXWindow, number: Int?)] {
        var out: [(window: AXWindow, number: Int?)] = AXWindow.all(pid: pid).map { ($0, $0.windowNumber) }
        var missing = wanted.subtracting(out.compactMap(\.number))
        guard !missing.isEmpty, let create = createWithToken, getWindow != nil else { return out }

        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(0.5)
        for elementID: UInt64 in 0..<2000 {
            if missing.isEmpty || Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
            guard element.role == kAXWindowRole else { continue }
            let window = AXWindow(element: element, pid: pid)
            guard let number = window.windowNumber, missing.contains(number) else { continue }
            missing.remove(number)
            out.append((window, number))
        }
        return out
    }

    // MARK: - Private symbols

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let connection: Int32? = {
        (symbol("CGSMainConnectionID") ?? symbol("_CGSDefaultConnection")).map { unsafeBitCast($0, to: ConnectionFn.self)() }
    }()

    private static let spacesForWindows: SpacesForWindowsFn? = {
        symbol("CGSCopySpacesForWindows").map { unsafeBitCast($0, to: SpacesForWindowsFn.self) }
    }()

    /// How many desktops a window is on; nil when the private call is unavailable.
    static func spaceCount(_ number: Int) -> Int? {
        guard let connection, let spacesForWindows else { return nil }
        // Mask 7: current, other and user spaces.
        guard let spaces = spacesForWindows(connection, 7, [number] as CFArray)?.takeRetainedValue() else { return 0 }
        return CFArrayGetCount(spaces)
    }

    /// The desktops (ManagedSpaceIDs) a window is on: one normally, several for a window
    /// set to "all desktops", none for a minimized or ordered-out one. nil when the private
    /// call is unavailable. Read-only.
    static func spaceIDs(_ number: Int) -> [UInt64]? {
        guard let connection, let spacesForWindows else { return nil }
        guard let spaces = spacesForWindows(connection, 7, [number] as CFArray)?.takeRetainedValue() else { return [] }
        return (spaces as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    private typealias CreateFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    fileprivate typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static let createWithToken: CreateFn? = {
        symbol("_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: CreateFn.self) }
    }()

    fileprivate static let getWindow: GetWindowFn? = {
        symbol("_AXUIElementGetWindow").map { unsafeBitCast($0, to: GetWindowFn.self) }
    }()
}

extension AXWindow {
    /// The window server's number for this window (private `_AXUIElementGetWindow`).
    var windowNumber: Int? {
        guard let get = AllSpacesWindows.getWindow else { return nil }
        var id: CGWindowID = 0
        guard get(element, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }
}
