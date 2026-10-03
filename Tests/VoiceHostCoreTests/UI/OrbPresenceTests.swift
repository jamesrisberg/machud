import AppKit
import HUDKit
import XCTest
@testable import VoiceHostCore

@MainActor
final class OrbPresenceTests: XCTestCase {
    private var window: FakeOrbWindow!
    private var fades: [(alpha: CGFloat, done: @MainActor () -> Void)] = []
    private var logged: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_791_000_000)
    private let safari = VoiceFullScreenEvidence(id: 4321, pid: 567, app: "Safari",
                                                 frame: VoiceRect(CGRect(x: 0, y: 0, width: 2560, height: 1440)), layer: 0)

    override func setUp() async throws {
        window = FakeOrbWindow()
        fades = []
        logged = []
    }

    private func makePresence() -> OrbPresence {
        OrbPresence(window: window, fade: { [unowned self] alpha, done in fades.append((alpha, done)) },
                    now: { [unowned self] in clock }, log: { [unowned self] in logged.append($0) })
    }

    /// Ends the pending fades: the window reaches each fade's alpha, or stops at `cutOffAt`.
    private func finishFades(cutOffAt: CGFloat? = nil) {
        let pending = fades
        fades = []
        for fade in pending {
            window.alphaValue = cutOffAt ?? fade.alpha
            fade.done()
        }
    }

    private func shownAndSettled() -> OrbPresence {
        let presence = makePresence()
        presence.apply(hidden: false)
        finishFades()
        logged = []
        return presence
    }

    // MARK: Show and hide

    func testTheFirstRenderShowsTheOrbAndSaysSo() {
        let presence = makePresence()
        presence.apply(hidden: false)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(window.alphaValue, 0, "fades in")
        XCTAssertEqual(fades.map(\.alpha), [1])
        XCTAssertEqual(logged, ["shown: the voice host started (window #812)"])
        presence.apply(hidden: false)
        XCTAssertEqual(logged.count, 1, "a render that changes nothing says nothing")
        finishFades()
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testHidingForFullScreenSaysWhichWindowDidIt() {
        let presence = shownAndSettled()
        presence.fullScreenEvidence = safari
        presence.apply(hidden: true)
        XCTAssertEqual(logged, ["hidden for full screen: window 4321 of Safari (pid 567), frame 0,0,2560,1440, layer 0"])
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(fades.map(\.alpha), [0])
        finishFades()
        XCTAssertFalse(window.isVisible, "ordered out once faded")

        presence.fullScreenEvidence = nil
        presence.apply(hidden: false)
        XCTAssertEqual(logged.last, "shown: full screen ended")
        XCTAssertTrue(window.isVisible)
    }

    func testAHideWithoutEvidenceSaysSo() {
        let presence = shownAndSettled()
        presence.fullScreenEvidence = VoiceFullScreenEvidence(id: 9, pid: 42, app: nil,
                                                              frame: VoiceRect(CGRect(x: 0, y: 0, width: 10, height: 10)), layer: 0)
        presence.apply(hidden: true)
        XCTAssertEqual(logged.last, "hidden for full screen: window 9 of an unknown app (pid 42), frame 0,0,10,10, layer 0")
        presence.fullScreenEvidence = nil
        presence.apply(hidden: false)
        presence.apply(hidden: true)
        XCTAssertEqual(logged.last, "hidden for full screen: the full-screen check named no window")
    }

    func testAShowFadeCutOffStillEndsOpaque() {
        let presence = makePresence()
        presence.apply(hidden: false)
        finishFades(cutOffAt: 0.4)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"))
    }

    func testAnOlderFadeEndingLateChangesNothing() {
        let presence = shownAndSettled()
        presence.apply(hidden: true)
        presence.apply(hidden: false)
        // The hide's fade ends after the show began: the orb stays in.
        let hide = fades.removeFirst()
        hide.done()
        XCTAssertTrue(window.isVisible)
        finishFades()
        XCTAssertEqual(window.alphaValue, 1)
    }

    func testAHideWithTheWindowAlreadyOutEndsTheShowsFade() {
        let presence = makePresence()
        presence.apply(hidden: false)
        window.isVisible = false
        presence.apply(hidden: true)
        finishFades(cutOffAt: 0.4)
        XCTAssertEqual(window.alphaValue, 0.4, "the show's fade does nothing when it ends")
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"), "out, as meant")
    }

    func testStartingHiddenLeavesTheWindowOut() {
        let presence = makePresence()
        presence.fullScreenEvidence = safari
        presence.apply(hidden: true)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(fades.isEmpty, "nothing on screen to fade")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].hasPrefix("hidden for full screen: window 4321"))
    }

    // MARK: Reconcile

    func testAWindowInStepIsLeftAloneSilently() {
        let presence = shownAndSettled()
        let ins = window.orderIns
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"))
        XCTAssertEqual(window.orderIns, ins)
        XCTAssertTrue(logged.isEmpty)

        presence.apply(hidden: true)
        finishFades()
        logged = []
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(logged.isEmpty)
    }

    func testNothingIsReconciledBeforeTheFirstRender() {
        let presence = makePresence()
        XCTAssertFalse(presence.reconcile(after: "settled after wake"))
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(logged.isEmpty)
    }

    func testAnOrbMeantToBeShownWhoseWindowWentAwayIsOrderedIn() {
        let presence = shownAndSettled()
        window.isVisible = false
        XCTAssertTrue(presence.reconcile(after: "settled after wake,screensWake"))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(logged, ["repaired window #812: meant to be shown, but it was ordered out (alpha 1.00); "
                                + "ordered in at alpha 1 (settled after wake,screensWake)"])
    }

    func testAnOrbMeantToBeShownLeftTransparentIsMadeOpaque() {
        let presence = makePresence()
        presence.apply(hidden: false)
        // The fade never finishes (its completion never comes).
        clock += 0.1
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"), "a fade is still running")
        XCTAssertEqual(window.alphaValue, 0)
        clock += 1
        logged = []
        XCTAssertTrue(presence.reconcile(after: "settled after activeSpace"))
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertEqual(logged, ["repaired window #812: meant to be shown, but it was at alpha 0.00 with no fade running; "
                                + "set to alpha 1 (settled after activeSpace)"])
    }

    func testAnOrbMeantToBeHiddenWhoseWindowStayedInIsOrderedOut() {
        let presence = shownAndSettled()
        presence.fullScreenEvidence = safari
        presence.apply(hidden: true)
        // The hide's fade never finishes, so nothing ordered the window out.
        XCTAssertFalse(presence.reconcile(after: "settled after activeSpace"), "a fade is still running")
        clock += 1
        logged = []
        XCTAssertTrue(presence.reconcile(after: "settled after activeSpace"))
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(logged, ["repaired window #812: meant to be hidden for full screen, but it was still ordered in "
                                + "(alpha 1.00); ordered out (settled after activeSpace)"])
    }

    // MARK: Anchor

    func testTheAnchorIsLoggedWhenItChanges() {
        let presence = makePresence()
        let dell = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
        XCTAssertTrue(presence.anchor(screenID: "1", geometry: dell, reason: "start"))
        XCTAssertFalse(presence.anchor(screenID: "1", geometry: dell, reason: "settled after wake"))
        let laptop = HUDNotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                      safeAreaInsetTop: 38, notchWidth: 185)
        XCTAssertTrue(presence.anchor(screenID: "2", geometry: laptop, reason: "settled after screenParameters"))
        XCTAssertEqual(logged, [
            "anchored to screen 1: frame 0,0,2560,1440, visible 0,0,2560,1415, no notch, top 1415 (start)",
            "anchored to screen 2: frame 0,0,1512,982, visible 0,0,1512,944, notch 185 wide, top 944 "
                + "(settled after screenParameters)",
        ])
        XCTAssertEqual(presence.anchor?.screenID, "2")
    }

    func testAWakeOrScreenChangeReadsTheScreenAgainASpaceChangeDoesNot() {
        XCTAssertFalse(OrbPresence.refreshesScreen(after: [.activeSpace]))
        XCTAssertTrue(OrbPresence.refreshesScreen(after: [.wake]))
        XCTAssertTrue(OrbPresence.refreshesScreen(after: [.screensWake]))
        XCTAssertTrue(OrbPresence.refreshesScreen(after: [.screenParameters]))
        XCTAssertTrue(OrbPresence.refreshesScreen(after: [.activeSpace, .wake]))
    }
}

@MainActor
private final class FakeOrbWindow: OrbWindowing {
    var windowNumber = 812
    var isVisible = false
    var alphaValue: CGFloat = 1
    var ignoresMouseEvents = false
    var orderIns = 0

    func orderFrontRegardless() {
        isVisible = true
        orderIns += 1
    }

    func orderOut(_ sender: Any?) { isVisible = false }
}
