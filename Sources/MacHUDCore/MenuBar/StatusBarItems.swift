import AppKit

/// The real separator and expander status items. macOS puts a new status item left of the
/// existing ones, so the expander is created first and the separator second: the separator
/// starts out immediately left of the expander. `autosaveName` keeps wherever the user
/// ⌘-drags them afterwards.
@MainActor
final class StatusBarItems: NSObject, MenuBarItems {
    /// Wide enough to push everything left of the separator off any menu bar.
    static let collapsedLength: CGFloat = 10_000
    static let separatorLength: CGFloat = 12

    private var expander: NSStatusItem?
    private var separator: NSStatusItem?
    var onExpanderClick: ((Bool) -> Void)?

    /// An isolated instance (tests) keeps its own remembered positions.
    private static var autosaveSuffix: String { Env.socketPath == nil ? "" : ".isolated" }

    var isInstalled: Bool { expander != nil }

    func install() {
        guard expander == nil else { return }
        let exp = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        exp.autosaveName = "MenuBarExpander" + Self.autosaveSuffix
        if let button = exp.button {
            button.target = self
            button.action = #selector(expanderAction(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Click to collapse or expand menu bar items; right-click for options"
        }
        expander = exp
        let sep = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        sep.autosaveName = "MenuBarSeparator" + Self.autosaveSuffix
        sep.button?.toolTip = "Items left of this line are hidden when the menu bar collapses (⌘-drag to arrange)"
        separator = sep
        setHidden(false)
    }

    func remove() {
        for item in [separator, expander].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        separator = nil
        expander = nil
    }

    func setHidden(_ hidden: Bool) {
        guard let separator, let expander else { return }
        separator.length = hidden ? Self.collapsedLength : Self.separatorLength
        separator.button?.image = hidden ? nil : Self.separatorImage
        // Collapsed points left, toward what is hidden.
        let symbol = hidden ? "chevron.left" : "chevron.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: hidden ? "Expand menu bar" : "Collapse menu bar")
        image?.isTemplate = true
        expander.button?.image = image
    }

    var separatorIsLeftOfExpander: Bool {
        guard let sep = separator?.button?.window?.frame, let exp = expander?.button?.window?.frame,
              sep.width > 0, exp.width > 0 else { return true }
        // A stretched separator extends far left; compare right edges.
        return sep.maxX <= exp.minX + 1
    }

    var expanderFrame: CGRect? { expander?.button?.window?.frame }

    var diagnostics: [String: Any] {
        func describe(_ item: NSStatusItem?) -> [String: Any]? {
            guard let item else { return nil }
            var d: [String: Any] = ["length": item.length, "visible": item.isVisible]
            if let f = item.button?.window?.frame {
                d["frame"] = ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]
            }
            return d
        }
        var out: [String: Any] = [:]
        out["separator"] = describe(separator)
        out["expander"] = describe(expander)
        return out
    }

    func popUpMenu(_ menu: NSMenu) {
        guard let button = expander?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func expanderAction(_ sender: Any?) {
        let event = NSApp.currentEvent
        onExpanderClick?(event?.type == .rightMouseUp)
    }

    /// A thin vertical rule.
    private static let separatorImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 16), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 0.75, y: 1, width: 1.5, height: rect.height - 2),
                         xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Mouse position, the menu bar strip, and open menus, from public API only. An open menu is
/// any on-screen window at the pop-up menu level whose top edge touches a screen's top
/// (menus drop from the menu bar); CGWindowList reports layer and bounds without Screen
/// Recording permission.
@MainActor
struct SystemMenuBarProbe: MenuBarProbe {
    var mouse: CGPoint { NSEvent.mouseLocation }

    func isInMenuBar(_ point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) || $0.frame.maxY == point.y }) else {
            return false
        }
        let height = max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
        return point.y >= screen.frame.maxY - height - 1
    }

    func anyMenuOpen() -> Bool {
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // Screen tops in CoreGraphics coordinates (origin top-left of the main display).
        let tops = NSScreen.screens.map { mainHeight - $0.frame.maxY }
        return list.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == menuLayer,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width > 1 else { return false }
            return tops.contains { abs(bounds.minY - $0) <= 60 }
        }
    }
}
