import AppKit

extension LoadoutEngine {
    /// Display- and desktop-aware control commands. Registered after the basic
    /// ones so `status` and `capture` gain their `screen=` / `screens=` forms.
    func registerScreensControl(_ control: ControlServer) {
        control.register("screens") { _, done in
            let monitors = Spaces.monitors()
            let screens = NSScreen.screens.enumerated().map { index, screen -> [String: Any] in
                var d = screen.json
                d["index"] = index + 1
                if let monitor = Spaces.monitor(for: screen, in: monitors) {
                    d["display"] = monitor.identifier
                    d["spaces"] = monitor.count
                    d["currentSpace"] = monitor.currentIndex ?? 0
                }
                return d
            }
            done(["ok": true, "screens": screens])
        }

        control.register("spaces") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            if let refusal = MultiDesktopVerbs.refusal(spaces: args, in: self.store.config) {
                done(["ok": false, "error": refusal]); return
            }
            let monitors = Spaces.monitors()
            let ref = args["screen"].flatMap { ScreenRef.parse($0) }
            guard let screen = ref.map({ $0.resolve() }) ?? NSScreen.main else {
                done(["ok": false, "error": "no screen matching \(ref?.label ?? "main")"]); return
            }
            guard let monitor = Spaces.monitor(for: screen, in: monitors) else {
                done(["ok": false, "error": Spaces.SwitchError.noDesktops.message]); return
            }
            guard (args["action"] ?? "status") == "switch" else {
                done(["ok": true, "screen": screen.localizedName, "spaces": monitor.count,
                      "currentSpace": monitor.currentIndex ?? 0,
                      "shortcuts": Self.shortcutReport(count: monitor.count),
                      "privateAPI": SpacesPrivate.isAvailable])
                return
            }
            guard let n = args["n"].flatMap({ Int($0) }) else {
                done(["ok": false, "error": "n=<desktop> required"]); return
            }
            Spaces.switchTo(n, on: screen) { result in
                switch result {
                case .success(let index):
                    done(["ok": true, "screen": screen.localizedName, "currentSpace": index])
                case .failure(let error):
                    done(["ok": false, "error": error.reason, "message": error.message,
                          "spaces": monitor.count, "currentSpace": monitor.currentIndex ?? 0])
                }
            }
        }

