import AppKit

/// Fetching one window from a desktop that is not showing: show its desktop on its display,
/// move the window into its region (or park it on another display while its own one switches
/// back), and put every display back. Which desktop each display shows is recorded before the
/// first keystroke; nothing starts when the window's display cannot say. Every exit after the
/// first keystroke goes through one restore step that switches back each display that differs
/// from the record, so a failed step, an unreachable window or a switch that stopped part-way
/// still ends where it began. A display that cannot be switched back is reported ("left on
/// desktop 2 of DELL") and the fetch fails; it is never a success. Its world is passed in, so
/// each step is failed in tests.
@MainActor
enum DesktopFetch {
    struct World {
        /// The desktop each display shows now, by display index; nil where it cannot be told.
        var showing: () -> [Int?]
        /// A display's name, for messages.
        var displayName: (Int) -> String
        /// Switch `display` to `desktop`. It may stop part-way and say so.
        var switchTo: (_ desktop: Int, _ display: Int, _ done: @escaping (Result<Int, Spaces.SwitchError>) -> Void) -> Void
        /// The window once its desktop shows: how to put it in a frame (restoring it from the
        /// Dock first), or nil when accessibility cannot reach it or its app is gone.
        var reach: () -> ((CGRect) -> Void)?
        /// Whether the window is on a desktop showing now.
        var isOnScreen: () -> Bool
        var after: (_ seconds: TimeInterval, _ body: @escaping () -> Void) -> Void
    }

    struct Request {
        /// The display the window is on, and its desktop there.
        var home: Int
        var desktop: Int
        /// The window's region.
        var target: CGRect
        /// Where to park it on another display while `home` switches back, when the region is on
        /// `home` itself; nil when the region is on another display (the window moves there).
        var via: CGRect?
    }

    enum Outcome: Equatable {
        case fetched
        /// Not fetched; every display shows what it showed before.
        case failed(String)
        /// A display could not be put back; the reason says which and where it was left.
        case leftOnAnotherDesktop(String)
    }

    static func run(_ request: Request, world: World, completion: @escaping (Outcome) -> Void) {
        let record = world.showing()
        guard record.indices.contains(request.home), record[request.home] != nil else {
            completion(.failed("which desktop \(world.displayName(request.home)) is showing is unknown"))
            return
        }

        /// Put every display back on its recorded desktop; nil when that worked, else what was
        /// left where. Putting one display back can move another one already checked, so a
        /// second pass follows when any display still differs, and every display is read once
        /// more before the answer.
        func restore(_ done: @escaping (String?) -> Void) {
            var errors: [Int: String] = [:]
            func differs() -> Bool {
                let now = world.showing()
                return record.indices.contains { record[$0] != nil && now.indices.contains($0) && now[$0] != record[$0] }
            }
            func pass(_ then: @escaping () -> Void) {
                var displays = Array(record.indices)
                func next() {
                    guard !displays.isEmpty else { then(); return }
                    let display = displays.removeFirst()
                    let now = world.showing()
                    guard let wanted = record[display], now.indices.contains(display),
                          let current = now[display], current != wanted else { next(); return }
                    world.switchTo(wanted, display) { result in
                        if case .failure(let error) = result { errors[display] = error.message } else { errors[display] = nil }
                        next()
                    }
                }
                next()
            }
            func answer() {
                let now = world.showing()
                var problems: [String] = []
                for display in record.indices {
                    guard let wanted = record[display], now.indices.contains(display) else { continue }
                    guard let landed = now[display] else {
                        problems.append("could not tell which desktop \(world.displayName(display)) is showing")
                        continue
                    }
                    guard landed != wanted else { continue }
                    problems.append("left on desktop \(landed) of \(world.displayName(display))"
                                    + (errors[display].map { " (\($0))" } ?? ""))
                }
                done(problems.isEmpty ? nil : problems.joined(separator: "; "))
            }
            pass { differs() ? pass(answer) : answer() }
        }

        /// The one way out once a keystroke has been typed.
        func finish(_ failure: String?) {
            restore { left in
                if let left {
                    completion(.leftOnAnotherDesktop(failure.map { "\($0); \(left)" } ?? left))
                    return
                }
                if let failure { completion(.failed(failure)); return }
                if request.via != nil { world.reach()?(request.target) }
                world.after(0.3) {
                    completion(world.isOnScreen() ? .fetched : .failed("it stayed on desktop \(request.desktop)"))
                }
            }
        }

        world.switchTo(request.desktop, request.home) { result in
            if case .failure(let error) = result { finish(error.message); return }
            guard let place = world.reach() else { finish("accessibility cannot reach it"); return }
            place(request.via ?? request.target)
            world.after(0.3) { finish(nil) }
        }
    }
}
