import Foundation
import SQLite3

/// How often each app was launched from the search bar, which lifts it in the ranking. Kept in
/// `state/launches.json` beside MacHUD's config, keyed by the app's canonical path
/// (`AppIndex.canonical`). Seeded once from Alfred's launch history when it is there.
@MainActor
final class LaunchCounts {
    nonisolated static var defaultURL: URL { LayoutStore.configDirectory.appendingPathComponent("state/launches.json") }

    private struct File: Codable {
        var counts: [String: Int] = [:]
        var alfredSeeded = false
    }

    private let url: URL
    private let canonical: (String) -> String
    private var file: File

    var counts: [String: Int] { file.counts }
    var alfredSeeded: Bool { file.alfredSeeded }

    init(url: URL = LaunchCounts.defaultURL, canonical: @escaping (String) -> String = AppIndex.canonical) {
        self.url = url
        self.canonical = canonical
        file = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(File.self, from: $0) } ?? File()
    }

    func record(_ path: String) {
        file.counts[canonical(path), default: 0] += 1
        save()
    }

    /// Adds Alfred's counts the first time they can be read; false when already seeded or when
    /// there is no history (nil), so a later launch tries again.
    @discardableResult
    func seed(fromAlfred alfred: [String: Int]?) -> Bool {
        guard !file.alfredSeeded, let alfred else { return false }
        for (path, n) in alfred { file.counts[canonical(path), default: 0] += n }
        file.alfredSeeded = true
        save()
        return true
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            NSLog("MacHUD: could not save search launch counts: %@", "\(error)")
        }
    }
}

/// Alfred's record of the apps launched through it, read without changing anything: the
/// `knowledge` table of `knowledge.alfdb` has a row per launch, its item
/// `features.filecache.<path>`.
enum AlfredHistory {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alfred/Databases/knowledge.alfdb")
    }

    private static let itemPrefix = "features.filecache."

    /// Launches per app path (`AppIndex.normalize`d); nil when there is no readable database.
    /// The database is copied to a temporary folder and the copy is read, so neither Alfred's
    /// file nor its journal is opened, locked or written, even by SQLite's read-only mode,
    /// which writes a `-shm` file for a database in WAL mode.
    static func launchCounts(at url: URL = defaultURL) -> [String: Int]? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let dir = fm.temporaryDirectory.appendingPathComponent("machud-alfred-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
            let wal = URL(fileURLWithPath: url.path + "-wal")
            if fm.fileExists(atPath: wal.path) { try fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
        } catch {
            return nil
        }
        // Read-write on the copy (ours), so SQLite can replay a copied journal into it.
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT item, COUNT(*) FROM knowledge WHERE item LIKE 'features.filecache.%' GROUP BY item"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0) else { continue }
            let item = String(cString: text)
            guard item.hasPrefix(itemPrefix) else { continue }
            let path = AppIndex.normalize(String(item.dropFirst(itemPrefix.count)))
            guard path.lowercased().hasSuffix(".app") else { continue }
            out[path, default: 0] += Int(sqlite3_column_int64(stmt, 1))
        }
        return out
    }
}