        control.register("status") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            let ref = args["screen"].flatMap { ScreenRef.parse($0) }
            if let ref, ref.resolve() == nil {
                done(["ok": false, "error": "no screen matching \(ref.label)"]); return
            }
            var response: [String: Any] = ["ok": true, "layout": self.store.activeLayout?.name ?? "",
                                          "activeLoadout": self.activeLoadout ?? "",
                                          "regions": self.status(screen: ref?.resolve()).map { $0.json }]
            if self.redirectLoadout == self.activeLoadout, !self.redirects.isEmpty {
                response["redirected"] = self.redirects.map(\.json)
            }
            done(response)
        }

        control.register("capture") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            self.handleCapture(args, done: done)
        }
    }

    /// The `capture` verb (see docs/API.md).
    func handleCapture(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        guard let name = args["name"], !name.isEmpty else {
            done(["ok": false, "error": "name required"]); return
        }
        if let refusal = MultiDesktopVerbs.refusal(capture: args, in: self.store.config) {
            done(["ok": false, "error": refusal]); return
        }
        // `hud=only`: just the tool dock and the siblings' panels; `hud=1`: the windows
        // as below, then the HUD added to the same loadout.
        let hudMode = args["hud"]?.lowercased()
        if hudMode == "only" {
            self.captureHUD(into: name) { loadout in
                guard let loadout else { done(["ok": false, "error": "HUD capture is not available"]); return }
                done(["ok": true, "slots": loadout.allSlots.count, "loadout": Self.json(loadout)])
            }
            return
        }
        let withHUD = ["1", "true", "yes", "on"].contains(hudMode ?? "")
        let done: ([String: Any]) -> Void = { [weak self] reply in
            guard withHUD, reply["ok"] as? Bool == true, let self else { done(reply); return }
            self.captureHUD(into: name) { loadout in
                var reply = reply
                if let loadout {
                    reply["loadout"] = Self.json(loadout)
                    reply["hud"] = Self.json(loadout)["hud"]
                }
                done(reply)
            }
        }
        let screensArg = args["screens"]
        let allScreens = screensArg.map { ["all", "*"].contains($0.lowercased()) } ?? false

        // Derive the layouts from the windows themselves, across displays
        // and (with `desktops=`) desktops.
        if allScreens || (screensArg == nil && args["desktops"] != nil) {
            var walk: DesktopWalk?
            if let text = args["desktops"] {
                switch DesktopWalk.parse(text) {
                case .error(let message): done(["ok": false, "error": message]); return
                case .walk(let parsed): walk = parsed
                }
            }
            var targets = NSScreen.screens
            if !allScreens {
                let ref = args["screen"].flatMap { ScreenRef.parse($0) }
                if let ref, ref.resolve() == nil {
                    done(["ok": false, "error": "no screen matching \(ref.label)"]); return
                }
                guard let one = ref?.resolve() ?? self.screen(nil) else {
                    done(["ok": false, "error": "no screen"]); return
                }
                targets = [one]
            }
            self.captureArrangement(name: name, screens: targets, walk: walk) { capture in
                guard let capture else {
                    done(["ok": false, "error": "no windows on those screens"]); return
                }
                self.commit(capture)
                done(capture.json.merging(["ok": true]) { a, _ in a })
            }
            return
        }

        let loadout: Loadout
        if let screens = screensArg {
            switch self.parseCaptureScreens(screens) {
            case .error(let message): done(["ok": false, "error": message]); return
            case .assignments(let assignments): loadout = self.capture(name: name, assignments: assignments)
            }
        } else if let layoutName = args["layout"] {
            guard let layout = self.store.layout(named: layoutName) else {
                done(["ok": false, "error": "no such layout"]); return
            }
            let ref = args["screen"].flatMap { ScreenRef.parse($0) }
            if let ref, ref.resolve() == nil {
                done(["ok": false, "error": "no screen matching \(ref.label)"]); return
            }
            loadout = self.capture(name: name, layout: layout, screen: ref?.resolve())
        } else {
            // Default: derive the layout from the windows themselves.
            let ref = args["screen"].flatMap { ScreenRef.parse($0) }
            if let ref, ref.resolve() == nil {
                done(["ok": false, "error": "no screen matching \(ref.label)"]); return
            }
            guard let capture = self.captureArrangement(name: name, screen: ref?.resolve()) else {
                done(["ok": false, "error": "no windows on that screen"]); return
            }
            self.commit(capture)
            done(capture.json.merging(["ok": true]) { a, _ in a })
            return
        }
        var captured = loadout
        captured.hud = self.store.loadout(named: name)?.hud
        self.store.upsert(captured)
        done(["ok": true, "slots": captured.allSlots.count, "loadout": Self.json(captured)])
    }

    static func json(_ loadout: Loadout) -> [String: Any] {
        let data = (try? JSONEncoder().encode(loadout)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Which Mission Control shortcuts are available for switching desktops.
    private static func shortcutReport(count: Int) -> [String: Any] {
        var direct: [Int] = []
        for n in 1...max(count, 1) where Spaces.shortcut(Spaces.Key.desktop(n))?.enabled == true {
            direct.append(n)
        }
        return ["switchToDesktop": direct,
                "moveLeft": Spaces.shortcut(Spaces.Key.moveLeft)?.enabled ?? false,
                "moveRight": Spaces.shortcut(Spaces.Key.moveRight)?.enabled ?? false]
    }
}

/// The socket forms that exist only for loadouts spanning several desktops or displays, and the
/// names of loadouts held back, and why each is refused while `experimental.multiDesktopLoadouts`
/// is off (see `ExperimentalLoadouts`). Pure, so the forms are unit tested.
enum MultiDesktopVerbs {
    /// `capture screens=all`, `desktops=…` and `screens=<layout>@<ref>,…`, and any capture
    /// (`hud=only` too) into the name of a loadout held back, which it would replace unseen; nil
    /// for the one-screen forms (the default, `screen=`, `layout=`) and `hud=only` otherwise.
    static func refusal(capture args: [String: String], in config: Config) -> String? {
        if args["hud"]?.lowercased() != "only" {
            var action: String?
            if let screens = args["screens"] {
                action = ["all", "*"].contains(screens.lowercased()) ? "Capturing every screen" : "Capturing a layout per display"
            } else if args["desktops"] != nil {
                action = "Walking desktops"
            }
            if let action, let refusal = ExperimentalLoadouts.refusal(forAction: action, in: config) { return refusal }
        }
        return args["name"].flatMap { ExperimentalLoadouts.refusal(forName: $0, in: config) }
    }

    /// `spaces action=switch`; reading the desktops is never refused.
    static func refusal(spaces args: [String: String], in config: Config) -> String? {
        guard args["action"] == "switch" else { return nil }
        return ExperimentalLoadouts.refusal(forAction: "Switching desktops", in: config)
    }
}
