import AppKit
import XCTest
@testable import VoiceHostCore

@MainActor
final class OrbViewTests: XCTestCase {
    private func orb() -> OrbView {
        let geometry = OrbSnapshot.geometry
        let size = OrbLayout.windowSize(stretch: 0, geometry: geometry)
        return OrbView(frame: CGRect(origin: .zero, size: size), geometry: geometry)
    }

    func testOrbIsAnAccessibleButtonThatClicks() {
        let view = orb()
        var clicks = 0
        view.onClick = { clicks += 1 }
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertEqual(view.accessibilityLabel(), "Voice assistant")
        XCTAssertEqual(view.accessibilityValue() as? String, "Ready")
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(clicks, 1)
    }

    func testAccessibilityValueFollowsTheScene() {
        let view = orb()
        view.scene = OrbSceneTracker.map(.working, muted: false)
        XCTAssertEqual(view.accessibilityValue() as? String, "Working")
    }

    func testOnlyTheShapeTakesTheMouse() {
        let view = orb()
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        let center = CGPoint(x: view.bounds.midX, y: OrbLayout.orbTopGap + OrbLayout.orbDiameter / 2)
        XCTAssertTrue(view.hitTest(view.convert(center, to: container)) === view)
        XCTAssertNil(view.hitTest(view.convert(CGPoint(x: 0, y: view.bounds.maxY), to: container)))
    }

    func testCardButtonsSendTheApprovalID() {
        let card = OrbCardView(frame: .zero)
        var approved: [String] = []
        var denied: [String] = []
        var closed = 0
        card.onApprove = { approved.append($0) }
        card.onDeny = { denied.append($0) }
        card.onClose = { closed += 1 }
        card.update(card: VoiceCard(prompt: "p", approval: VoiceApproval(id: "a1", summary: "Run ls")), errorMessage: nil)
        card.approveButton.performClick(nil)
        card.denyButton.performClick(nil)
        card.closeButton.performClick(nil)
        XCTAssertEqual(approved, ["a1"])
        XCTAssertEqual(denied, ["a1"])
        XCTAssertEqual(closed, 1)
        XCTAssertEqual(card.approveButton.accessibilityLabel(), "Approve: Run ls")
        XCTAssertEqual(card.closeButton.accessibilityLabel(), "Close reply")
    }

    func testCardGrowsWithItsContent() {
        let card = OrbCardView(frame: .zero)
        card.update(card: nil, errorMessage: "No mic")
        let message = card.fittingCardSize.height
        card.update(card: VoiceCard(prompt: "What's up?", reply: "A reply"), errorMessage: nil)
        let short = card.fittingCardSize.height
        card.update(card: VoiceCard(prompt: "What's up?", reply: String(repeating: "word ", count: 80),
                                    progress: ["one", "two"], approval: VoiceApproval(id: "a", summary: "Do it", detail: "rm -rf /tmp/x")),
                    errorMessage: nil)
        let long = card.fittingCardSize.height
        XCTAssertGreaterThan(message, 0)
        XCTAssertGreaterThan(short, message)
        XCTAssertGreaterThan(long, short)
        XCTAssertEqual(card.fittingCardSize.width, OrbLayout.cardWidth)
    }
}
