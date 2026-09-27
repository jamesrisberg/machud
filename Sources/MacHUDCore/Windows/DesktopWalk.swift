import AppKit

/// Which desktops a capture visits on each display. Written as `1,3` (every
/// display walks those desktops) or per display as `main:1,2;builtin:1`.
struct DesktopWalk: Equatable {
    struct Entry: Equatable {
        /// nil means "every display that has no entry of its own".
        var screen: ScreenRef?
        var desktops: [Int]
    }

    var entries: [Entry]

    enum Parsed {
        case walk(DesktopWalk)
        case error(String)
    }

    static func parse(_ text: String) -> Parsed {
        var entries: [Entry] = []
        for part in text.split(whereSeparator: { $0 == ";" }).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !part.isEmpty {
            let pieces = part.split(separator: ":", maxSplits: 1)
            var ref: ScreenRef?
            var list = part
            if pieces.count == 2 {
                guard let parsed = ScreenRef.parse(String(pieces[0])) else {
                    return .error("no screen matching \(pieces[0])")
                }
                ref = parsed
                list = String(pieces[1])
            }
            var desktops: [Int] = []
            for number in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !number.isEmpty {
                guard let n = Int(number), n >= 1 else { return .error("desktop numbers start at 1, got \(number)") }
                if !desktops.contains(n) { desktops.append(n) }
            }
            guard !desktops.isEmpty else { return .error("expected desktop numbers in \(part)") }
            entries.append(Entry(screen: ref, desktops: desktops))
        }
        guard !entries.isEmpty else { return .error("desktops=<n,n> or <screen>:<n,n>;<screen>:<n>") }
        return .walk(DesktopWalk(entries: entries))
    }

    /// The desktops to walk on the display at `index`: its own entry if it has
    /// one, otherwise the entry that names no display. Empty means "whatever
    /// desktop is showing", i.e. no switching.
    func desktops(for screens: [ScreenDescriptor], index: Int) -> [Int] {
        for entry in entries {
            guard let ref = entry.screen else { continue }
            if ref.index(in: screens) == index { return entry.desktops }
        }
        return entries.first { $0.screen == nil }?.desktops ?? []
    }

    /// Every display walks its own desktops, 1...count. Used by the "Also walk
    /// desktops" checkbox in the capture prompt.
    static func all(counts: [Int]) -> DesktopWalk {
        DesktopWalk(entries: counts.enumerated().map { index, count in
            Entry(screen: .index(index + 1), desktops: count > 0 ? Array(1...count) : [1])
        })
    }
}
