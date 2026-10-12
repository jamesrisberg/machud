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

    /// Launches per app path (`AppIndex.normalize`d); nil when there is no database or it cannot
    /// be read to the end. Alfred's file is opened read-only and never written: SQLite's backup
    /// copies it, with whatever its journal holds, into memory as one consistent snapshot (a
    /// read transaction, so a write Alfred makes meanwhile cannot tear it), and the copy is read.
    static func launchCounts(at url: URL = defaultURL) -> [String: Int]? {
        guard FileManager.default.fileExists(atPath: url.path), let db = snapshot(of: url) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT item, COUNT(*) FROM knowledge WHERE item LIKE 'features.filecache.%' GROUP BY item"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                let item = String(cString: text)
                let path = AppIndex.normalize(String(item.dropFirst(itemPrefix.count)))
                if item.hasPrefix(itemPrefix), path.lowercased().hasSuffix(".app") {
                    out[path, default: 0] += Int(sqlite3_column_int64(stmt, 1))
                }
            }
            rc = sqlite3_step(stmt)
        }
        // Anything but the end of the rows (a damaged page, a busy file) is no history at all,
        // so the seed is tried again next launch rather than made from part of it.
        return rc == SQLITE_DONE ? out : nil
    }

    /// An in-memory copy of the database at `url`, read through a read-only connection. A
    /// WAL-mode database closed cleanly (no `-wal` or `-shm` left) cannot be opened read-only
    /// the usual way, which would mean creating its `-shm`, so it is opened `immutable`: with
    /// no journal there is nothing for a writer to be halfway through. A WAL database with its
    /// `-wal`, and a rollback-journal one (which locks for its readers), open read-only.
    private static func snapshot(of url: URL) -> OpaquePointer? {
        var source: OpaquePointer?
        defer { sqlite3_close(source) }
        let closedWAL = isWALMode(url) && !FileManager.default.fileExists(atPath: url.path + "-wal")
        let opened = closedWAL
            ? sqlite3_open_v2(immutableURI(url), &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            : sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(source, 500)
        var copy: OpaquePointer?
        guard sqlite3_open(":memory:", &copy) == SQLITE_OK else { sqlite3_close(copy); return nil }
        guard let backup = sqlite3_backup_init(copy, "main", source, "main") else { sqlite3_close(copy); return nil }
        let rc = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else { sqlite3_close(copy); return nil }
        return copy
    }

    /// `file:<path>?mode=ro&immutable=1`, the path percent-encoded as a URI path.
    static func immutableURI(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        return components.string ?? "file:\(url.path)?mode=ro&immutable=1"
    }

    /// Whether the database file's header marks it as in WAL mode (its read and write format
    /// versions, bytes 18 and 19, are 2).
    static func isWALMode(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20 else { return false }
        return header[18] == 2 && header[19] == 2
    }
}
