import XCTest
import AppKit
import HUDKit
@testable import MacHUDCore

/// The status menu's Save Diagnostics item: where it sits, what it says, and that it runs the
/// same service as the `diagnose` verb.
@MainActor
final class DiagnoseMenuTests: XCTestCase {
    private var root: URL!
    private var builds = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnose-menu-\(getpid())-\(Int.random(in: 0..<100_000))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        builds = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func providers(_ replies: [String: [String: Any]], windows: [DiagnoseSnapshot.AppKitWindow] = []) -> DiagnoseSnapshot.Providers {
        builds += 1
        return DiagnoseSnapshot.Providers(
            now: { Date(timeIntervalSince1970: 1_790_000_000 + Double(self.builds)) },
            machud: { .init(version: "0.3.1", build: nil, pid: 1, launchedAt: nil, isolated: true) },
            displays: { [] }, frontmost: { nil }, processes: { [] }, serverWindows: { [] }, spaces: { _ in nil },
            appKitWindows: { windows }, replies: replies)
    }

    private let healthy: [String: Any] = ["ok": true, "status": "disabled", "connected": false]

    /// One service the verb and the menu both run, over `windows` and with a voice status reply.
    private func service(voiceStatus: [String: Any]? = nil, windows: [DiagnoseSnapshot.AppKitWindow] = [],
                         directory: URL? = nil) -> DiagnoseService {
        DiagnoseService(
            sources: ["voiceStatus": { $0(voiceStatus ?? self.healthy) }],
            providers: { [unowned self] in self.providers($0, windows: windows) },
            store: DiagnoseStore(directory: directory ?? root, timeZone: TimeZone(identifier: "UTC")!))
    }

    private let ghost = DiagnoseSnapshot.AppKitWindow(
        number: 4242, identifier: "ghost", title: nil, className: "NSPanel", isVisible: true, isOnActiveSpace: true, alpha: 1, level: 0,
        collectionBehavior: 0, frame: CGRect(x: 0, y: 0, width: 10, height: 10))

    // MARK: - The item

    func testTheItemIsCalledSaveDiagnosticsAndTargetsTheMenuObject() {
        let menu = DiagnoseMenu(service: service())
        let item = menu.menuItem()
        XCTAssertEqual(item.title, "Save Diagnostics")
        XCTAssertEqual(DiagnoseMenu.title, "Save Diagnostics")
        XCTAssertTrue(item.target === menu)
        XCTAssertNotNil(item.action)
        XCTAssertNil(item.submenu)
        XCTAssertTrue(item.isEnabled)
    }

    func testItSitsAtTheEndOfTheAdvancedSubmenu() {
        let menu = DiagnoseMenu(service: service())
        let base = ["Edit layouts.json…", "Reveal layouts.json in Finder", "Reload Config"].map {
            NSMenuItem(title: $0, action: nil, keyEquivalent: "")
        }
        let entries = StatusMenu.advancedEntries(base: base, extras: [menu.menuItem()])
        XCTAssertEqual(entries.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["Edit layouts.json…", "Reveal layouts.json in Finder", "Reload Config", "-", "Save Diagnostics"])
        XCTAssertEqual(StatusMenu.advancedEntries(base: base, extras: []).map(\.title),
                       ["Edit layouts.json…", "Reveal layouts.json in Finder", "Reload Config"], "nothing registered, nothing added")
    }

    // MARK: - What it says

    func testChoosingItSavesToastsAndRevealsTheFile() throws {
        let menu = DiagnoseMenu(service: service())
        var toasts: [(String, String?)] = []
        var revealed: [URL] = []
        menu.toast = { toasts.append(($0, $1)) }
        menu.reveal = { revealed.append($0) }

        let item = menu.menuItem()
        XCTAssertTrue(NSApplication.shared.sendAction(item.action!, to: item.target, from: item), "the menu's own invoke path")
        XCTAssertTrue(spin(until: { !toasts.isEmpty }))
        XCTAssertEqual(toasts.map(\.0), ["Diagnostics saved. Nothing looks wrong."])
        XCTAssertEqual(toasts.first?.1, "diagnose-20260921-141321.json")
        let file = try XCTUnwrap(revealed.first)
        XCTAssertEqual(revealed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.lastPathComponent, "diagnose-20260921-141321.json")
    }

