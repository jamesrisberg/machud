import XCTest
import HUDKit
@testable import MacHUDMCPCore

/// The built `machud-mcp` executable over real stdin/stdout, against the fake MacHUD socket.
@MainActor
final class StdioEndToEndTests: XCTestCase {
    func testBinaryServesToolsOverStdio() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("machud-mcp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "build the machud-mcp product first (swift build)")
        let fake = FakeMacHUD()
        fake.start()
        defer { fake.cleanUp() }

        let process = Process()
        process.executableURL = binary
        process.environment = ["MACHUD_SOCKET": fake.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let lines = Output()
        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            for line in buffer.append(handle.availableData) { lines.append(line) }
        }
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        func send(_ object: [String: Any]) {
            input.fileHandleForWriting.write(Data((JSONLine.string(object) + "\n").utf8))
        }
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "e2e", "version": "1"]]])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "say", "arguments": ["text": "hi"]]])
        // The server answers requests concurrently: wait for every response, not the last sent.
        XCTAssertTrue(spin(until: { [1, 2, 3].allSatisfy { lines.response(id: $0) != nil } }, timeout: 10))

        XCTAssertEqual((lines.response(id: 1)?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let tools = (lines.response(id: 2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 19)
        let show = tools.first { $0["name"] as? String == "show_panel" }
        XCTAssertTrue((show?["description"] as? String ?? "").contains("Scratch (xyz.machud.scratch)"),
                      "the binary read the apps from MACHUD_SOCKET at start")
        XCTAssertEqual((lines.response(id: 3)?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(fake.requests("voice").last, ["_": "action", "name": "say", "text": "hi"])

        // Closing stdin ends the server.
        try input.fileHandleForWriting.close()
        XCTAssertTrue(spin(until: { !process.isRunning }, timeout: 5))
        XCTAssertEqual(process.terminationStatus, 0)
        output.fileHandleForReading.readabilityHandler = nil
    }
}

/// Splits a byte stream into lines; a line may arrive over several reads.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 10) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}
