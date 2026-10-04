import AppKit
import HUDKit
import XCTest
@testable import MacHUDCore

/// The family's backdrop is the window server's blur of the whole window under a tint. The
/// layout editor and the loadout preview are screen-sized clear windows that dim the desktop,
/// so a window-wide blur would blur the very desktop they exist to show: their floating panels
/// stay on the classic material, which blurs only the panel. Nothing here orders a window on
/// screen.
final class OverlayGlassPanelTests: XCTestCase {
    private var classicPanel: HUDGlassView.Style {
        var style = HUDGlassView.Style.panel
        style.material = .visualEffect
        return style
    }

    @MainActor
    func testTheLayoutEditorsPanelIsOnTheClassicMaterial() {
        let panel = GlassPanel(frame: CGRect(x: 0, y: 0, width: 240, height: 64))
        XCTAssertEqual(panel.style.material, .visualEffect)
        XCTAssertEqual(panel.style, classicPanel, "only the material differs from the family's panel")
    }

    @MainActor
    func testTheLoadoutPreviewsPanelIsOnTheClassicMaterial() {
        let stack = NSStackView(views: [NSTextField(labelWithString: "Desktop 2")])
        let glass = LoadoutPreview.glassPanel(around: stack)
        XCTAssertEqual(glass.style.material, .visualEffect)
        XCTAssertEqual(glass.style, classicPanel, "only the material differs from the family's panel")
        XCTAssertTrue(glass.subviews.contains(stack), "the panel still holds its content")
    }
}
