import XCTest

/// `scripts/machud`, run against a stub binary that echoes its arguments instead of talking to a socket.
final class CLIShimTests: XCTestCase {
    private let scripts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts")
    private var dir: URL!
    private var stub: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("machud-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stub = dir.appendingPathComponent("MacHUD")
        try "#!/bin/sh\necho \"stub $*\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func run(_ script: URL, _ args: [String], env: [String: String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = script
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["MACHUD_APP"] = nil
        environment.merge(env) { $1 }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, o, e)
    }

    func testMachudForwardsToCtl() throws {
        let r = try run(scripts.appendingPathComponent("machud"), ["apply", "loadout=Work"], env: ["MACHUD_APP": stub.path])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, "stub ctl apply loadout=Work\n")
        XCTAssertEqual(r.err, "")
    }
}
