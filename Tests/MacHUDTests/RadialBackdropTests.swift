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
        RadialField(layout: RadialLayout(wedges: RadialLayoutTests.wedges(6, RadialLayoutTests.short)), reduced: false).blurImage
    }

    func testTheBackdropIsTheFamilysBlurWithNoTintOfItsOwn() {
        let backdrop = RadialBackdrop()
        XCTAssertNil(backdrop.view.tint, "the tint is the wheel's own layer")
        XCTAssertEqual(backdrop.view.blurRadius, 25)
        XCTAssertEqual(backdrop.view.path, .none, "nothing is drawn before there is a field")
    }

    /// Over the blur, and over the system's material (Reduce transparency, or no blur to be
    /// made), the tint has its usual darkness; with no backdrop at all it is darker.
    func testThePathDecidesHowDarkTheTintIs() throws {
        let missing = HUDSoftBackdropPieces.Missing(reason: "no CABackdropLayer (test)")
        XCTAssertEqual(backdrop(reduced: true).show(field: field), .systemMaterial)
        XCTAssertEqual(backdrop(pieces: .failure(missing)).show(field: field), .systemMaterial)
        XCTAssertEqual(backdrop().path, .none)
        XCTAssertEqual(RadialBackdrop.darkness(for: .blur), RadialField.darkness)
        XCTAssertEqual(RadialBackdrop.darkness(for: .systemMaterial), RadialField.darkness)
        XCTAssertEqual(RadialBackdrop.darkness(for: .none), RadialBackdrop.darknessWithoutBackdrop)
        XCTAssertGreaterThan(RadialBackdrop.darknessWithoutBackdrop, RadialField.darkness)
        guard case .success = HUDSoftBackdropPieces.live else { throw XCTSkip("no blur pieces on this Mac") }
        XCTAssertEqual(backdrop().show(field: field), .blur)
    }

    /// A white word on a white desktop, where the tint is weakest under any word: at least 4.5
    /// to 1 over the blur or the system's material, and at least 7 to 1 with no backdrop, where
    /// sharp detail sits behind the words.
    func testWordsReadOnEveryPath() {
        func contrast(_ path: HUDSoftBackdropView.Path) -> CGFloat {
            let shade = 1 - RadialBackdrop.darkness(for: path) * RadialField.readable
            let luminance = shade <= 0.04045 ? shade / 12.92 : pow((shade + 0.055) / 1.055, 2.4)
            return 1.05 / (luminance + 0.05)
        }
        XCTAssertGreaterThanOrEqual(contrast(.blur), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(.systemMaterial), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(.none), 7)
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
        backdrop.show(field: RadialField(layout: RadialLayout(wedges: RadialLayoutTests.wedges(9, RadialLayoutTests.short)),
                                         reduced: false).blurImage)
        XCTAssertFalse(backdrop.view.field === shown)
    }

    /// The tint view shows its darkness times how far the wheel has faded in.
    func testTheTintViewIsItsDarknessAsTheWheelFadesIn() {
        let tint = RadialTintView(frame: .zero)
        tint.darkness = RadialBackdrop.darknessWithoutBackdrop
        tint.shown = 0.5
        XCTAssertEqual(tint.alphaValue, RadialBackdrop.darknessWithoutBackdrop * 0.5, accuracy: 0.0001)
        tint.shown = 1
        tint.darkness = RadialField.darkness
        XCTAssertEqual(tint.alphaValue, RadialField.darkness, accuracy: 0.0001)
    }
}
