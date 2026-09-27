import AppKit

extension LoadoutEngine {
    /// Engine-owned control commands. Call once at startup:
    /// `engine.registerControl(control)`.
    func registerControl(_ control: ControlServer) {
        control.register("restore") { [weak self] _, done in
            done(["ok": true, "restored": self?.restore() ?? 0])
        }
        control.register("clear") { [weak self] _, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            done(["ok": true, "cleared": self.clearAll()])
        }
        control.register("place") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "engine gone"]); return }
            guard let number = args["window"].flatMap({ Int($0) }) else {
                done(["ok": false, "error": "window=<number> required"]); return
            }
            guard let regionID = self.regionID(matching: args["region"] ?? "") else {
                done(["ok": false, "error": "region=<id|name|index> required"]); return
            }
            switch self.place(windowNumber: number, regionID: regionID) {
            case .placed(let rect):
                done(["ok": true, "window": number, "region": regionID,
                      "x": Int(rect.minX), "y": Int(rect.minY), "w": Int(rect.width), "h": Int(rect.height)])
            case .failed(let reason):
                done(["ok": false, "error": reason])
            }
        }
        registerScreensControl(control)
        registerParkingControl(control)
    }

    /// Regions may be named by id, by name or by 1-based position in the active layout.
    func regionID(matching key: String) -> String? {
        guard let layout = store.activeLayout, !key.isEmpty else { return nil }
        if let byID = layout.region(id: key)?.id { return byID }
        if let byName = layout.regions.first(where: { $0.name?.caseInsensitiveCompare(key) == .orderedSame }) { return byName.id }
        if let index = Int(key), layout.regions.indices.contains(index - 1) { return layout.regions[index - 1].id }
        return nil
    }
}
