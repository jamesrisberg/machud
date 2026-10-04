import CoreGraphics
import Foundation

/// What apply does with an occupant whose only window is on a desktop that is not showing, while
/// multi-desktop loadouts are on (`PlacementPlan.Mode`).
enum SpacesPolicy: String, Codable, Equatable, CaseIterable {
    /// Fetch the existing window: show its desktop, move it, go back (default). Needs the
    /// window to be on another display, or a second display to hop it through; otherwise
    /// falls back to `launchNew`, then to reporting it.
    case bring
    /// Leave the existing window where it is and open a new one here, when the app can.
    case launchNew
    /// Leave it where it is and report `leave`.
    case leave
}

extension SpacesPolicy {
    /// With multi-desktop loadouts off `spaces.policy` is not read: an app whose only window is on
    /// another desktop gets a new window here when it can open one, and a single-window app gets
    /// `oneScreenSingleWindow`.
    static func oneScreen(_ newWindow: NewWindowClass) -> SpacesPolicy {
        newWindow.canOpenAnother ? .launchNew : oneScreenSingleWindow
    }

    /// What a single-window app (Messages, Signal…) whose window is on another desktop gets while
    /// multi-desktop loadouts are off: `bring` fetches it by switching desktops (it needs a
    /// display to carry it across; without one, or when the switch fails, the slot is left and
    /// names the app). It is the one desktop switch an apply makes with the setting off.
    /// `launchNew` would leave the window there and fail the slot instead.
    static let oneScreenSingleWindow: SpacesPolicy = .bring
}

/// `spaces` in layouts.json.
struct SpacesConfig: Codable, Equatable {
    var policy: SpacesPolicy?
    var effectivePolicy: SpacesPolicy { policy ?? .bring }
}

/// How an app gets a second window without being brought to the front. Decides whether
/// `launchNew` can work for it.
enum NewWindowClass: String, Equatable {
    /// A browser: asked by Apple event (`make new window`), or a new `--app` window.
    case browser
    /// Its menus have a New Window item, found by title (`NewWindowMenu`): Finder, Mail, terminals.
    case menu
    /// No such item (Messages, Signal, Notes…, or a menu in another language): there is no
    /// second window to open.
    case single

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "company.thebrowser.Browser", "com.apple.Safari",
        "org.mozilla.firefox",
    ]

    /// `hasNewWindowMenu`: `NewWindowMenu` found an item to press.
    static func of(bundleID: String, hasNewWindowMenu: Bool) -> NewWindowClass {
        if opensWindowsElsewhere(bundleID) { return .single }
        if browsers.contains(bundleID) { return .browser }
        return hasNewWindowMenu ? .menu : .single
    }

    /// A browser whose new windows open on its own desktop (Arc) counts as single-window.
    static func opensWindowsElsewhere(_ bundleID: String) -> Bool {
        BrowserWindow.Kind(bundleID: bundleID)?.opensNewWindowsOnItsOwnDesktop == true
    }

    /// A web page's window: `.browser`, unless the browser it opens in (its host, or the one a
    /// Chrome-app page falls back to) opens new windows on its own desktop.
    static func forWeb(host: WebHost, configuredBrowser: String?) -> NewWindowClass {
        let opensIn = BrowserWindow.Kind(host: host)
            ?? WebHost.chromeAppFallback(configuredBrowser: configuredBrowser).flatMap { BrowserWindow.Kind(host: $0) }
        return opensIn?.opensNewWindowsOnItsOwnDesktop == true ? .single : .browser
    }

    var canOpenAnother: Bool { self != .single }
}

/// The dry run of an apply: for every slot, which window it would use, where that window
/// is now and what apply will do to get it into its region. Pure, so the decision table
/// is unit tested against fake window lists.
enum PlacementPlan {
    enum Action: String, Equatable {
        /// Already in its region.
        case stay
        /// Same display and desktop: move/resize in place (or restore from the Dock).
        case resize
        /// On another display (its showing desktop): moved across.
        case move
        /// A desktop has to be shown first: the slot's own desktop, or the one the window is on.
        case switchSpace
        /// No usable window: launch the app or ask it for a new window.
        case launch
        /// Left where it is (`spaces.policy = leave`).
        case leave
        /// Cannot be placed; `reason` says why.
        case cannot
    }

    struct Screen: Equatable {
        var name: String
        var frame: CGRect
        /// 1-based desktop showing now.
        var currentSpace: Int?
        var spaces: Int = 1
        /// The desktops this display can be switched to from the one showing and back again with
        /// the Mission Control shortcuts that are on; nil when that is not known.
        var switchable: Set<Int>? = nil

        func canSwitch(to desktop: Int) -> Bool { switchable?.contains(desktop) ?? true }

        /// The desktops reachable there and back from `current` (`Spaces.route`); nil when the
        /// showing desktop is unknown.
        static func switchable(current: Int?, count: Int, shortcuts: (Int) -> Spaces.Shortcut?) -> Set<Int>? {
            guard let current else { return nil }
            return Set((1...max(count, 1)).filter { n in
                guard case .success = Spaces.route(to: n, current: current, count: count, shortcuts: shortcuts),
                      case .success = Spaces.route(to: current, current: n, count: count, shortcuts: shortcuts)
                else { return false }
                return true
            })
        }
    }

