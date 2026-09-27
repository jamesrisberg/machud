import XCTest
@testable import MacHUDCore

final class ClearAllDesktopsTests: XCTestCase {
    func testClearTargetsExemptOwnSiblingAndHiddenApps() {
        let e = { (n: Int, pid: pid_t, on: Bool) in
            AllSpacesWindows.Entry(number: n, pid: pid, frame: .zero, onScreen: on)
        }
        let entries = [e(1, 10, true), e(2, 10, false), e(3, 20, true), e(4, 30, false), e(5, 40, true)]
        let targets = AllSpacesWindows.clearTargets(entries, exempt: [20], hidden: [40])
        XCTAssertEqual(targets[10]?.map(\.number), [1, 2], "windows on other desktops are included")
        XCTAssertEqual(targets[30]?.map(\.number), [4])
        XCTAssertNil(targets[20])
        XCTAssertNil(targets[40])
    }
}
