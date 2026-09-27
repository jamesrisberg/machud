import AppKit
import HUDKit

/// The tool dock's window: the HUDKit panel recipe (non-activating, all Spaces, dragged
/// by its background), just above other floating panels, following the system
/// appearance like the Dock does.
@MainActor
final class ToolDockWindow: HUDPanelWindow {
    static func make() -> ToolDockWindow {
        let w = ToolDockWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 64), keyable: false,
                               level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
        w.appearance = nil
        w.hasShadow = true
        w.title = "MacHUD Tool Dock"
        return w
    }
}

/// The tool dock's strip is HUDKit's `HUDDockStripView` (its look is `HUDDockStyle.standard`,
/// measured from this dock). This maps the dock's buttons onto its items.
extension ToolDockItem {
    /// The app's real icon, or a symbol tile when the bundle is gone.
    var content: HUDDockTile.Content {
        if let path = bundlePath, FileManager.default.fileExists(atPath: path) { return .file(path) }
        return .symbol(symbol)
    }

    /// The name the strip shows beside a windowed (or menu) button while the pointer rests
    /// on it. Hover buttons have none: their panel is what shows.
    var stripLabel: String? { isHover ? nil : title }

    func stripItem(indicator: HUDDockIndicator) -> HUDDockItem {
        HUDDockItem(id: id, title: title, content: content, indicator: indicator, acceptsDrop: acceptsDrop,
                    label: stripLabel.map { .text($0) } ?? .none)
    }
}
