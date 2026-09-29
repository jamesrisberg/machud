import Foundation
import HUDKit

/// A change to the saved loadouts: what the settings window's Loadouts tab, the status
/// menu and the `loadouts` socket verb all do through `LoadoutLibrary`.
enum LoadoutEdit: Equatable {
    case rename(String, to: String)
    /// `as` nil picks "<name> copy" (then "copy 2", …).
    case duplicate(String, as: String?)
    case delete(String)
    /// nil clears `startupLoadout`.
    case startup(String?)
}

enum LoadoutEditError: Error, Equatable, CustomStringConvertible {
    case noSuchLoadout(String)
    case nameTaken(String)
    case emptyName

    var description: String {
        switch self {
        case .noSuchLoadout(let name): return "no loadout named \(name)"
        case .nameTaken(let name): return "a loadout named \(name) already exists"
        case .emptyName: return "a loadout needs a name"
        }
    }
}

/// What an edit changed besides the loadout itself.
struct LoadoutEditResult: Equatable {
    /// The loadout's name after the edit (the copy's for a duplicate); nil after a delete
    /// or a cleared startup loadout.
    var loadout: String?
    var removedLayouts: [String] = []
    /// Old name → new name.
    var renamedLayouts: [String: String] = [:]
    var addedLayouts: [String] = []

    var json: [String: Any] {
        var d: [String: Any] = ["ok": true]
        if let loadout { d["loadout"] = loadout }
        if !removedLayouts.isEmpty { d["removedLayouts"] = removedLayouts }
        if !renamedLayouts.isEmpty { d["renamedLayouts"] = renamedLayouts }
        if !addedLayouts.isEmpty { d["addedLayouts"] = addedLayouts }
        return d
    }
}

extension Loadout {
    /// Every layout the loadout places into: the one-screen form's and each display's.
    var layoutNames: [String] {
        var out: [String] = []
        for name in [layout] + (screens ?? []).map(\.layout) where !name.isEmpty && !out.contains(name) {
            out.append(name)
        }
        return out
    }
}

extension Config {
    /// The layouts that belong to loadout `name` alone: hidden ones (a capture keeps its
    /// layouts for its loadout only) that no other loadout uses. They go with it on delete
    /// and are renamed and copied with it.
    func ownedLayouts(of name: String) -> [String] {
        guard let loadout = loadouts?.first(where: { $0.name == name }) else { return [] }
        let others = Set((loadouts ?? []).filter { $0.name != name }.flatMap(\.layoutNames))
        return loadout.layoutNames.filter { layoutName in
            !others.contains(layoutName) && layouts.contains { $0.name == layoutName && $0.hidden == true }
        }
    }

    /// Apply `edit` to the config. Pure, so every edit is unit tested.
    mutating func apply(_ edit: LoadoutEdit) throws -> LoadoutEditResult {
        switch edit {
        case .rename(let old, let new): return try rename(old, to: new)
        case .duplicate(let name, let copyName): return try duplicate(name, as: copyName)
        case .delete(let name): return try delete(name)
        case .startup(let name):
            if let name, !name.isEmpty {
                guard loadout(named: name) != nil else { throw LoadoutEditError.noSuchLoadout(name) }
                startupLoadout = name
                return LoadoutEditResult(loadout: name)
            }
            startupLoadout = nil
            return LoadoutEditResult(loadout: nil)
        }
    }

    private func loadout(named name: String) -> Loadout? { loadouts?.first { $0.name == name } }

    /// A captured layout is named after its loadout (`Work`, `Work · DELL`, `Work · DELL ·
    /// Desktop 2`): the same name with the loadout's part swapped, else nil.
    private static func layoutName(_ layout: String, from old: String, to new: String) -> String? {
        if layout == old { return new }
        if layout.hasPrefix(old + " · ") { return new + layout.dropFirst(old.count) }
        return nil
    }

