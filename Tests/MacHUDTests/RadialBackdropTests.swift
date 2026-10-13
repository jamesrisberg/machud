import AppKit
@testable import HUDKit
import XCTest
@testable import MacHUDCore

/// The wheel's backdrop is HUDKit's soft backdrop: a blur shown through the field, with no tint
/// of its own. How it draws (`path`) decides how dark the wheel's own tint is, so the words read
/// on every path. The soft backdrop's private pieces and the Reduce transparency setting are
/// injected; no window is shown.
@MainActor
final class RadialBackdropTests: XCTestCase {
    private func backdrop(pieces: Result<HUDSoftBackdropPieces, HUDSoftBackdropPieces.Missing> = HUDSoftBackdropPieces.live,
                          reduced: Bool = false) -> RadialBackdrop {
        RadialBackdrop(view: HUDSoftBackdropView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), pieces: pieces,
                                                 transparency: .fixed(reduced: reduced), environment: .shared, scheduler: .main))
    }

    private var field: CGImage {
        RadialField(layout: RadialLayout(tree: RadialLayoutTests.tree(6, RadialLayoutTests.short)), reduced: false).blurImage
    }

    func testTheBackdropIsTheFamilysBlurWithNoTintOfItsOwn() {
        let backdrop = RadialBackdrop()
        XCTAssertNil(backdrop.view.tint, "the tint is the wheel's own layer")
        XCTAssertEqual(backdrop.view.blurRadius, 25)
        XCTAssertEqual(backdrop.view.path, .none, "nothing is drawn before there is a field")
        XCTAssertEqual(backdrop.view.identifier?.rawValue, "loadout wheel", "HUDKit's log lines name the wheel")
    }

    /// With a field the backdrop always draws something: the blur, or the system's material
    /// (Reduce transparency on, or no blur to be made), under the same tint.
    func testWithAFieldTheBackdropAlwaysDraws() throws {
        let missing = HUDSoftBackdropPieces.Missing(reason: "no CABackdropLayer (test)")
        XCTAssertEqual(backdrop(reduced: true).show(field: field), .systemMaterial)
        XCTAssertEqual(backdrop(pieces: .failure(missing)).show(field: field), .systemMaterial)
        XCTAssertEqual(backdrop().path, .none, "only before a field is shown")
        guard case .success = HUDSoftBackdropPieces.live else { throw XCTSkip("no blur pieces on this Mac") }
        XCTAssertEqual(backdrop().show(field: field), .blur)
    }

    /// A white word on a white desktop, where the tint is weakest under any word, reads at
    /// better than 4.5 to 1.
    func testWordsReadOnAWhiteDesktop() {
        let shade = 1 - RadialField.darkness * RadialField.readable
        let luminance = shade <= 0.04045 ? shade / 12.92 : pow((shade + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
    }

    /// The same field shown again is not set again: the soft backdrop rebuilds its material
    /// for a new field.
    func testTheSameFieldIsSetOnce() {
        let backdrop = backdrop()
        let image = field
        backdrop.show(field: image)
        let shown = backdrop.view.field
        XCTAssertNotNil(shown)
        backdrop.show(field: image)
        XCTAssertTrue(backdrop.view.field === shown)
        backdrop.show(field: RadialField(layout: RadialLayout(tree: RadialLayoutTests.tree(10, RadialLayoutTests.short)),
                                         reduced: false).blurImage)
        XCTAssertFalse(backdrop.view.field === shown)
    }

    /// The tint view shows the tint's darkness times how far the wheel has faded in.
    func testTheTintViewIsItsDarknessAsTheWheelFadesIn() {
        let tint = RadialTintView(frame: .zero)
        XCTAssertEqual(tint.alphaValue, RadialField.darkness, accuracy: 0.0001)
        tint.shown = 0.5
        XCTAssertEqual(tint.alphaValue, RadialField.darkness * 0.5, accuracy: 0.0001)
        tint.shown = 1
        XCTAssertEqual(tint.alphaValue, RadialField.darkness, accuracy: 0.0001)
    }
}
