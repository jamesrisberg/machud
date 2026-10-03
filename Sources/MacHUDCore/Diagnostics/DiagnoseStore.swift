import Foundation

/// Where `diagnose` writes its snapshots, what it calls them and how many it keeps.
struct DiagnoseStore {
    /// The newest this many `diagnose-*.json` files stay; older ones are removed after a write.
    static let keep = 20

    var directory: URL
    var timeZone: TimeZone = .current

    /// `~/Library/Logs/MacHUD`. An isolated instance never writes there, or it would prune the
    /// real instance's snapshots: with `MACHUD_CONFIG` it uses a `diagnostics` folder beside that
    /// config, and with only `MACHUD_SOCKET` a `<socket path without extension>-diagnostics`
    /// folder beside the socket.
    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let config = Env.value("CONFIG", in: environment) {
            return URL(fileURLWithPath: (config as NSString).expandingTildeInPath)
                .deletingLastPathComponent().appendingPathComponent("diagnostics", isDirectory: true)
        }
        if let socket = Env.value("SOCKET", in: environment) {
            return URL(fileURLWithPath: (socket as NSString).deletingPathExtension + "-diagnostics", isDirectory: true)
        }
        return home.appendingPathComponent("Library/Logs/MacHUD", isDirectory: true)
    }

    /// `diagnose-<yyyyMMdd-HHmmss>.json` in local time.
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "diagnose-\(formatter.string(from: date)).json"
    }

    /// Writes `document` as a new file (never over an earlier snapshot taken in the same second)
    /// readable by the user only: it names the user's apps and widgets. Then prunes.
    @discardableResult
    func write(_ document: [String: Any], at date: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        let name = Self.fileName(for: date, timeZone: timeZone)
        var url = directory.appendingPathComponent(name)
        var attempt = 1
        while fm.fileExists(atPath: url.path) {
            attempt += 1
            url = directory.appendingPathComponent((name as NSString).deletingPathExtension + "-\(attempt).json")
        }
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        prune()
        return url
    }

    /// Removes every `diagnose-*.json` but the newest `keep`. Nothing else in the folder is touched.
    private func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path)
            .filter({ $0.hasPrefix("diagnose-") && $0.hasSuffix(".json") }) else { return }
        let stale = Self.surplus(names, modified: {
            (try? fm.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.modificationDate] as? Date) ?? .distantPast
        }, keep: Self.keep)
        for name in stale { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// The oldest of `names` beyond the newest `keep`; files modified at the same moment go by name,
    /// which carries the timestamp.
    static func surplus(_ names: [String], modified: (String) -> Date, keep: Int) -> [String] {
        let oldestFirst = names.map { (name: $0, date: modified($0)) }.sorted { ($0.date, $0.name) < ($1.date, $1.name) }
        return oldestFirst.dropLast(keep).map(\.name)
    }
}