    private mutating func rename(_ old: String, to rawNew: String) throws -> LoadoutEditResult {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { throw LoadoutEditError.emptyName }
        guard let index = loadouts?.firstIndex(where: { $0.name == old }) else { throw LoadoutEditError.noSuchLoadout(old) }
        guard new != old else { return LoadoutEditResult(loadout: old) }
        guard loadout(named: new) == nil else { throw LoadoutEditError.nameTaken(new) }
        var result = LoadoutEditResult(loadout: new)
        let taken = Set(layouts.map(\.name))
        for layoutName in ownedLayouts(of: old) {
            guard let renamed = Self.layoutName(layoutName, from: old, to: new), !taken.contains(renamed),
                  let li = layouts.firstIndex(where: { $0.name == layoutName }) else { continue }
            layouts[li].name = renamed
            result.renamedLayouts[layoutName] = renamed
        }
        var loadout = loadouts![index]
        loadout.name = new
        loadout.retarget(result.renamedLayouts)
        loadouts![index] = loadout
        if startupLoadout == old { startupLoadout = new }
        return result
    }

    /// "<name> copy", "<name> copy 2", … whichever is free.
    func copyName(for name: String) -> String {
        let names = Set((loadouts ?? []).map(\.name))
        var candidate = "\(name) copy"
        var n = 2
        while names.contains(candidate) { candidate = "\(name) copy \(n)"; n += 1 }
        return candidate
    }

    private mutating func duplicate(_ name: String, as requested: String?) throws -> LoadoutEditResult {
        guard var copy = loadout(named: name) else { throw LoadoutEditError.noSuchLoadout(name) }
        let copyName = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.copyName(for: name)
        guard !copyName.isEmpty else { throw LoadoutEditError.emptyName }
        guard loadout(named: copyName) == nil else { throw LoadoutEditError.nameTaken(copyName) }
        var result = LoadoutEditResult(loadout: copyName)
        // The copy gets its own copies of the layouts the original owns, so editing one
        // never moves the other's regions. Shared (visible) layouts stay shared.
        var regionIDs: [String: String] = [:]
        var renamed: [String: String] = [:]
        for layoutName in ownedLayouts(of: name) {
            guard var layout = layouts.first(where: { $0.name == layoutName }) else { continue }
            var newName = Self.layoutName(layoutName, from: name, to: copyName) ?? "\(layoutName) copy"
            var n = 2
            let base = newName
            while layouts.contains(where: { $0.name == newName }) { newName = "\(base) \(n)"; n += 1 }
            layout.name = newName
            for ri in layout.regions.indices {
                let fresh = UUID().uuidString.lowercased()
                if let old = layout.regions[ri].id { regionIDs[old] = fresh }
                layout.regions[ri].id = fresh
            }
            layouts.append(layout)
            renamed[layoutName] = newName
            result.addedLayouts.append(newName)
        }
        copy.name = copyName
        // A hotkey applies one loadout; the copy starts without it.
        copy.hotkey = nil
        copy.retarget(renamed, regionIDs: regionIDs)
        loadouts = (loadouts ?? []) + [copy]
        return result
    }

    private mutating func delete(_ name: String) throws -> LoadoutEditResult {
        guard loadout(named: name) != nil else { throw LoadoutEditError.noSuchLoadout(name) }
        let owned = ownedLayouts(of: name)
        layouts.removeAll { owned.contains($0.name) }
        loadouts = (loadouts ?? []).filter { $0.name != name }
        if startupLoadout == name { startupLoadout = nil }
        return LoadoutEditResult(loadout: nil, removedLayouts: owned)
    }
}

