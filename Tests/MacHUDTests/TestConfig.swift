import Foundation
@testable import MacHUDCore

/// `LayoutStore` reads `MACHUD_CONFIG` once per process, so every test that builds a
/// store shares this one file (never the user's real config). Its folder is removed when
/// the test process exits; the tests that spawn a process wait for it, so nothing reads
/// the folder afterwards.
enum TestConfig {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("machud-tests-\(getpid())")
    }

    static let url: URL = {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A C callback cannot capture `dir`: it names the folder again.
        atexit { try? FileManager.default.removeItem(at: TestConfig.directory) }
        let url = dir.appendingPathComponent("layouts.json")
        setenv("MACHUD_CONFIG", url.path, 1)
        return url
    }()

    /// Write the config; false when `LayoutStore` was already pinned to another file.
    static func write(_ json: String) throws -> Bool {
        let target = url
        try Data(json.utf8).write(to: target)
        return LayoutStore.configURL == target
    }
}
