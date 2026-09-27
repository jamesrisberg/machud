import AppKit
import ApplicationServices

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt if not yet trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Coordinate helpers. AX uses a top-left origin on the primary display;
/// Cocoa uses bottom-left. Both share the same x axis and scale.
enum ScreenCoords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func axPoint(fromCocoa p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func axRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}

/// Thin wrapper over an AXUIElement of role AXWindow.
struct AXWindow {
    /// Decides which of MacHUD's own windows may be snapped; set by the app to
    /// "is a registered panel window".
    nonisolated(unsafe) static var ownWindowFilter: ((NSWindow) -> Bool)?

    private static func ownWindow(at p: CGPoint) -> NSWindow? {
        MainActor.assumeIsolated {
            NSApp.windows.first { $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(p) }
        }
    }

    let element: AXUIElement
    let pid: pid_t

    /// Resolve the standard window under a Cocoa-coordinate point, if any.
    static func under(cocoaPoint p: CGPoint) -> AXWindow? {
        let ax = ScreenCoords.axPoint(fromCocoa: p)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(ax.x), Float(ax.y), &hit) == .success,
              let start = hit else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(start, &pid)
        if pid == getpid() {
            // Only our panels (dock, dev servers, web) are draggable into regions;
            // overlays, the editor and the wheel are not.
            guard let own = ownWindow(at: p), let filter = ownWindowFilter, filter(own) else { return nil }
        }

        // Walk to the enclosing window.
        var current = start
        for _ in 0..<25 {
            if current.role == kAXWindowRole { return AXWindow(element: current, pid: pid).placeableOrNil }
            if let w = current.elementAttribute(kAXWindowAttribute) {
                return AXWindow(element: w, pid: pid).placeableOrNil
            }
            guard let parent = current.elementAttribute(kAXParentAttribute) else { break }
            current = parent
        }
        return nil
    }

    private var placeableOrNil: AXWindow? { isPlaceable ? self : nil }

    /// All of an application's windows, front to back.
    static func all(pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let raw = app.rawAttribute(kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return raw.map { AXWindow(element: $0, pid: pid) }
    }

    var subrole: String? { element.stringAttribute(kAXSubroleAttribute) }
    /// Sheets, popovers and drawers are not standard; borderless windows report
    /// no subrole at all and must stay usable.
    var isStandard: Bool { subrole == nil || subrole == kAXStandardWindowSubrole }
    /// The only test that really matters: can we move and resize it?
    var isPlaceable: Bool {
        element.isSettable(kAXPositionAttribute) && element.isSettable(kAXSizeAttribute)
    }
    var isMain: Bool { element.rawAttribute(kAXMainAttribute) as? Bool ?? false }

    var isMinimized: Bool {
        get { element.rawAttribute(kAXMinimizedAttribute) as? Bool ?? false }
        nonmutating set { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, newValue as CFBoolean) }
    }

    /// False once the window is gone (the app quit or closed it).
    var exists: Bool { axFrame != nil }

    var candidate: WindowMatch.Candidate {
        WindowMatch.Candidate(title: title, isMain: isMain, isStandard: isStandard,
                              isPlaceable: isPlaceable, isMinimized: isMinimized)
    }

    /// Frame in Cocoa coordinates (bottom-left origin).
    var cocoaFrame: CGRect? {
        guard let r = axFrame else { return nil }
        return CGRect(x: r.minX, y: ScreenCoords.primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    func setCocoaFrame(_ r: CGRect) { setAXFrame(ScreenCoords.axRect(fromCocoa: r)) }

    /// Ask a running app to open a window by pressing its ⌘N menu item (apps like
    /// TextEdit launch with no window at all). True once the item was pressed.
    static func openNewWindow(pid: pid_t) -> Bool {
        guard let item = newWindowItem(pid: pid) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The app's enabled ⌘N menu item (plain ⌘N, which beats matching a localized "New"
    /// title), if its menu bar is reachable without activating it.
    static func newWindowItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = app.elementAttribute(kAXMenuBarAttribute),
              let menus = bar.rawAttribute(kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for menu in menus {
            guard let submenu = (menu.rawAttribute(kAXChildrenAttribute) as? [AXUIElement])?.first,
                  let items = submenu.rawAttribute(kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items where item.stringAttribute(kAXMenuItemCmdCharAttribute) == "n"
                && item.rawAttribute(kAXMenuItemCmdModifiersAttribute) as? Int == 0
                && item.rawAttribute(kAXEnabledAttribute) as? Bool != false {
                return item
            }
        }
        return nil
    }

    /// Bring the window to the front of the window stack without activating its app.
    @discardableResult
    func raise() -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.5)
        return AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    /// Move without resizing (AX coordinates); what the parking animator calls per frame.
    func setAXPosition(_ p: CGPoint) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        element.set(kAXPositionAttribute, point: p)
    }

    /// Click the window's close button; windows have no close action of their own.
    func close() {
        guard let button = element.elementAttribute(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// Frame in AX coordinates (top-left origin).
    var axFrame: CGRect? {
        guard let pos: CGPoint = element.value(kAXPositionAttribute, .cgPoint),
              let size: CGSize = element.value(kAXSizeAttribute, .cgSize) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    var title: String { element.stringAttribute(kAXTitleAttribute) ?? "" }

    /// Set the window frame (AX coordinates). Position is set twice because some
    /// apps clamp the position based on the *old* size.
    func setAXFrame(_ r: CGRect) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        element.set(kAXPositionAttribute, point: r.origin)
        element.set(kAXSizeAttribute, size: r.size)
        element.set(kAXPositionAttribute, point: r.origin)
    }

    func isSame(as other: AXWindow) -> Bool { CFEqual(element, other.element) }
}

extension AXUIElement {
    var role: String? { stringAttribute(kAXRoleAttribute) }

    func rawAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value
    }

    func stringAttribute(_ name: String) -> String? {
        rawAttribute(name) as? String
    }

    func elementAttribute(_ name: String) -> AXUIElement? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    func value<T>(_ name: String, _ type: AXValueType) -> T? {
        guard let raw = rawAttribute(name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axValue = raw as! AXValue
        guard AXValueGetType(axValue) == type else { return nil }
        switch type {
        case .cgPoint:
            var p = CGPoint.zero
            return AXValueGetValue(axValue, .cgPoint, &p) ? (p as? T) : nil
        case .cgSize:
            var s = CGSize.zero
            return AXValueGetValue(axValue, .cgSize, &s) ? (s as? T) : nil
        default:
            return nil
        }
    }

    func set(_ name: String, point: CGPoint) {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(self, name as CFString, v)
    }

    func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(self, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    func set(_ name: String, size: CGSize) {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(self, name as CFString, v)
    }
}
