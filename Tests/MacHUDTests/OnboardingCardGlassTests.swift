import AppKit
import HUDKit
import SwiftUI
import XCTest
@testable import MacHUDCore

/// The onboarding window blurs the whole screen with its own `NSVisualEffectView` (and not at
/// all while it is the compact card), so its cards must not set a second, window-wide blur:
/// they are on the classic material, which blurs only the card.
final class OnboardingCardGlassTests: XCTestCase {
    @MainActor
    func testTheCardsAreOnTheClassicMaterial() throws {
        let cards: [(radius: CGFloat, view: AnyView)] = [
            (24, AnyView(Text("card").frame(width: 200, height: 80).onboardingGlass())),
            (28, AnyView(Text("card").frame(width: 200, height: 80).onboardingGlass(radius: 28))),
        ]
        for card in cards {
            let host = NSHostingView(rootView: card.view)
            host.frame = CGRect(x: 0, y: 0, width: 200, height: 80)
            // Never ordered on screen; SwiftUI builds the representable once the view has a window.
            let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 200, height: 80),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let glass = try XCTUnwrap(Self.glassViews(in: host).first, "the card has HUD glass")
            XCTAssertEqual(glass.style.material, .visualEffect)
            XCTAssertEqual(glass.style.cornerRadius, card.radius)
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private static func glassViews(in view: NSView) -> [HUDGlassView] {
        (view as? HUDGlassView).map { [$0] } ?? view.subviews.flatMap { glassViews(in: $0) }
    }
}