    func testTheToastCountsWhatLooksWrong() {
        XCTAssertEqual(DiagnoseMenu.message(for: ["ok": true, "path": "/x/a.json", "anomalies": ["one"]]).headline,
                       "Diagnostics saved. 1 thing looks wrong.")
        XCTAssertEqual(DiagnoseMenu.message(for: ["ok": true, "path": "/x/a.json", "anomalies": ["one", "two"]]).headline,
                       "Diagnostics saved. 2 things look wrong.")
        XCTAssertEqual(DiagnoseMenu.message(for: ["ok": true, "path": "/x/a.json", "anomalies": []]).headline,
                       "Diagnostics saved. Nothing looks wrong.")
        XCTAssertEqual(DiagnoseMenu.message(for: ["ok": true, "path": "/x/a.json", "anomalies": []]).detail, "a.json")
    }

    func testTwoThingsLookingWrongIsSaidAndStillRevealed() throws {
        // A window AppKit shows that the server does not list, and no voice status at all.
        let menu = DiagnoseMenu(service: DiagnoseService(
            sources: [:], providers: { [unowned self] in self.providers($0, windows: [self.ghost]) },
            store: DiagnoseStore(directory: root, timeZone: TimeZone(identifier: "UTC")!)))
        var toasts: [String] = []
        var revealed = 0
        menu.toast = { text, _ in toasts.append(text) }
        menu.reveal = { _ in revealed += 1 }
        menu.save()
        XCTAssertTrue(spin(until: { !toasts.isEmpty }))
        XCTAssertEqual(toasts, ["Diagnostics saved. 2 things look wrong."])
        XCTAssertEqual(revealed, 1)
    }

    func testAFailureIsAnErrorToastWithTheReasonAndRevealsNothing() throws {
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        let menu = DiagnoseMenu(service: service(directory: file.appendingPathComponent("inside")))
        var toasts: [(String, String?)] = []
        var revealed = 0
        menu.toast = { toasts.append(($0, $1)) }
        menu.reveal = { _ in revealed += 1 }
        menu.save()
        XCTAssertTrue(spin(until: { !toasts.isEmpty }))
        XCTAssertEqual(toasts.first?.0, "Could not save diagnostics")
        XCTAssertTrue(toasts.first?.1?.hasPrefix("could not write the snapshot to ") == true, "\(toasts)")
        XCTAssertEqual(revealed, 0)
    }

    // MARK: - One path

    func testTheMenuAndTheVerbRunTheSameServiceAndOnlyTheMenuReveals() throws {
        let service = service()
        let menu = DiagnoseMenu(service: service)
        var toasts = 0
        var revealed: [URL] = []
        menu.toast = { _, _ in toasts += 1 }
        menu.reveal = { revealed.append($0) }

        let path = "/tmp/diag-menu-\(getpid())-\(Int.random(in: 0..<100_000)).sock"
        let server = HUDSocketServer(path: path, label: "machud.test.diagnose.menu")
        service.registerControl(server)
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var verb: [String: Any]?
        DispatchQueue.global().async {
            let reply = try? HUDSocketClient(path: path, timeout: 10).request("diagnose", args: [:])
            DispatchQueue.main.async { verb = reply ?? ["failed": true] }
        }
        XCTAssertTrue(spin(until: { verb != nil }, timeout: 10))
        XCTAssertEqual(builds, 1, "the verb built one snapshot through the shared providers")
        XCTAssertEqual(toasts, 0, "the verb is quiet")
        XCTAssertTrue(revealed.isEmpty, "the verb never reveals, so a script is not pulled into Finder")

        menu.save()
        XCTAssertTrue(spin(until: { toasts == 1 }))
        XCTAssertEqual(builds, 2, "the menu built its snapshot through the same providers")
        XCTAssertEqual(revealed.count, 1)

        let verbPath = try XCTUnwrap(verb?["path"] as? String)
        XCTAssertNotEqual(verbPath, revealed.first?.path)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)).count, 2)
    }
}
