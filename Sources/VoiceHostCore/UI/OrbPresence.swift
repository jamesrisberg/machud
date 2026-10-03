import AppKit
import HUDKit
import os

/// The orb's window as `OrbPresence` drives it: the presenter's `HUDPanelWindow`, a fake in
/// tests.
@MainActor
protocol OrbWindowing: AnyObject {
    var windowNumber: Int { get }
    /// Ordered in.
    var isVisible: Bool { get }
    var alphaValue: CGFloat { get set }
    var ignoresMouseEvents: Bool { get set }
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
}

extension HUDPanelWindow: OrbWindowing {}

/// Keeps the orb's window in step with what the presenter intends, and tells the story in the
/// log (`OrbLog`): each show and hide with its reason (for a full-screen hide, the window that
/// caused it), each repair, and each change of the screen the orb is anchored to. A pass that
/// finds the window in step says nothing.
///
/// The window fades in and out. Each fade's completion acts only if no later fade replaced it,
/// and a show that ends short of opaque (a fade cut off) is made opaque. Space membership is not
/// repaired here: HUDKit's presence keeper owns that for every hover `HUDPanelWindow`.
@MainActor
final class OrbPresence {
    enum Intent: Equatable {
        case shown
        case hiddenForFullScreen
    }

    /// The screen and geometry the orb is anchored to.
    struct Anchor: Equatable {
        /// `HUDScreenSnapshot.id(for:)`; nil without a screen.
        var screenID: String?
        var geometry: HUDNotchGeometry
    }

    /// How long past a fade's duration it still counts as running when its completion has not
    /// come (an animation stalled while the displays slept).
    static let fadeGrace: TimeInterval = 0.3

    /// The settled changes after which the orb's screen and geometry are read again: at the raw
    /// notification `NSScreen` can still describe the screens before the change.
    static let screenChanges: HUDEnvironmentMonitor.Change = [.screenParameters, .wake, .screensWake]

    static func refreshesScreen(after change: HUDEnvironmentMonitor.Change) -> Bool {
        !change.isDisjoint(with: screenChanges)
    }

    /// What the presenter last asked for; nil before its first render.
    private(set) var intent: Intent?
    var isShown: Bool { intent == .shown }
    /// The window that made the orb's screen full screen, named when the orb hides.
    var fullScreenEvidence: VoiceFullScreenEvidence?
    private(set) var anchor: Anchor?

    private let window: OrbWindowing
    /// Fades the window to an alpha over `OrbLayout.fadeDuration`, then calls back (also when the
    /// fade is cut off).
    private let fade: (CGFloat, @escaping @MainActor () -> Void) -> Void
    private let now: () -> Date
    private let log: (String) -> Void
    /// Bumped by every fade and repair; a fade's completion acts only if nothing followed it.
    private var fadeGeneration = 0
    /// While a fade runs, when it is due to be over (`fadeGrace` included).
    private var fadeDeadline: Date?

    init(window: OrbWindowing, fade: @escaping (CGFloat, @escaping @MainActor () -> Void) -> Void,
         now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = OrbLog.notice) {
        self.window = window
        self.fade = fade
        self.now = now
        self.log = log
    }

    // MARK: Show and hide

    /// Shows the orb, or hides it for full screen, when that is a change.
    func apply(hidden: Bool) {
        let next: Intent = hidden ? .hiddenForFullScreen : .shown
        guard next != intent else { return }
        let first = intent == nil
        intent = next
        window.ignoresMouseEvents = hidden
        if hidden {
            log("hidden for full screen: " + Self.describe(fullScreenEvidence))
            guard window.isVisible else { return dropFade() }
            startFade(to: 0) { [weak self] in
                guard let self else { return }
                self.window.orderOut(nil)
            }
        } else {
            log(first ? "shown: the voice host started (window #\(window.windowNumber))" : "shown: full screen ended")
            window.alphaValue = 0
            window.orderFrontRegardless()
            startFade(to: 1) { [weak self] in
                // A fade cut off short still leaves the orb opaque.
                guard let self, self.window.alphaValue != 1 else { return }
                self.window.alphaValue = 1
            }
        }
    }

    private var isFading: Bool { fadeDeadline.map { now() < $0 } ?? false }

