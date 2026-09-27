import XCTest
import HUDKit
@testable import MacHUDCore

/// The shipped machud.json must decode and describe the panels MacHUD registers.
final class ManifestTests: XCTestCase {
    func testShippedManifestMatchesPanels() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacHUD/Resources/machud.json")
        let manifest = try HUDManifest.decode(Data(contentsOf: url))
        XCTAssertEqual(manifest.id, "com.jrisberg.machud")
        XCTAssertEqual(manifest.socket, "machud")
        XCTAssertEqual(manifest.panels.map(\.id), ["menubar"], "the quick-actions dock and dev servers moved to their own apps")
        let registered = MainActor.assumeIsolated { [MenuBarManager.panelID] }
        XCTAssertEqual(manifest.panels.map(\.id), registered)
    }
}