    /// A window the occupant could use.
    struct Candidate: Equatable {
        var number: Int
        var title: String = ""
        /// Cocoa coordinates.
        var frame: CGRect
        /// Index into the screens; nil when unknown.
        var screen: Int?
        /// 1-based desktop on that screen; nil when unknown (or on every desktop).
        var space: Int?
        /// On a desktop that is showing now (a hidden app's window there included).
        var visible: Bool
        var minimized: Bool = false
        /// Its app is hidden (⌘H): placing the window unhides the app, which does not bring it forward.
        var hidden: Bool = false
    }

    enum Kind: Equatable { case app, web, panel }

    /// Whether multi-desktop loadouts are on (see `ExperimentalLoadouts`).
    enum Mode: Equatable {
        /// On: a slot may name a desktop, and `spaces.policy` decides what happens to a window on
        /// a desktop that is not showing.
        case multiDesktop(SpacesPolicy)
        /// Off: the desktop showing. A slot's desktop is not read, and `SpacesPolicy.oneScreen`
        /// decides instead of `spaces.policy`: only a single-window app's window is fetched from
        /// another desktop.
        case oneScreen

        /// As `apply … plan=1` reports it (`policy`).
        var name: String {
            switch self {
            case .multiDesktop(let policy): return policy.rawValue
            case .oneScreen: return "oneScreen"
            }
        }
    }

    struct SlotInput {
        var regionID: String
        var regionName: String
        var occupant: String
        var kind: Kind = .app
        /// Index into the screens.
        var screen: Int
        /// Desktop the slot asks for; nil means whichever is showing.
        var space: Int?
        /// Cocoa coordinates of the region on that screen.
        var rect: CGRect
        /// Usable windows, front to back.
        var candidates: [Candidate] = []
        var running: Bool = false
        var installed: Bool = true
        var newWindow: NewWindowClass = .menu
        /// A reason apply fails the slot before looking at windows (no such region…).
        var blocked: String? = nil
    }

    struct Location: Equatable {
        var screen: String? = nil
        var space: Int? = nil
        var frame: CGRect? = nil

        var json: [String: Any] {
            var d: [String: Any] = [:]
            if let screen { d["screen"] = screen }
            if let space { d["space"] = space }
            if let frame {
                d["frame"] = ["x": Int(frame.minX.rounded()), "y": Int(frame.minY.rounded()),
                              "w": Int(frame.width.rounded()), "h": Int(frame.height.rounded())]
            }
            return d
        }
    }

    /// How an existing window on a hidden desktop is fetched.
    enum Bring: Equatable {
        /// Show desktop `space` on the window's display, move it to the target display, switch back.
        case acrossDisplays(fromScreen: Int, space: Int)
        /// Same display: show its desktop, park it on `via` (another display), switch back, move it home.
        case hop(screen: Int, space: Int, via: Int)
    }

    struct Step: Equatable {
        var regionID: String
        var regionName: String
        var occupant: String
        var action: Action
        var from: Location?
        var to: Location
        var reason: String
        /// Window-server number of the window apply will use.
        var window: Int?
        /// Set when apply fetches the window from another desktop.
        var bring: Bring?
        /// Set when apply must open a new window without activating the app.
        var newWindow: Bool = false

        var json: [String: Any] {
            var d: [String: Any] = ["slot": regionID, "region": regionName, "occupant": occupant,
                                    "action": action.rawValue, "to": to.json, "reason": reason]
            if let from { d["from"] = from.json }
            if let window { d["window"] = window }
            return d
        }

        /// Whether apply is expected to end with the window in its region.
        var places: Bool { ![.leave, .cannot].contains(action) }
    }

    private static func name(_ screens: [Screen], _ i: Int?) -> String? {
        i.flatMap { screens.indices.contains($0) ? screens[$0].name : nil }
    }

