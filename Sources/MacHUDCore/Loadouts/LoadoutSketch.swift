import AppKit
import HUDKit

/// A loadout drawn without looking at any window: every slot's region on the display and
/// desktop apply would use, from the same grouping (`LoadoutPlan`), display fallback
/// (`ScreenFallback`) and region geometry (`LoadoutEngine.regionRect`) apply uses. The
/// settings window's Loadouts tab draws it. Pure, so it is unit tested with fake displays.
struct LoadoutSketch: Equatable {
    /// An attached display as the sketch needs it.
    struct Display: Equatable {
        var descriptor: ScreenDescriptor
        /// Cocoa coordinates, as `NSScreen.frame` / `visibleFrame`.
        var frame: CGRect
        var visible: CGRect
        var desktops: ScreenFallback.Desktops = .unknown

        var name: String { descriptor.name }
    }

    /// One slot where apply would put it.
    struct Region: Equatable, Identifiable {
        var regionID: String
        var name: String
        var occupant: Occupant
        /// Index into `displays`.
        var display: Int
        /// 1-based desktop; nil means whichever desktop is showing.
        var desktop: Int?
        /// Cocoa coordinates on that display.
        var rect: CGRect
        var z: Int = 0
        /// The edge a parked slot hides behind.
        var parked: HUDEdge? = nil
        /// The display the loadout names when it is not attached and this one stands in.
        var redirectedFrom: String? = nil

        var id: String { "\(display):\(desktop ?? 0):\(regionID)" }
    }

    /// A sibling panel the loadout's HUD part shows, at the frame it saved.
    struct HUDPanel: Equatable, Identifiable {
        var app: String
        var panel: String
        var visible: Bool
        var mode: HUDPanelMode?
        var frame: CGRect?

        var id: String { "\(app)/\(panel)" }
    }

    var displays: [Display]
    var regions: [Region]
    /// Where each display's part comes from, one line each ("DELL S2722QC → Built-in, desktop 2").
    var notes: [String] = []
    /// What cannot be drawn: missing layouts or regions, displays with nowhere to go.
    var problems: [String] = []
    var dock: HUDDockPosition?
    var hudPanels: [HUDPanel] = []

    /// The desktop keys the regions use, in order: nil (whichever is showing) first.
    var desktops: [Int?] {
        var out: [Int?] = []
        for region in regions where !out.contains(region.desktop) { out.append(region.desktop) }
        return out.sorted { a, b in
            switch (a, b) {
            case (nil, _?): return true
            case (let x?, let y?): return x < y
            default: return false
            }
        }
    }

    /// The regions on `desktop`, back to front.
    func regions(on desktop: Int?) -> [Region] {
        regions.enumerated().filter { $0.element.desktop == desktop }
            .sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element)
    }

    /// The union of every display's frame.
    var bounds: CGRect { displays.map(\.frame).reduce(CGRect.null) { $0.union($1) } }

    /// Displays with something on them.
    var usedDisplays: [Int] { Array(Set(regions.map(\.display))).sorted() }

    static func build(_ loadout: Loadout, layouts: [Layout], displays: [Display], gap: CGFloat) -> LoadoutSketch {
        var sketch = LoadoutSketch(displays: displays, regions: [])
        if let hud = loadout.hud {
            sketch.dock = hud.dock?.position
            for (app, entry) in (hud.apps ?? [:]).sorted(by: { $0.key < $1.key }) {
                for (panel, state) in entry.panels.sorted(by: { $0.key < $1.key }) {
                    sketch.hudPanels.append(HUDPanel(app: app, panel: panel, visible: state.visible ?? false,
                                                     mode: state.mode, frame: state.frame?.rect))
                }
            }
        }
        let descriptors = displays.map(\.descriptor)
        let assignments = loadout.screens ?? []
        let outcomes = ScreenFallback.plan(ScreenFallback.requests(for: loadout), screens: descriptors,
                                           policy: loadout.screenMissingPolicy,
                                           desktops: { displays.indices.contains($0) ? displays[$0].desktops : .unknown })
        for (index, outcome) in outcomes.enumerated() {
            let label = assignments[index].screen.label
            switch outcome {
            case .present:
                break
            case .redirected(let screen, let space):
                sketch.notes.append("\(label) is not attached: shown on \(displays[screen].name), desktop \(space)")
            case .needsDesktops(let screen, let count):
                sketch.problems.append("\(label) is not attached and \(displays[screen].name) needs \(count) desktops")
            case .skipped:
                sketch.problems.append("\(label) is not attached (skipped)")
            }
        }
        let main = ScreenRef.main.index(in: descriptors)
        for group in LoadoutPlan.groups(for: loadout) where !group.slots.isEmpty {
            var display: Int
            var desktop = group.space
            var redirectedFrom: String?
            if let index = group.assignment {
                switch outcomes[index] {
                case .present(let screen, _):
                    display = screen
                case .redirected(let screen, let space):
                    display = screen
                    desktop = space
                    redirectedFrom = assignments[index].screen.label
                case .needsDesktops, .skipped:
                    continue
                }
            } else {
                // The one-screen form goes to the display under the pointer; draw it on the main one.
                guard let main else { sketch.problems.append("no display"); continue }
                display = main
            }
            guard let layout = layouts.first(where: { $0.name == group.layout }) else {
                let problem = "no layout named \(group.layout)"
                if !sketch.problems.contains(problem) { sketch.problems.append(problem) }
                continue
            }
            for slot in group.slots {
                guard let i = layout.regionIndex(id: slot.regionID) else {
                    sketch.problems.append("\(slot.occupant.label): no such region in \(layout.name)")
                    continue
                }
                let region = layout.regions[i]
                sketch.regions.append(Region(
                    regionID: slot.regionID, name: region.name ?? "Region \(i + 1)", occupant: slot.occupant,
                    display: display, desktop: desktop,
                    rect: LoadoutEngine.regionRect(region, visible: displays[display].visible, gap: gap),
                    z: slot.stackOrder, parked: slot.isParked ? slot.parkEdge : nil, redirectedFrom: redirectedFrom))
            }
        }
        return sketch
    }
}

extension LoadoutSketch.Display {
    /// The attached displays, with their desktops.
    @MainActor
    static func attached() -> [LoadoutSketch.Display] {
        let monitors = Spaces.monitors()
        return NSScreen.screens.map { screen in
            let monitor = Spaces.monitor(for: screen, in: monitors)
            return LoadoutSketch.Display(descriptor: screen.descriptor, frame: screen.frame, visible: screen.visibleFrame,
                                         desktops: ScreenFallback.Desktops(count: monitor?.count ?? 1,
                                                                           current: monitor?.currentIndex))
        }
    }
}

extension Loadout {
    /// How many displays the loadout was made for: one per display it names, plus one for
    /// the one-screen form when it has slots. A HUD-only loadout has none.
    var screenCount: Int {
        var refs: [ScreenRef] = []
        for assignment in screens ?? [] where !refs.contains(assignment.screen) { refs.append(assignment.screen) }
        return refs.count + (slots.isEmpty ? 0 : 1)
    }

    /// How many desktops its slots name (1 when none does, 0 for a HUD-only loadout).
    var desktopCount: Int {
        guard !allSlots.isEmpty else { return 0 }
        var spaces = Set(slots.compactMap(\.space))
        for assignment in screens ?? [] {
            for slot in assignment.slots { if let space = slot.space ?? assignment.space { spaces.insert(space) } }
        }
        return max(spaces.count, 1)
    }
}
