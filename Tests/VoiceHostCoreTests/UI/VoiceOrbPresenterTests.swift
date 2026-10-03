import AppKit
import HUDKit
import XCTest
@testable import VoiceHostCore

/// The presenter's windows, read without rendering: nothing here orders a window in.
@MainActor
final class VoiceOrbPresenterTests: XCTestCase {
    private let actions = NoActions()
    private var logged: [String] = []

    private func makePresenter() -> VoiceOrbPresenter {
        VoiceOrbPresenter(actions: actions, log: { [unowned self] in logged.append($0) })
    }

    func testTheFullScreenEvidenceIsWhatHUDKitSaw() {
        let window = HUDWindowSnapshot(windowID: 4321, ownerPID: 567, layer: 0,
                                       bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), alpha: 1)
        XCTAssertEqual(VoiceFullScreenEvidence(window, app: "Safari"),
                       VoiceFullScreenEvidence(id: 4321, pid: 567, app: "Safari",
                                               frame: VoiceRect(CGRect(x: 0, y: 0, width: 2560, height: 1440)), layer: 0))
    }

    func testItsWindowsHaveIdentifiersForHUDKitsLog() {
        let presenter = makePresenter()
        let windows = [presenter.orbWindow, presenter.cardWindow, presenter.conversationWindow, presenter.scrimWindow]
        XCTAssertEqual(windows.map { $0.identifier?.rawValue },
                       ["voice-orb", "voice-card", "voice-conversation", "voice-scrim"])
    }

    func testItSaysWhichScreenItIsAnchoredToAtStart() throws {
        _ = makePresenter()
        let screen = try XCTUnwrap(VoiceOrbScreen.current(), "needs a display")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].hasPrefix("anchored to screen \(HUDScreenSnapshot.id(for: screen)): frame "), logged[0])
        XCTAssertTrue(logged[0].hasSuffix(" (start)"), logged[0])
    }

    func testTheOrbsWindowIsReportedAsAppKitHasIt() throws {
        let presenter = makePresenter()
        let report = try XCTUnwrap(presenter.orbWindowReport())
        XCTAssertFalse(report.isVisible, "ordered in by the first render")
        XCTAssertEqual(report.number, presenter.orbWindow.windowNumber)
        XCTAssertEqual(report.alpha, Double(presenter.orbWindow.alphaValue))
        XCTAssertEqual(report.frame, VoiceRect(presenter.orbWindow.frame))
        XCTAssertEqual(report.level, presenter.orbWindow.level.rawValue)
        if let screen = VoiceOrbScreen.current() {
            XCTAssertEqual(report.screen.id, Int(HUDScreenSnapshot.id(for: screen)))
            XCTAssertEqual(report.screen.frame, VoiceRect(screen.frame))
            XCTAssertEqual(report.screen.hasNotch, HUDNotchGeometry(screen: screen).hasNotch)
        }
    }
}

@MainActor
private final class NoActions: VoiceHostActing {
    func perform(_ action: VoiceHostAction) {}
    func send(typed text: String) -> String? { nil }
}