    static func step(for slot: SlotInput, screens: [Screen], mode: Mode) -> Step {
        let policy: SpacesPolicy
        let slotSpace: Int?
        switch mode {
        case .multiDesktop(let chosen):
            policy = chosen
            slotSpace = slot.space
        case .oneScreen:
            policy = .oneScreen(slot.newWindow)
            slotSpace = nil
        }
        let target = screens.indices.contains(slot.screen) ? screens[slot.screen] : nil
        let showing = target?.currentSpace
        let wantedSpace = slotSpace ?? showing
        let needsSwitch = slotSpace != nil && slotSpace != showing
        let to = Location(screen: target?.name, space: wantedSpace, frame: slot.rect)
        var step = Step(regionID: slot.regionID, regionName: slot.regionName, occupant: slot.occupant,
                        action: .cannot, from: nil, to: to, reason: "")
        if let blocked = slot.blocked {
            step.reason = blocked
            return step
        }
        guard target != nil else {
            step.reason = "display not attached"
            return step
        }
        let switchNote = needsSwitch ? "show desktop \(slotSpace!) on \(target!.name), then " : ""

        guard let window = choose(slot.candidates, target: slot.screen, space: wantedSpace) else {
            // Nothing to reuse.
            if !slot.installed {
                step.reason = "\(slot.occupant) is not installed"
                return step
            }
            step.action = needsSwitch ? .switchSpace : .launch
            switch slot.kind {
            case .app:
                step.reason = switchNote + (slot.running ? "ask \(slot.occupant) for a window" : "launch \(slot.occupant)")
            case .web:
                step.reason = switchNote + "open a window for it"
            case .panel:
                step.reason = switchNote + "show the panel"
            }
            return step
        }

        step.window = window.number
        step.from = Location(screen: name(screens, window.screen), space: window.space, frame: window.frame)

        // A window MacHUD can reach once the slot's desktop is showing. A window on
        // this display's showing desktop is left behind when the slot asks for another.
        let onTarget = window.screen == slot.screen
        let reachable: Bool
        if window.minimized {
            reachable = true
        } else if window.visible {
            reachable = !(needsSwitch && onTarget && window.space != nil && window.space != wantedSpace)
        } else {
            reachable = needsSwitch && onTarget && window.space != nil && window.space == wantedSpace
        }
        if reachable {
            let unhide = window.hidden ? "unhide it and " : ""
            if needsSwitch {
                step.action = .switchSpace
                step.reason = switchNote + unhide + (onTarget || window.minimized || window.screen == nil
                    ? "place it" : "move it from \(name(screens, window.screen) ?? "?")")
            } else if window.minimized {
                step.action = .resize
                step.reason = "restore it from the Dock"
            } else if !onTarget {
                step.action = .move
                step.reason = unhide + "move it from \(name(screens, window.screen) ?? "another display")"
            } else if matches(window.frame, slot.rect) {
                step.action = window.hidden ? .resize : .stay
                step.reason = window.hidden ? "unhide it, already in place" : "already in place"
            } else {
                step.action = .resize
                step.reason = unhide + "move/resize in place"
            }
            return step
        }

        // Its only window is on a desktop that is not showing.
        let desktop = "desktop \(window.space.map(String.init) ?? "?")"
            + (window.screen.flatMap { name(screens, $0) }.map { " of \($0)" } ?? "")
        let whereNow = "on \(desktop)"
        func launchNew(_ why: String) -> Step {
            var s = step
            if slot.newWindow.canOpenAnother {
                s.action = .launch
                s.newWindow = true
                s.window = nil
                s.reason = "\(why)open a new \(slot.occupant) window here; the one \(whereNow) stays"
            } else if mode == .oneScreen {
                let note = why.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
                s.action = .cannot
                s.reason = "\(slot.occupant) has one window, on another desktop (\(desktop)\(note.isEmpty ? "" : "; \(note)"))"
            } else {
                s.action = .cannot
                s.reason = "\(slot.occupant) has one window, \(whereNow)\(why.isEmpty ? "" : " (\(why.trimmingCharacters(in: CharacterSet(charactersIn: "; "))))")"
            }
            return s
        }
        switch policy {
        case .leave:
            step.action = .leave
            step.reason = "left \(whereNow) (spaces.policy leave)"
            return step
        case .launchNew:
            return launchNew("")
        case .bring:
            guard let space = window.space, let from = window.screen else {
                return launchNew("its desktop is unknown; ")
            }
            guard screens[from].canSwitch(to: space) else {
                return launchNew("MacHUD cannot switch desktops there: \(Spaces.SwitchError.shortcutDisabled.message); ")
            }
            if from != slot.screen {
                step.action = .switchSpace
                step.bring = .acrossDisplays(fromScreen: from, space: space)
                step.reason = "show desktop \(space) on \(name(screens, from) ?? "?"), move it to \(target!.name), switch back"
                return step
            }
            if let via = screens.indices.first(where: { $0 != slot.screen }) {
                step.action = .switchSpace
                step.bring = .hop(screen: from, space: space, via: via)
                step.reason = "show desktop \(space), hop it through \(screens[via].name), switch back"
                return step
            }
            return launchNew("one display, and macOS cannot move windows between its desktops; ")
        }
    }

    /// The window a slot will use: one already where it belongs, then one on another
    /// display, then a minimized one, then one on a hidden desktop — front to back within each.
    static func choose(_ candidates: [Candidate], target: Int, space: Int?) -> Candidate? {
        func rank(_ c: Candidate) -> Int {
            if c.visible && c.screen == target { return 0 }
            if !c.visible && !c.minimized && c.screen == target && c.space != nil && c.space == space { return 1 }
            if c.visible { return 2 }
            if c.minimized { return 3 }
            return 4
        }
        return candidates.enumerated().min { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }?.element
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
            && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }

    /// One line for the toast.
    static func summary(_ step: Step) -> String {
        "\(step.occupant): \(step.action.rawValue) — \(step.reason)"
    }
}
