import Foundation
@testable import MacHUDCore

/// `LayoutStore` reads `MACHUD_CONFIG` once per process, so every test that builds a
/// store shares this one file (never the user's real config).
enum TestConfig {
    static let url: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("machud-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