    /// `completion` runs when the fade ends, unless another fade or a repair came after it.
    private func startFade(to alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
        fadeGeneration &+= 1
        let generation = fadeGeneration
        fadeDeadline = now().addingTimeInterval(OrbLayout.fadeDuration + Self.fadeGrace)
        fade(alpha) { [weak self] in
            guard let self, generation == self.fadeGeneration else { return }
            self.fadeDeadline = nil
            completion()
        }
    }

    /// Ends the running fade's claim on the window: its completion will do nothing.
    private func dropFade() {
        fadeGeneration &+= 1
        fadeDeadline = nil
    }

    // MARK: Reconcile

    /// Compares the window with the intent and repairs it when they disagree: an orb meant to be
    /// shown whose window is not ordered in, or is not opaque while no fade runs, is ordered in at
    /// alpha 1; an orb meant to be hidden whose window is still ordered in once no fade runs is
    /// ordered out. `reason` (what settled) goes in the log line. Returns whether it repaired.
    @discardableResult
    func reconcile(after reason: String) -> Bool {
        guard let intent else { return false }
        let alpha = String(format: "%.2f", window.alphaValue)
        let name = "repaired window #\(window.windowNumber)"
        switch intent {
        case .shown:
            if !window.isVisible {
                log("\(name): meant to be shown, but it was ordered out (alpha \(alpha)); ordered in at alpha 1 (\(reason))")
                dropFade()
                window.alphaValue = 1
                window.ignoresMouseEvents = false
                window.orderFrontRegardless()
            } else if window.alphaValue != 1, !isFading {
                log("\(name): meant to be shown, but it was at alpha \(alpha) with no fade running; set to alpha 1 (\(reason))")
                dropFade()
                window.alphaValue = 1
                window.ignoresMouseEvents = false
            } else {
                return false
            }
        case .hiddenForFullScreen:
            guard window.isVisible, !isFading else { return false }
            log("\(name): meant to be hidden for full screen, but it was still ordered in (alpha \(alpha)); ordered out (\(reason))")
            dropFade()
            window.orderOut(nil)
        }
        return true
    }

    // MARK: Anchor

    /// Records the screen and geometry the orb is anchored to and logs a change (the first one
    /// too) with `reason`. Returns whether it changed.
    @discardableResult
    func anchor(screenID: String?, geometry: HUDNotchGeometry, reason: String) -> Bool {
        let next = Anchor(screenID: screenID, geometry: geometry)
        guard next != anchor else { return false }
        anchor = next
        let notch = geometry.hasNotch ? "notch \(Self.points(geometry.notchWidth ?? 0)) wide" : "no notch"
        log("anchored to screen \(screenID ?? "unknown"): frame \(Self.format(geometry.screenFrame)), "
            + "visible \(Self.format(geometry.visibleFrame)), \(notch), top \(Self.points(geometry.topAnchorY)) (\(reason))")
        return true
    }

    // MARK: Formatting

    private static func describe(_ evidence: VoiceFullScreenEvidence?) -> String {
        guard let evidence else { return "the full-screen check named no window" }
        let app = evidence.app.map { "of \($0)" } ?? "of an unknown app"
        let frame = CGRect(x: evidence.frame.x, y: evidence.frame.y, width: evidence.frame.w, height: evidence.frame.h)
        return "window \(evidence.id) \(app) (pid \(evidence.pid)), frame \(format(frame)), layer \(evidence.layer)"
    }

    /// `x,y,w,h` in whole points, as HUDKit's log writes a rect.
    static func format(_ rect: CGRect) -> String {
        [rect.minX, rect.minY, rect.width, rect.height].map(points).joined(separator: ",")
    }

    private static func points(_ value: CGFloat) -> String { String(format: "%.0f", value) }
}

/// The orb's account of itself in the unified log: subsystem `com.jrisberg.machud.voice`,
/// category `orb`, at notice level with every value public, so the log reads the same after the
/// fact (`log show --predicate 'subsystem == "com.jrisberg.machud.voice" AND category == "orb"'`).
enum OrbLog {
    static let logger = Logger(subsystem: VoiceHostMain.secretsService, category: "orb")

    static func notice(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }
}
