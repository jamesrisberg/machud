import AppKit

/// Desktops ("Spaces"). There is no public API, so the layout of the desktops is
/// read out of `com.apple.spaces` and switching is done by posting the Mission
/// Control keyboard shortcuts the user has enabled in
/// `com.apple.symbolichotkeys`.
enum Spaces {
    /// One display's desktops, in Mission Control order.
    struct Monitor: Equatable {
        var identifier: String          // display UUID, or "Main"
        var spaceIDs: [UInt64]          // ManagedSpaceID per desktop
        var currentSpaceID: UInt64?

        var count: Int { spaceIDs.count }
        /// 1-based position of the desktop currently showing on this display.
        var currentIndex: Int? {
            guard let id = currentSpaceID, let i = spaceIDs.firstIndex(of: id) else { return nil }
            return i + 1
        }

        func spaceID(at index: Int) -> UInt64? {
            spaceIDs.indices.contains(index - 1) ? spaceIDs[index - 1] : nil
        }

        var json: [String: Any] {
            ["display": identifier, "spaces": count, "currentSpace": currentIndex ?? 0]
        }
    }

    /// A Mission Control keyboard shortcut as stored in `com.apple.symbolichotkeys`.
    struct Shortcut: Equatable {
        var enabled: Bool
        var keyCode: Int
        /// `NSEvent.ModifierFlags` raw value, which shares its bit positions with `CGEventFlags`.
        var modifiers: UInt64

        /// Only the four real modifiers; the stored mask also carries
        /// device-dependent left/right bits that CGEvent must not see.
        var eventFlags: CGEventFlags { CGEventFlags(rawValue: modifiers & 0x001E_0000) }
    }

    /// `AppleSymbolicHotKeys` numbers we care about.
    enum Key {
        /// "Switch to Desktop 1" is 118, Desktop 2 is 119, ...
        static func desktop(_ n: Int) -> Int { 117 + n }
        static let moveLeft = 79
        static let moveRight = 81
    }

    enum SwitchError: Error {
        case noDesktops
        case outOfRange(count: Int)
        case shortcutDisabled
        case didNotSwitch(to: Int)
        case automationDenied
        case keystrokeFailed

        var reason: String {
            switch self {
            case .noDesktops: return "noDesktopsForScreen"
            case .outOfRange: return "spaceOutOfRange"
            case .shortcutDisabled: return "spacesShortcutDisabled"
            case .didNotSwitch: return "spaceDidNotSwitch"
            case .automationDenied: return "automationDenied"
            case .keystrokeFailed: return "keystrokeFailed"
            }
        }

        var message: String {
            switch self {
            case .noDesktops:
                return "no desktop information for this display in com.apple.spaces"
            case .outOfRange(let count):
                return "that display has \(count) desktop\(count == 1 ? "" : "s")"
            case .shortcutDisabled:
                return "enable \"Switch to Desktop N\" (or \"Move left/right a space\") in "
                    + "System Settings › Keyboard › Keyboard Shortcuts › Mission Control"
            case .didNotSwitch(let n):
                return "the system did not switch to desktop \(n)"
            case .keystrokeFailed:
                return "System Events would not type the shortcut"
            case .automationDenied:
                return "allow MacHUD to control System Events in System Settings › Privacy & Security › Automation"
            }
        }
    }

    // MARK: - Parsing

