import AppKit

/// Which display part of a loadout targets. JSON form:
/// `{"display": "10ac-a0b4-4c4a3134", "name": "DELL S2722QC"}` (a persistent display id,
/// see `NSScreen.persistentID`, with the name as a fallback), `{"name": "DELL S2722QC"}`,
/// `{"index": 1}` (1-based position in `NSScreen.screens`), `{"main": true}` or
/// `{"builtin": true}`.
enum ScreenRef: Codable, Equatable, Hashable {
    /// Pinned to one physical display; `name` is used only when no attached display has `id`.
    case display(id: String, name: String)
    case name(String)
    case index(Int)
    case main
    case builtin

    private enum CodingKeys: String, CodingKey { case display, name, index, main, builtin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .display) {
            self = .display(id: id, name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
            return
        }
        if let name = try c.decodeIfPresent(String.self, forKey: .name) { self = .name(name); return }
        if let index = try c.decodeIfPresent(Int.self, forKey: .index) { self = .index(index); return }
        if try c.decodeIfPresent(Bool.self, forKey: .builtin) == true { self = .builtin; return }
        if try c.decodeIfPresent(Bool.self, forKey: .main) == true { self = .main; return }
        throw DecodingError.dataCorruptedError(
            forKey: .name, in: c, debugDescription: "screen needs one of name, index, main, builtin")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .display(let id, let name):
            try c.encode(id, forKey: .display)
            if !name.isEmpty { try c.encode(name, forKey: .name) }
        case .name(let name): try c.encode(name, forKey: .name)
        case .index(let index): try c.encode(index, forKey: .index)
        case .main: try c.encode(true, forKey: .main)
        case .builtin: try c.encode(true, forKey: .builtin)
        }
    }

    /// Short form used in reports and on the command line.
    var label: String {
        switch self {
        case .display(let id, let name): return name.isEmpty ? id : name
        case .name(let name): return name
        case .index(let index): return "\(index)"
        case .main: return "main"
        case .builtin: return "builtin"
        }
    }

    /// `main`, `builtin`, a 1-based index, or a display name.
    static func parse(_ text: String) -> ScreenRef? {
        let key = text.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        switch key.lowercased() {
        case "main": return .main
        case "builtin", "built-in", "internal": return .builtin
        default: break
        }
        if let index = Int(key) { return .index(index) }
        return .name(key)
    }
}

/// A display reduced to the properties picking one depends on.
struct ScreenDescriptor: Equatable {
    var name: String
    var isMain: Bool
    var isBuiltin: Bool
    /// `NSScreen.persistentID`; nil when the display reports no vendor/model/serial.
    var persistentID: String? = nil
}

extension ScreenRef {
    /// Position of the display this refers to, or nil when it is not attached.
    /// Names match case-insensitively, exactly first, then as a substring so
    /// `{"name": "DELL"}` finds "DELL S2722QC".
    func index(in screens: [ScreenDescriptor]) -> Int? {
        switch self {
        case .display(let id, let name):
            if let pinned = screens.firstIndex(where: { $0.persistentID == id }) { return pinned }
            // Fallback by exact name only, and never onto a display that has an id of
            // its own of the same model: that one is a different physical screen.
            guard !name.isEmpty else { return nil }
            return screens.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame
                && ($0.persistentID.map { !Self.sameModel($0, id) } ?? true) }
        case .index(let n):
            return screens.indices.contains(n - 1) ? n - 1 : nil
        case .main:
            return screens.firstIndex { $0.isMain } ?? (screens.isEmpty ? nil : 0)
        case .builtin:
            return screens.firstIndex { $0.isBuiltin }
        case .name(let name):
            if let exact = screens.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                return exact
            }
            return screens.firstIndex { $0.name.range(of: name, options: .caseInsensitive) != nil }
        }
    }

    /// Two persistent ids (`vendor-model-serial`) for the same kind of display.
    static func sameModel(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "-"), pb = b.split(separator: "-")
        return pa.count == 3 && pb.count == 3 && pa[0] == pb[0] && pa[1] == pb[1]
    }

    func resolve() -> NSScreen? {
        let screens = NSScreen.screens
        guard let i = index(in: screens.map(\.descriptor)) else { return nil }
        return screens[i]
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    /// A display id that survives reconnecting, rearranging and rebooting:
    /// `<vendor>-<model>-<serial>` in hex, from the EDID. `NSScreenNumber` (the
    /// `CGDirectDisplayID`) is not stable across reconnects. Two identical displays that
    /// report no serial share an id; the first attached one wins.
    var persistentID: String? { Self.persistentID(displayID) }

    static func persistentID(_ display: CGDirectDisplayID) -> String? {
        let vendor = CGDisplayVendorNumber(display), model = CGDisplayModelNumber(display)
        let serial = CGDisplaySerialNumber(display)
        guard vendor != 0 || model != 0 || serial != 0 else { return nil }
        return String(format: "%x-%x-%x", vendor, model, serial)
    }

    /// How a capture refers to this display: the built-in one by role (its name
    /// differs between Macs), everything else pinned to the physical display.
    var ref: ScreenRef {
        if isBuiltin { return .builtin }
        return persistentID.map { .display(id: $0, name: localizedName) } ?? .name(localizedName)
    }

    var descriptor: ScreenDescriptor {
        ScreenDescriptor(name: localizedName, isMain: self == NSScreen.main || displayID == CGMainDisplayID(),
                         isBuiltin: isBuiltin, persistentID: persistentID)
    }

    /// How `com.apple.spaces` names this display: its UUID, or "Main".
    var spacesIdentifier: String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    var json: [String: Any] {
        ["name": localizedName, "display": Int(displayID), "persistentID": persistentID ?? "",
         "main": displayID == CGMainDisplayID(),
         "builtin": isBuiltin,
         "x": Int(frame.minX), "y": Int(frame.minY), "w": Int(frame.width), "h": Int(frame.height)]
    }
}

/// One display's share of a loadout: its own layout and slots.
struct ScreenAssignment: Codable, Equatable {
    var screen: ScreenRef
    var layout: String
    var slots: [Slot]
    /// Desktop this whole assignment belongs to, 1-based. A slot's own `space`
    /// wins; this is what a capture that walked the desktops writes.
    var space: Int? = nil
    /// Where to put this assignment when its display is not attached.
    var fallback: Fallback? = nil

    /// A stand-in display (and desktop) for a missing one. Either field may be
    /// left out: the screen defaults to the main display, the desktop to the
    /// lowest free one there.
    struct Fallback: Codable, Equatable {
        var screen: ScreenRef?
        var space: Int?
    }
}
