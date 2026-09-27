import CoreGraphics
import Foundation

/// What apply does with an occupant whose only window is on a desktop that is not showing.
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
    /// Its menus have a plain ⌘N item that opens a window (TextEdit, Finder, terminals).
    case menu
    /// One window per app (Messages, Signal, Slack…): there is no second window to open.
    case single

    /// Chat and media apps whose ⌘N does not open a window (it starts a conversation or
    /// does nothing) or that refuse a second instance.
    static let singleWindowApps: Set<String> = [
        "com.apple.MobileSMS", "org.whispersystems.signal-desktop", "com.automattic.beeper.desktop",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "com.spotify.client", "com.apple.Music", "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2",
        "com.apple.systempreferences", "com.apple.AppStore",
    ]

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium", "company.thebrowser.Browser", "com.apple.Safari",
        "org.mozilla.firefox",
    ]

    static func of(bundleID: String, hasNewWindowMenu: Bool) -> NewWindowClass {
        if browsers.contains(bundleID) { return .browser }
        if singleWindowApps.contains(bundleID) { return .single }
        return hasNewWindowMenu ? .menu : .single
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
        /// On a desktop that is showing now.
        var visible: Bool
        var minimized: Bool = false
    }

    enum Kind: Equatable { case app, web, panel }

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

    static func plan(_ slots: [SlotInput], screens: [Screen], policy: SpacesPolicy) -> [Step] {
        slots.map { step(for: $0, screens: screens, policy: policy) }
    }

    private static func name(_ screens: [Screen], _ i: Int?) -> String? {
        i.flatMap { screens.indices.contains($0) ? screens[$0].name : nil }
    }

    static func step(for slot: SlotInput, screens: [Screen], policy: SpacesPolicy) -> Step {
        let target = screens.indices.contains(slot.screen) ? screens[slot.screen] : nil
        let showing = target?.currentSpace
        let wantedSpace = slot.space ?? showing
        let needsSwitch = slot.space != nil && slot.space != showing
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
        let switchNote = needsSwitch ? "show desktop \(slot.space!) on \(target!.name), then " : ""

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
            if needsSwitch {
                step.action = .switchSpace
                step.reason = switchNote + (onTarget || window.minimized || window.screen == nil
                    ? "place it" : "move it from \(name(screens, window.screen) ?? "?")")
            } else if window.minimized {
                step.action = .resize
                step.reason = "restore it from the Dock"
            } else if !onTarget {
                step.action = .move
                step.reason = "move it from \(name(screens, window.screen) ?? "another display")"
            } else if matches(window.frame, slot.rect) {
                step.action = .stay
                step.reason = "already in place"
            } else {
                step.action = .resize
                step.reason = "move/resize in place"
            }
            return step
        }

        // Its only window is on a desktop that is not showing.
        let whereNow = "on desktop \(window.space.map(String.init) ?? "?")"
            + (window.screen.flatMap { name(screens, $0) }.map { " of \($0)" } ?? "")
        func launchNew(_ why: String) -> Step {
            var s = step
            if slot.newWindow.canOpenAnother {
                s.action = .launch
                s.newWindow = true
                s.window = nil
                s.reason = "\(why)open a new \(slot.occupant) window here; the one \(whereNow) stays"
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
