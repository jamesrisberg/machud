import AppKit

/// Rewrites display-by-name references in loadouts to persistent display ids, for the
/// displays that are attached (a name alone mixes up two monitors of the same model and
/// breaks when macOS appends " (2)"). Run on every config load and display change, so a
/// display that was unplugged at load is pinned the next time it shows up.
enum DisplayPinning {
    static func migrate(_ config: Config, screens: [ScreenDescriptor]) -> Config {
        guard var loadouts = config.loadouts, screens.contains(where: { $0.persistentID != nil }) else { return config }
        for li in loadouts.indices {
            guard var assignments = loadouts[li].screens else { continue }
            for ai in assignments.indices {
                assignments[ai].screen = pin(assignments[ai].screen, screens: screens)
                if let fallback = assignments[ai].fallback?.screen {
                    assignments[ai].fallback?.screen = pin(fallback, screens: screens)
                }
            }
            loadouts[li].screens = assignments
        }
        var out = config
        out.loadouts = loadouts
        return out
    }

    /// `.name` becomes `.display` when it identifies exactly one attached display that
    /// reports a persistent id. Everything else is left alone: `main`, `builtin` and
    /// `index` are roles, not displays.
    static func pin(_ ref: ScreenRef, screens: [ScreenDescriptor]) -> ScreenRef {
        guard case .name(let name) = ref else { return ref }
        let exact = screens.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let matches = exact.isEmpty ? screens.filter { $0.name.range(of: name, options: .caseInsensitive) != nil } : exact
        guard matches.count == 1, let id = matches[0].persistentID else { return ref }
        return .display(id: id, name: matches[0].name)
    }
}

extension LayoutStore {
    /// Pins by-name display references to the displays attached now; saves if anything changed.
    func pinDisplays() {
        let pinned = DisplayPinning.migrate(config, screens: NSScreen.screens.map(\.descriptor))
        if pinned != config { save(pinned) }
    }
}

/// Re-applies the active loadout when the set of attached displays changes.
/// `didChangeScreenParametersNotification` fires in bursts (and for resolution or
/// arrangement changes too), so it is debounced and compared by display identity.
@MainActor
final class DisplayWatcher {
    /// Identity of the attached displays, order-independent.
    var signature: () -> [String] = {
        NSScreen.screens.map { $0.persistentID ?? "cg:\($0.displayID)" }.sorted()
    }
    var debounce: TimeInterval = 1.0
    /// What to do once the display set has settled on something new.
    let onChange: () -> Void

    private var last: [String]
    private var pending: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(signature: (() -> [String])? = nil, onChange: @escaping () -> Void) {
        if let signature { self.signature = signature }
        self.onChange = onChange
        last = []
        last = self.signature()
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } }
    }

    /// Debounce: only the last notification of a burst leads to a check.
    func screensChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { _ = self?.check() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// True (and `onChange` called) when the display set differs from the last check.
    @discardableResult
    func check() -> Bool {
        let now = signature()
        guard now != last else { return false }
        last = now
        onChange()
        return true
    }
}
