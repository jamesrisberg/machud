import AppKit
import HUDKit

/// The tool dock as the Tool dock section drives it: changes apply live, through the same
/// calls as the dock's own menu, so they are saved in layouts.json.
@MainActor
protocol OnboardingToolDock: AnyObject {
    var isEnabled: Bool { get }
    var dockPosition: HUDDockPosition { get }
    /// The display it is on; nil is the main display.
    var screenName: String? { get }
    func setEnabled(_ on: Bool)
    func move(to position: HUDDockPosition)
}

@MainActor
final class LiveOnboardingToolDock: OnboardingToolDock {
    private weak var dock: ToolDock?

    init(dock: ToolDock) { self.dock = dock }

    var isEnabled: Bool { dock?.config().isEnabled ?? true }
    var dockPosition: HUDDockPosition { dock?.config().dockPosition ?? .bottom }
    var screenName: String? { dock?.config().screen }
    func setEnabled(_ on: Bool) { dock?.setEnabled(on) }
    func move(to position: HUDDockPosition) { dock?.position(position) }
}

/// A loadout as the First loadout and Radial menu sections show it: its regions on a
/// miniature of the display, each labelled with what fills it.
struct OnboardingLoadoutSummary: Equatable {
    struct Region: Equatable {
        var label: String
        var frame: FractionRect
    }

    var name: String
    var regions: [Region]
    /// Width over height of the display it was captured on.
    var aspect: Double
    var screen: String

    var json: [String: Any] {
        ["name": name, "screen": screen, "regions": regions.map { r -> [String: Any] in
            ["label": r.label, "x": r.frame.x, "y": r.frame.y, "w": r.frame.w, "h": r.frame.h]
        }]
    }
}

/// A finished apply, as the radial practice sees it.
struct OnboardingApplied: Equatable {
    var loadout: String
    var placed: Int
    var failed: Int
}

/// Why capturing did not work, for the user.
struct OnboardingProblem: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Capturing a loadout and hearing about applies. Tests use a fake, so nothing reads or moves
/// real windows.
@MainActor
protocol OnboardingLoadouts: AnyObject {
    var names: [String] { get }
    func summary(named name: String) -> OnboardingLoadoutSummary?
    /// Captures the windows on the display the onboarding is on as the loadout `name` (a
    /// hidden layout of the same name, one region per window), replacing one of that name.
    func capture(name: String, done: @escaping @MainActor (Result<OnboardingLoadoutSummary, OnboardingProblem>) -> Void)
    /// Called after each apply MacHUD finishes, however it was started.
    var onApplied: ((OnboardingApplied) -> Void)? { get set }
}

@MainActor
final class LiveOnboardingLoadouts: OnboardingLoadouts {
    private let engine: LoadoutEngine
    private let store: LayoutStore
    var onApplied: ((OnboardingApplied) -> Void)?

    init(engine: LoadoutEngine, store: LayoutStore) {
        self.engine = engine
        self.store = store
        let previous = engine.onApplied
        engine.onApplied = { [weak self] report in
            previous?(report)
            self?.onApplied?(OnboardingApplied(loadout: report.loadout, placed: report.placed.count, failed: report.failed.count))
        }
    }

    var names: [String] { store.loadouts.map(\.name) }

    func summary(named name: String) -> OnboardingLoadoutSummary? {
        guard let loadout = store.loadout(named: name) else { return nil }
        let assignment = loadout.screens?.first
        let layoutName = assignment?.layout ?? loadout.layout
        let slots = assignment?.slots ?? loadout.slots
        guard let layout = store.layout(named: layoutName) else { return nil }
        let screen = NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 16, height: 10)
        return OnboardingLoadoutSummary(
            name: name,
            regions: layout.regions.map { region in
                let label = slots.first { $0.regionID == region.id }?.occupant.label ?? region.name ?? "Empty"
                return .init(label: label, frame: region.frame)
            },
            aspect: visible.width / max(visible.height, 1),
            screen: screen?.localizedName ?? "")
    }

    func capture(name: String, done: @escaping @MainActor (Result<OnboardingLoadoutSummary, OnboardingProblem>) -> Void) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { done(.failure(OnboardingProblem("Give the loadout a name."))); return }
        guard Accessibility.isTrusted else {
            done(.failure(OnboardingProblem("MacHUD needs Accessibility to see your windows: grant it in Permissions.")))
            return
        }
        let screen = ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        engine.captureArrangement(name: name, layoutName: name, screens: [screen].compactMap { $0 }, walk: nil) { [weak self] capture in
            guard let self else { return }
            guard let capture, capture.slotCount > 0 else {
                done(.failure(OnboardingProblem("No app windows are on this display. Open two or three, then capture.")))
                return
            }
            self.engine.commit(capture, hideLayouts: true)
            NSLog("MacHUD: onboarding captured '%@': %d regions", name, capture.regionCount)
            guard let summary = self.summary(named: name) else {
                done(.failure(OnboardingProblem("The loadout was not saved.")))
                return
            }
            done(.success(summary))
        }
    }
}