extension Loadout {
    /// Point the loadout at renamed layouts (and, for a copy, at its layouts' new region ids).
    mutating func retarget(_ layoutNames: [String: String], regionIDs: [String: String] = [:]) {
        func remap(_ slots: [Slot], layout: String) -> [Slot] {
            guard layoutNames[layout] != nil else { return slots }
            return slots.map { slot in
                var slot = slot
                slot.regionID = regionIDs[slot.regionID] ?? slot.regionID
                return slot
            }
        }
        slots = remap(slots, layout: layout)
        if let renamed = layoutNames[layout] { layout = renamed }
        if var assignments = screens {
            for i in assignments.indices {
                let old = assignments[i].layout
                assignments[i].slots = remap(assignments[i].slots, layout: old)
                if let renamed = layoutNames[old] { assignments[i].layout = renamed }
            }
            screens = assignments
        }
    }
}

/// The one place loadouts are renamed, copied, deleted and made the startup loadout. Saves
/// through the store (which the file watcher and every view follow) and tells the engine,
/// which remembers the applied loadout by name.
@MainActor
final class LoadoutLibrary {
    let store: LayoutStore
    /// Called after every successful edit (the engine follows renames and deletes).
    var onEdit: ((LoadoutEdit, LoadoutEditResult) -> Void)?

    init(store: LayoutStore) {
        self.store = store
    }

    @discardableResult
    func perform(_ edit: LoadoutEdit) throws -> LoadoutEditResult {
        var config = store.config
        let active = store.activeLayout?.name
        let result = try config.apply(edit)
        store.save(config)
        // Removing layouts shifts the snap layout's index: keep it on the same layout.
        let activeName = active.flatMap { result.renamedLayouts[$0] ?? $0 }
        if let activeName, let i = store.layouts.firstIndex(where: { $0.name == activeName }),
           store.activeLayout?.name != activeName {
            store.select(index: i)
        }
        onEdit?(edit, result)
        return result
    }

    /// What to ask before deleting `name`: the question and, when it owns layouts, which
    /// ones go with it. The settings tab and the status menu both ask this.
    nonisolated static func deleteQuestion(_ name: String, ownedLayouts: [String]) -> (title: String, detail: String?) {
        let title = "Delete “\(name)”?"
        guard !ownedLayouts.isEmpty else { return (title, nil) }
        let what = ownedLayouts.count == 1 ? "the layout" : "the \(ownedLayouts.count) layouts"
        return (title, "Also removes \(what) captured for it: \(ownedLayouts.joined(separator: ", ")).")
    }

    static let actions = ["list", "rename", "duplicate", "delete", "startup"]

    /// `loadouts [list]|rename name= to=|duplicate name= [to=]|delete name=|startup [name=]`.
    func handle(_ args: [String: String]) -> [String: Any] {
        // `machud loadouts delete name=X` arrives as `_: delete, delete: 1, name: X`.
        let action = args["action"] ?? args["_"] ?? Self.actions.first { args[$0] == "1" } ?? "list"
        let name = args["name"] ?? args["loadout"]
        let edit: LoadoutEdit
        switch action {
        case "list":
            return ["ok": true, "startup": store.config.startupLoadout ?? "",
                    "loadouts": store.loadouts.map(Self.json)]
        case "rename":
            guard let name, let to = args["to"] else { return ["ok": false, "error": "loadouts rename needs name= and to="] }
            edit = .rename(name, to: to)
        case "duplicate":
            guard let name else { return ["ok": false, "error": "loadouts duplicate needs name="] }
            edit = .duplicate(name, as: args["to"])
        case "delete":
            guard let name else { return ["ok": false, "error": "loadouts delete needs name="] }
            edit = .delete(name)
        case "startup":
            let off = ["", "0", "none", "off"].contains((args["name"] ?? "").lowercased()) && args["loadout"] == nil
            edit = .startup(off ? nil : name)
        default:
            return ["ok": false, "error": "loadouts takes \(Self.actions.joined(separator: ", ")), not \(action)"]
        }
        do {
            return try perform(edit).json
        } catch {
            return ["ok": false, "error": "\(error)"]
        }
    }

    /// A loadout as `layouts.json` stores it.
    static func json(_ loadout: Loadout) -> [String: Any] {
        let data = (try? JSONEncoder().encode(loadout)) ?? Data()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? ["name": loadout.name]
    }
}