    /// Desktops per display from a decoded `com.apple.spaces` plist. Entries
    /// without a `Spaces` array are collapsed/remembered displays and skipped.
    static func monitors(from plist: [String: Any]) -> [Monitor] {
        guard let config = plist["SpacesDisplayConfiguration"] as? [String: Any],
              let management = config["Management Data"] as? [String: Any],
              let raw = management["Monitors"] as? [[String: Any]] else { return [] }
        var out: [Monitor] = []
        for entry in raw {
            guard let identifier = entry["Display Identifier"] as? String,
                  let spaces = entry["Spaces"] as? [[String: Any]], !spaces.isEmpty else { continue }
            let ids = spaces.compactMap { spaceID($0) }
            let current = (entry["Current Space"] as? [String: Any]).flatMap { spaceID($0) }
            out.append(Monitor(identifier: identifier, spaceIDs: ids, currentSpaceID: current))
        }
        return out
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        if let n = space["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        if let n = space["id64"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// One shortcut out of a decoded `com.apple.symbolichotkeys` plist (either the
    /// whole file or the `AppleSymbolicHotKeys` dictionary inside it).
    static func shortcut(from plist: [String: Any], key: Int) -> Shortcut? {
        let table = (plist["AppleSymbolicHotKeys"] as? [String: Any]) ?? plist
        guard let entry = table["\(key)"] as? [String: Any] else { return nil }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? false
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else {
            return Shortcut(enabled: false, keyCode: 0, modifiers: 0)
        }
        return Shortcut(enabled: enabled, keyCode: parameters[1].intValue,
                        modifiers: parameters[2].uint64Value)
    }

    // MARK: - Reading the live state

    /// `defaults export <domain> -` gives a plist of the *current* values, which
    /// is what we need: the Dock rewrites com.apple.spaces as desktops change.
    static func readDomain(_ domain: String) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["export", domain, "-"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func monitors() -> [Monitor] {
        readDomain("com.apple.spaces").map { monitors(from: $0) } ?? []
    }

    static func shortcut(_ key: Int) -> Shortcut? {
        readDomain("com.apple.symbolichotkeys").flatMap { shortcut(from: $0, key: key) }
    }

    /// The `com.apple.spaces` entry for a display: matched by UUID, falling back
    /// to the literal "Main" the main display is written as.
    static func monitor(for screen: NSScreen, in monitors: [Monitor]) -> Monitor? {
        var hit = monitors.first { $0.identifier == screen.spacesIdentifier }
        if hit == nil, screen.displayID == CGMainDisplayID() {
            hit = monitors.first { $0.identifier == "Main" }
        }
        guard var monitor = hit else { return nil }
        // `Current Space` in the plist is only as fresh as the Dock's last write.
        if let live = SpacesPrivate.currentSpace(of: screen) { monitor.currentSpaceID = live }
        return monitor
    }

    static func monitor(for screen: NSScreen) -> Monitor? { monitor(for: screen, in: monitors()) }

    // MARK: - Switching

    /// How to reach desktop `target` from `current`: either the direct
    /// "Switch to Desktop N" shortcut, or a number of left/right steps.
    enum Route: Equatable {
        case already
        case direct(Shortcut)
        case steps(Shortcut, count: Int)
    }

    static func route(to target: Int, current: Int, count: Int,
                      shortcuts: (Int) -> Shortcut?) -> Result<Route, SwitchError> {
        guard count > 0 else { return .failure(.noDesktops) }
        guard target >= 1, target <= count else { return .failure(.outOfRange(count: count)) }
        if target == current { return .success(.already) }
        if let direct = shortcuts(Key.desktop(target)), direct.enabled {
            return .success(.direct(direct))
        }
        let delta = target - current
        let key = delta > 0 ? Key.moveRight : Key.moveLeft
        guard let step = shortcuts(key), step.enabled else { return .failure(.shortcutDisabled) }
        return .success(.steps(step, count: abs(delta)))
    }

    /// Two ways to type a shortcut. The window server ignores synthetic key
    /// events for its own hotkeys on some systems, so when the CGEvent does not
    /// take effect the same keystroke is asked of System Events instead.
    enum Typist: String {
        case cgEvent
        case systemEvents
    }

    /// Whichever typist last worked, so later switches skip the dead path.
    @MainActor
    private(set) static var typist: Typist = .cgEvent

    /// Modifier keys, so the shortcut is typed the way a keyboard types it:
    /// the window server only matches its hotkeys when the modifiers are held.
    private static let modifierKeys: [(CGEventFlags, CGKeyCode, String)] = [
        (.maskCommand, 55, "command down"), (.maskShift, 56, "shift down"),
        (.maskAlternate, 58, "option down"), (.maskControl, 59, "control down"),
    ]

    static func post(_ shortcut: Shortcut) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags = shortcut.eventFlags
        let held = modifierKeys.filter { flags.contains($0.0) }
        for (_, key, _) in held { key.post(source: source, down: true, flags: flags) }
        CGKeyCode(shortcut.keyCode).post(source: source, down: true, flags: flags)
        CGKeyCode(shortcut.keyCode).post(source: source, down: false, flags: flags)
        for (_, key, _) in held.reversed() { key.post(source: source, down: false, flags: []) }
    }

    /// `key code 124 using {control down}` — the same keystroke, typed by System
    /// Events, which the window server does act on.
    static func systemEventsScript(for shortcut: Shortcut) -> String {
        let flags = shortcut.eventFlags
        let names = modifierKeys.filter { flags.contains($0.0) }.map(\.2)
        let using = names.isEmpty ? "" : " using {\(names.joined(separator: ", "))}"
        return "tell application \"System Events\" to key code \(shortcut.keyCode)\(using)"
    }

    /// True unless the Apple event was refused; -1743 is "not authorised to send".
    @discardableResult
    static func type(_ shortcut: Shortcut, with typist: Typist) -> Result<Void, SwitchError> {
        switch typist {
        case .cgEvent:
            post(shortcut)
            return .success(())
        case .systemEvents:
            var error: NSDictionary?
            NSAppleScript(source: systemEventsScript(for: shortcut))?.executeAndReturnError(&error)
            guard let error else { return .success(()) }
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            NSLog("MacHUD: System Events keystroke failed: %@", "\(error)")
            return .failure(code == -1743 ? .automationDenied : .keystrokeFailed)
        }
    }

    /// Switch `screen` to its `target` desktop and call back once it is showing.
    @MainActor
    static func switchTo(_ target: Int, on screen: NSScreen,
                         completion: @escaping (Result<Int, SwitchError>) -> Void) {
        let first = typist
        let budget = (monitor(for: screen)?.count ?? 1) + 1
        perform(target, on: screen, with: first, budget: budget) { result in
            if case .success = result { typist = first; completion(result); return }
            guard case .failure(.didNotSwitch) = result, first == .cgEvent else { completion(result); return }
            perform(target, on: screen, with: .systemEvents, budget: budget) { second in
                if case .success = second { typist = .systemEvents }
                completion(second)
            }
        }
    }

    /// One keystroke at a time, re-reading which desktop is showing after each:
    /// a step typed while the last one is still animating is swallowed, and the
    /// route is then simply recomputed from where we actually are.
    @MainActor
    private static func perform(_ target: Int, on screen: NSScreen, with typist: Typist, budget: Int,
                                completion: @escaping (Result<Int, SwitchError>) -> Void) {
        guard let monitor = monitor(for: screen) else { completion(.failure(.noDesktops)); return }
        let current = monitor.currentIndex ?? 1
        switch route(to: target, current: current, count: monitor.count, shortcuts: { Self.shortcut($0) }) {
        case .failure(let error):
            completion(.failure(error))
        case .success(.already):
            completion(.success(target))
        case .success(.direct(let shortcut)), .success(.steps(let shortcut, _)):
            guard budget > 0 else { completion(.failure(.didNotSwitch(to: target))); return }
            if case .failure(let error) = type(shortcut, with: typist) { completion(.failure(error)); return }
            waitForChange {
                guard Self.monitor(for: screen)?.currentIndex != current else {
                    completion(.failure(.didNotSwitch(to: target)))
                    return
                }
                perform(target, on: screen, with: typist, budget: budget - 1, completion: completion)
            }
        }
    }

    /// Wait for `activeSpaceDidChangeNotification`, or 1.5 s, whichever is first,
    /// then let the switch settle: the window server keeps reporting the old
    /// desktop's windows as on screen for a moment after the notification.
    @MainActor
    static func waitForChange(_ done: @escaping () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        var finished = false
        func settle() {
            guard !finished else { return }
            finished = true
            if let observer { center.removeObserver(observer) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { done() } }
        }
        observer = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                      object: nil, queue: .main) { _ in MainActor.assumeIsolated { settle() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { settle() } }
    }
}

private extension CGKeyCode {
    func post(source: CGEventSource?, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: self, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

/// SkyLight's private window/space calls, resolved at runtime. Only used when
/// `Config.experimental.spacesPrivateAPI` is on.
enum SpacesPrivate {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias MoveFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        if let handle, let found = dlsym(handle, name) { return found }
        // RTLD_DEFAULT: SkyLight is usually already loaded through AppKit.
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private static let connection: Int32? = {
        guard let sym = symbol("CGSMainConnectionID") ?? symbol("_CGSDefaultConnection") else { return nil }
        return unsafeBitCast(sym, to: ConnectionFn.self)()
    }()

    private static let currentSpace: CurrentSpaceFn? = {
        guard let sym = symbol("CGSManagedDisplayGetCurrentSpace") else { return nil }
        return unsafeBitCast(sym, to: CurrentSpaceFn.self)
    }()

    private static let moveWindows: MoveFn? = {
        guard let sym = symbol("CGSMoveWindowsToManagedSpace") else { return nil }
        return unsafeBitCast(sym, to: MoveFn.self)
    }()

    static var isAvailable: Bool { connection != nil && moveWindows != nil }

    /// The desktop a display is showing right now. Read-only, so it is not
    /// behind the experimental flag: `com.apple.spaces` records the current
    /// desktop only when the Dock happens to write the file.
    static func currentSpace(of screen: NSScreen) -> UInt64? {
        guard let connection, let currentSpace,
              let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue(),
              let name = CFUUIDCreateString(nil, uuid) else { return nil }
        let space = currentSpace(connection, name)
        return space == 0 ? nil : space
    }

    @discardableResult
    static func move(windowNumbers: [Int], toSpace space: UInt64) -> Bool {
        guard !windowNumbers.isEmpty, let connection, let moveWindows else { return false }
        moveWindows(connection, windowNumbers as CFArray, space)
        return true
    }

    /// An application's windows as the window server sees them, including the
    /// ones on other desktops that `.optionOnScreenOnly` (and the accessibility
    /// API) hide.
    static func windows(pid: pid_t) -> [(number: Int, frame: CGRect)] {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        var out: [(number: Int, frame: CGRect)] = []
        for info in raw {
            guard info[kCGWindowOwnerPID as String] as? Int32 == pid,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= WindowList.minimumSize.width,
                  bounds.height >= WindowList.minimumSize.height else { continue }
            out.append((number, CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                       width: bounds.width, height: bounds.height)))
        }
        return out
    }

    static func windowNumber(pid: pid_t, cocoaFrame frame: CGRect) -> Int? {
        windows(pid: pid).first { Geometry.matches($0.frame, frame, tolerance: 3) }?.number
    }
}
