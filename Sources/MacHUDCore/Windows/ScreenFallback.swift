import AppKit

/// Where each per-display assignment of a loadout actually goes when some of
/// the displays it was captured on are not attached. Pure, so the allocation is
/// unit tested.
enum ScreenFallback {
    /// One assignment reduced to what the decision depends on.
    struct Request: Equatable {
        var screen: ScreenRef
        var space: Int?
        var fallback: ScreenAssignment.Fallback?
    }

    /// What a display can offer: how many desktops it has and which one is showing.
    struct Desktops: Equatable {
        var count: Int
        var current: Int?

        static let unknown = Desktops(count: 1, current: 1)
    }

    enum Outcome: Equatable {
        /// The display is attached; use it as captured.
        case present(screen: Int, space: Int?)
        /// The display is missing; this one stands in, on this desktop.
        case redirected(screen: Int, space: Int)
        /// `whenScreenMissing: "skip"`, or there is no display at all.
        case skipped
        /// The stand-in display would need this many desktops.
        case needsDesktops(screen: Int, count: Int)
    }

    /// Decide for every assignment in turn. Assignments whose display is
    /// attached keep their desktop and reserve it, so a redirected one lands
    /// somewhere nothing else is using.
    static func plan(_ requests: [Request], screens: [ScreenDescriptor],
                     policy: ScreenMissingPolicy,
                     desktops: (Int) -> Desktops) -> [Outcome] {
        var used: [Int: Set<Int>] = [:]
        var resolved: [Int?] = []
        for request in requests {
            let index = request.screen.index(in: screens)
            resolved.append(index)
            if let index {
                let space = request.space ?? desktops(index).current ?? 1
                used[index, default: []].insert(space)
            }
        }

        let mainIndex = ScreenRef.main.index(in: screens)
        var deficit: [Int: Int] = [:]
        var out: [Outcome] = []
        for (i, request) in requests.enumerated() {
            if let index = resolved[i] {
                out.append(.present(screen: index, space: request.space))
                continue
            }
            guard policy == .desktop else { out.append(.skipped); continue }
            let target = request.fallback?.screen?.index(in: screens) ?? mainIndex
            guard let target else { out.append(.skipped); continue }
            let room = desktops(target)
            if let wanted = request.fallback?.space {
                guard wanted <= room.count else {
                    out.append(.needsDesktops(screen: target, count: wanted)); continue
                }
                used[target, default: []].insert(wanted)
                out.append(.redirected(screen: target, space: wanted))
                continue
            }
            let taken = used[target] ?? []
            guard let free = (1...max(room.count, 1)).first(where: { !taken.contains($0) && $0 <= room.count }) else {
                deficit[target, default: 0] += 1
                out.append(.needsDesktops(screen: target, count: taken.count + (deficit[target] ?? 1)))
                continue
            }
            used[target, default: []].insert(free)
            out.append(.redirected(screen: target, space: free))
        }
        return out
    }
}
