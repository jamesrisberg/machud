import XCTest
@testable import MacHUDCore

final class ScreenRefTests: XCTestCase {
    private let screens = [
        ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false),
        ScreenDescriptor(name: "Built-in Retina Display", isMain: false, isBuiltin: true),
    ]

    func testRoundTrip() throws {
        let cases: [ScreenRef] = [.name("DELL S2722QC"), .index(2), .main, .builtin]
        for c in cases {
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(ScreenRef.self, from: data), c)
        }
    }

    func testJSONForm() throws {
        func decode(_ json: String) throws -> ScreenRef {
            try JSONDecoder().decode(ScreenRef.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"name": "Color LCD"}"#), .name("Color LCD"))
        XCTAssertEqual(try decode(#"{"index": 1}"#), .index(1))
        XCTAssertEqual(try decode(#"{"main": true}"#), .main)
        XCTAssertEqual(try decode(#"{"builtin": true}"#), .builtin)
        XCTAssertThrowsError(try decode(#"{}"#))
        let encoded = String(decoding: try JSONEncoder().encode(ScreenRef.main), as: UTF8.self)
        XCTAssertEqual(encoded, #"{"main":true}"#)
    }

    func testResolution() {
        XCTAssertEqual(ScreenRef.main.index(in: screens), 0)
        XCTAssertEqual(ScreenRef.builtin.index(in: screens), 1)
        XCTAssertEqual(ScreenRef.index(2).index(in: screens), 1)
        XCTAssertNil(ScreenRef.index(3).index(in: screens))
        XCTAssertNil(ScreenRef.index(0).index(in: screens))
        XCTAssertEqual(ScreenRef.name("dell s2722qc").index(in: screens), 0)
        XCTAssertEqual(ScreenRef.name("Retina").index(in: screens), 1)
        XCTAssertNil(ScreenRef.name("Studio Display").index(in: screens))
        // An exact name wins over a display that merely contains it.
        let both = [ScreenDescriptor(name: "DELL S2722QC (2)", isMain: false, isBuiltin: false),
                    ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false)]
        XCTAssertEqual(ScreenRef.name("DELL S2722QC").index(in: both), 1)
    }

    func testMissingScreenResolvesToNothing() {
        XCTAssertNil(ScreenRef.builtin.index(in: [screens[0]]))
    }

    func testParse() {
        XCTAssertEqual(ScreenRef.parse("main"), .main)
        XCTAssertEqual(ScreenRef.parse("builtin"), .builtin)
        XCTAssertEqual(ScreenRef.parse("2"), .index(2))
        XCTAssertEqual(ScreenRef.parse("DELL"), .name("DELL"))
        XCTAssertNil(ScreenRef.parse("  "))
    }
}

final class ModelCompatibilityTests: XCTestCase {
    /// A config written before screens and desktops existed must still decode,
    /// and must not grow keys when written back.
    func testLegacyLoadoutDecodes() throws {
        let json = """
        {"layouts": [], "loadouts": [{"name": "Work", "layout": "Main",
          "slots": [{"regionID": "a", "occupant": {"kind": "app", "bundleID": "com.apple.TextEdit"}}]}]}
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let loadout = try XCTUnwrap(config.loadouts?.first)
        XCTAssertNil(loadout.screens)
        XCTAssertNil(loadout.slots.first?.space)
        XCTAssertNil(config.experimental)

        let written = String(decoding: try JSONEncoder().encode(loadout.slots[0]), as: UTF8.self)
        XCTAssertFalse(written.contains("space"))
    }

    func testScreensRoundTrip() throws {
        let slot = Slot(regionID: "a", occupant: .app(bundleID: "com.apple.TextEdit", titleMatch: nil), space: 2)
        let loadout = Loadout(name: "Two", layout: "Main", slots: [], hotkey: nil,
                              screens: [ScreenAssignment(screen: .name("DELL S2722QC"), layout: "Main", slots: [slot]),
                                        ScreenAssignment(screen: .builtin, layout: "Side", slots: [])])
        let data = try JSONEncoder().encode(loadout)
        XCTAssertEqual(try JSONDecoder().decode(Loadout.self, from: data), loadout)
        XCTAssertEqual(loadout.allSlots, [slot])
    }

    func testExperimentalFlag() throws {
        let json = #"{"layouts": [], "experimental": {"spacesPrivateAPI": true}}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.experimental?.spacesPrivateAPI, true)
    }
}

final class LoadoutPlanTests: XCTestCase {
    private func slot(_ id: String, space: Int? = nil) -> Slot {
        Slot(regionID: id, occupant: .panel(id: id), space: space)
    }

    func testLegacyLoadoutIsOneGroupOnTheMouseScreen() {
        let loadout = Loadout(name: "L", layout: "Main", slots: [slot("a"), slot("b")], hotkey: nil)
        let groups = LoadoutPlan.groups(for: loadout)
        XCTAssertEqual(groups, [.init(screen: nil, layout: "Main", space: nil, slots: [slot("a"), slot("b")])])
    }

    func testEmptyLoadoutStillYieldsAGroupSoMissingLayoutsAreReported() {
        let groups = LoadoutPlan.groups(for: Loadout(name: "L", layout: "Gone", slots: [], hotkey: nil))
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].slots.isEmpty)
    }

    func testDesktopsAreGroupedAndOrdered() {
        let slots = [slot("a", space: 2), slot("b"), slot("c", space: 1), slot("d", space: 2)]
        let loadout = Loadout(name: "L", layout: "Main", slots: slots, hotkey: nil)
        let groups = LoadoutPlan.groups(for: loadout)
        XCTAssertEqual(groups.map(\.space), [nil, 1, 2])
        XCTAssertEqual(groups[0].slots, [slot("b")])
        XCTAssertEqual(groups[2].slots, [slot("a", space: 2), slot("d", space: 2)])
    }

    func testScreenAssignmentsFollowTheLegacySlots() {
        let loadout = Loadout(name: "L", layout: "Main", slots: [slot("a")], hotkey: nil,
                              screens: [ScreenAssignment(screen: .builtin, layout: "Side",
                                                         slots: [slot("b", space: 2), slot("c")])])
        let groups = LoadoutPlan.groups(for: loadout)
        XCTAssertEqual(groups.map(\.screen), [nil, .builtin, .builtin])
        XCTAssertEqual(groups.map(\.layout), ["Main", "Side", "Side"])
        XCTAssertEqual(groups.map(\.space), [nil, nil, 2])
    }

    func testScreensOnlyLoadoutHasNoMouseScreenGroup() {
        let loadout = Loadout(name: "L", layout: "Main", slots: [], hotkey: nil,
                              screens: [ScreenAssignment(screen: .main, layout: "Main", slots: [slot("a")])])
        XCTAssertEqual(LoadoutPlan.groups(for: loadout).map(\.screen), [.main])
    }
}

final class SpacesParsingTests: XCTestCase {
    /// Trimmed capture of `defaults export com.apple.spaces -` on a two-display
    /// Mac: the main display has three desktops (the second one showing), the
    /// second display one, and there are collapsed entries for displays that
    /// are not attached.
    private let spacesPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>SpacesDisplayConfiguration</key><dict>
        <key>Management Data</key><dict>
          <key>Monitors</key><array>
            <dict>
              <key>Current Space</key><dict><key>ManagedSpaceID</key><integer>4</integer><key>id64</key><integer>4</integer></dict>
              <key>Display Identifier</key><string>Main</string>
              <key>Spaces</key><array>
                <dict><key>ManagedSpaceID</key><integer>5</integer><key>id64</key><integer>5</integer></dict>
                <dict><key>ManagedSpaceID</key><integer>4</integer><key>id64</key><integer>4</integer></dict>
                <dict><key>ManagedSpaceID</key><integer>525</integer><key>id64</key><integer>525</integer></dict>
              </array>
            </dict>
            <dict>
              <key>Current Space</key><dict><key>ManagedSpaceID</key><integer>1314</integer><key>id64</key><integer>1314</integer></dict>
              <key>Display Identifier</key><string>37D8832A-2D66-02CA-B9F7-8F30A301B230</string>
              <key>Spaces</key><array>
                <dict><key>ManagedSpaceID</key><integer>1314</integer><key>id64</key><integer>1314</integer></dict>
              </array>
            </dict>
            <dict>
              <key>Collapsed Space</key><dict><key>ManagedSpaceID</key><integer>1561</integer></dict>
              <key>Display Identifier</key><string>DFE35036-0705-4F19-8040-FBF67F354D2A</string>
            </dict>
          </array>
        </dict>
      </dict>
      <key>spans-displays</key><integer>0</integer>
    </dict></plist>
    """

    /// `defaults export com.apple.symbolichotkeys -`: "Switch to Desktop 1/2"
    /// turned off, "Move left/right a space" (79/81) left at their defaults.
    private let hotkeysPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>AppleSymbolicHotKeys</key><dict>
        <key>79</key><dict><key>enabled</key><true/><key>value</key><dict>
          <key>parameters</key><array><integer>65535</integer><integer>123</integer><integer>8650752</integer></array>
          <key>type</key><string>standard</string></dict></dict>
        <key>81</key><dict><key>enabled</key><true/><key>value</key><dict>
          <key>parameters</key><array><integer>65535</integer><integer>124</integer><integer>8650752</integer></array>
          <key>type</key><string>standard</string></dict></dict>
        <key>118</key><dict><key>enabled</key><false/><key>value</key><dict>
          <key>parameters</key><array><integer>65535</integer><integer>18</integer><integer>262144</integer></array>
          <key>type</key><string>standard</string></dict></dict>
        <key>119</key><dict><key>enabled</key><false/><key>value</key><dict>
          <key>parameters</key><array><integer>65535</integer><integer>19</integer><integer>262144</integer></array>
          <key>type</key><string>standard</string></dict></dict>
        <key>16</key><dict><key>enabled</key><false/></dict>
      </dict>
    </dict></plist>
    """

    private func plist(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
    }

    func testMonitors() throws {
        let monitors = Spaces.monitors(from: try plist(spacesPlist))
        XCTAssertEqual(monitors.count, 2)
        XCTAssertEqual(monitors[0].identifier, "Main")
        XCTAssertEqual(monitors[0].spaceIDs, [5, 4, 525])
        XCTAssertEqual(monitors[0].count, 3)
        XCTAssertEqual(monitors[0].currentIndex, 2)
        XCTAssertEqual(monitors[0].spaceID(at: 3), 525)
        XCTAssertNil(monitors[0].spaceID(at: 4))
        XCTAssertEqual(monitors[1].identifier, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertEqual(monitors[1].count, 1)
        XCTAssertEqual(monitors[1].currentIndex, 1)
    }

    func testMonitorsOfEmptyPlist() {
        XCTAssertTrue(Spaces.monitors(from: [:]).isEmpty)
    }

    func testShortcuts() throws {
        let p = try plist(hotkeysPlist)
        let left = try XCTUnwrap(Spaces.shortcut(from: p, key: Spaces.Key.moveLeft))
        XCTAssertTrue(left.enabled)
        XCTAssertEqual(left.keyCode, 123)
        XCTAssertEqual(left.eventFlags, .maskControl)
        XCTAssertEqual(Spaces.shortcut(from: p, key: Spaces.Key.moveRight)?.keyCode, 124)

        let desktop1 = try XCTUnwrap(Spaces.shortcut(from: p, key: Spaces.Key.desktop(1)))
        XCTAssertFalse(desktop1.enabled)
        XCTAssertEqual(desktop1.keyCode, 18)
        XCTAssertEqual(desktop1.eventFlags, .maskControl)
        // An entry with no value at all is a disabled shortcut, not a crash.
        XCTAssertEqual(Spaces.shortcut(from: p, key: 16)?.enabled, false)
        XCTAssertNil(Spaces.shortcut(from: p, key: 999))
    }

    func testKeyNumbering() {
        XCTAssertEqual(Spaces.Key.desktop(1), 118)
        XCTAssertEqual(Spaces.Key.desktop(4), 121)
    }

    func testEventFlagsDropDeviceDependentBits() {
        // 8650752 = control (1 << 18) plus the left-control device bit (1 << 23).
        let s = Spaces.Shortcut(enabled: true, keyCode: 124, modifiers: 8_650_752)
        XCTAssertEqual(s.eventFlags, .maskControl)
    }

    // MARK: - Routing

    private func route(to target: Int, current: Int, count: Int,
                       direct: Set<Int> = [], steps: Bool = true) -> Result<Spaces.Route, Spaces.SwitchError> {
        Spaces.route(to: target, current: current, count: count) { key in
            if key == Spaces.Key.moveLeft || key == Spaces.Key.moveRight {
                return Spaces.Shortcut(enabled: steps, keyCode: key == Spaces.Key.moveLeft ? 123 : 124,
                                       modifiers: 262_144)
            }
            let n = key - 117
            return Spaces.Shortcut(enabled: direct.contains(n), keyCode: 17 + n, modifiers: 262_144)
        }
    }

    func testRouteNoop() throws {
        XCTAssertEqual(try route(to: 2, current: 2, count: 3).get(), .already)
    }

    func testRoutePrefersTheDirectShortcut() throws {
        guard case .direct(let shortcut) = try route(to: 3, current: 1, count: 3, direct: [3]).get() else {
            return XCTFail("expected the direct shortcut")
        }
        XCTAssertEqual(shortcut.keyCode, 20)
    }

    func testRouteFallsBackToSteps() throws {
        guard case .steps(let shortcut, let count) = try route(to: 4, current: 2, count: 5).get() else {
            return XCTFail("expected steps")
        }
        XCTAssertEqual(shortcut.keyCode, 124)
        XCTAssertEqual(count, 2)
        guard case .steps(let back, let backCount) = try route(to: 1, current: 3, count: 5).get() else {
            return XCTFail("expected steps")
        }
        XCTAssertEqual(back.keyCode, 123)
        XCTAssertEqual(backCount, 2)
    }

    func testRouteFailsWhenEverySwitchShortcutIsOff() {
        guard case .failure(let error) = route(to: 3, current: 1, count: 3, steps: false) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error.reason, "spacesShortcutDisabled")
        XCTAssertTrue(error.message.contains("Mission Control"))
    }

    func testRouteRejectsDesktopsThatDoNotExist() {
        guard case .failure(let error) = route(to: 4, current: 1, count: 3) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(error.reason, "spaceOutOfRange")
        guard case .failure(let empty) = route(to: 1, current: 1, count: 0) else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(empty.reason, "noDesktopsForScreen")
    }
}

final class SpacesKeystrokeTests: XCTestCase {
    func testSystemEventsScript() {
        let control = Spaces.Shortcut(enabled: true, keyCode: 124, modifiers: 8_650_752)
        XCTAssertEqual(Spaces.systemEventsScript(for: control),
                       "tell application \"System Events\" to key code 124 using {control down}")
        let plain = Spaces.Shortcut(enabled: true, keyCode: 18, modifiers: 0)
        XCTAssertEqual(Spaces.systemEventsScript(for: plain),
                       "tell application \"System Events\" to key code 18")
        // Modifiers are listed in a fixed order, whatever order the bits are in.
        let many = Spaces.Shortcut(enabled: true, keyCode: 19, modifiers: 262_144 | 131_072 | 1_048_576)
        XCTAssertEqual(Spaces.systemEventsScript(for: many),
                       "tell application \"System Events\" to key code 19 using {command down, shift down, control down}")
    }
}

final class DesktopWalkTests: XCTestCase {
    private let screens = [
        ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false),
        ScreenDescriptor(name: "Built-in Retina Display", isMain: false, isBuiltin: true),
    ]

    private func parse(_ text: String) throws -> DesktopWalk {
        guard case .walk(let walk) = DesktopWalk.parse(text) else {
            throw XCTSkip("expected a walk from \(text)")
        }
        return walk
    }

    func testPlainListAppliesToEveryScreen() throws {
        let walk = try parse("1,3")
        XCTAssertEqual(walk.entries, [.init(screen: nil, desktops: [1, 3])])
        XCTAssertEqual(walk.desktops(for: screens, index: 0), [1, 3])
        XCTAssertEqual(walk.desktops(for: screens, index: 1), [1, 3])
    }

    func testPerScreenListsWin() throws {
        let walk = try parse("main:1,2;builtin:1")
        XCTAssertEqual(walk.desktops(for: screens, index: 0), [1, 2])
        XCTAssertEqual(walk.desktops(for: screens, index: 1), [1])
    }

    func testAScreenWithNoEntryFallsBackToTheUnnamedOne() throws {
        let walk = try parse("builtin:1;2,3")
        XCTAssertEqual(walk.desktops(for: screens, index: 1), [1])
        XCTAssertEqual(walk.desktops(for: screens, index: 0), [2, 3])
        // Nothing at all for a screen with no entry and no default.
        let only = try parse("builtin:1")
        XCTAssertTrue(only.desktops(for: screens, index: 0).isEmpty)
    }

    func testDuplicatesAndSpacesAreTidied() throws {
        XCTAssertEqual(try parse(" 2 , 1 , 2 ").entries.first?.desktops, [2, 1])
    }

    func testBadInput() {
        for text in ["", "main:", "0", "main:x", "  "] {
            guard case .error = DesktopWalk.parse(text) else {
                return XCTFail("expected \(text) to be rejected")
            }
        }
    }

    func testEveryScreenWalksItsOwnDesktops() {
        let walk = DesktopWalk.all(counts: [6, 1])
        XCTAssertEqual(walk.desktops(for: screens, index: 0), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(walk.desktops(for: screens, index: 1), [1])
    }
}

final class ScreenFallbackTests: XCTestCase {
    private let both = [
        ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false),
        ScreenDescriptor(name: "Built-in Retina Display", isMain: false, isBuiltin: true),
    ]
    private let alone = [ScreenDescriptor(name: "DELL S2722QC", isMain: true, isBuiltin: false)]

    private func request(_ screen: ScreenRef, space: Int? = nil,
                         fallback: ScreenAssignment.Fallback? = nil) -> ScreenFallback.Request {
        ScreenFallback.Request(screen: screen, space: space, fallback: fallback)
    }

    private func plan(_ requests: [ScreenFallback.Request], screens: [ScreenDescriptor],
                      policy: ScreenMissingPolicy = .desktop,
                      desktops: ScreenFallback.Desktops = .init(count: 6, current: 1)) -> [ScreenFallback.Outcome] {
        ScreenFallback.plan(requests, screens: screens, policy: policy) { _ in desktops }
    }

    func testAttachedScreensAreLeftAlone() {
        let outcomes = plan([request(.name("DELL S2722QC")), request(.builtin, space: 2)], screens: both)
        XCTAssertEqual(outcomes, [.present(screen: 0, space: nil), .present(screen: 1, space: 2)])
    }

    func testMissingScreenLandsOnTheFirstFreeDesktopOfTheMainOne() {
        // The present assignment is showing desktop 1, so the redirect takes 2.
        let outcomes = plan([request(.name("DELL S2722QC")), request(.builtin)], screens: alone)
        XCTAssertEqual(outcomes, [.present(screen: 0, space: nil), .redirected(screen: 0, space: 2)])
    }

    func testRedirectsAllocateInOrderAndDoNotCollide() {
        let outcomes = plan([request(.name("Studio Display")), request(.builtin),
                             request(.name("DELL S2722QC"), space: 3)], screens: alone)
        XCTAssertEqual(outcomes, [.redirected(screen: 0, space: 1), .redirected(screen: 0, space: 2),
                                  .present(screen: 0, space: 3)])
    }

    func testAnExplicitFallbackWins() {
        let fallback = ScreenAssignment.Fallback(screen: .builtin, space: 1)
        let outcomes = plan([request(.name("Studio Display"), fallback: fallback)], screens: both)
        XCTAssertEqual(outcomes, [.redirected(screen: 1, space: 1)])
    }

    /// Nothing else is on the built-in display, so its first desktop is free —
    /// which is also the one it is showing, so nothing has to switch.
    func testAFallbackWithoutADesktopTakesTheFirstFreeOne() {
        let fallback = ScreenAssignment.Fallback(screen: .builtin, space: nil)
        let outcomes = plan([request(.name("Studio Display"), fallback: fallback)], screens: both)
        XCTAssertEqual(outcomes, [.redirected(screen: 1, space: 1)])
        // With the built-in already spoken for, the next desktop is used.
        let taken = plan([request(.builtin), request(.name("Studio Display"), fallback: fallback)], screens: both)
        XCTAssertEqual(taken, [.present(screen: 1, space: nil), .redirected(screen: 1, space: 2)])
    }

    func testAFallbackScreenThatIsAlsoMissingFallsBackToMain() {
        let fallback = ScreenAssignment.Fallback(screen: .name("Studio Display"), space: nil)
        let outcomes = plan([request(.builtin, fallback: fallback)], screens: alone)
        XCTAssertEqual(outcomes, [.redirected(screen: 0, space: 1)])
    }

    func testTooFewDesktopsIsReportedWithTheNumberNeeded() {
        let two = ScreenFallback.Desktops(count: 2, current: 1)
        let outcomes = plan([request(.name("DELL S2722QC")), request(.builtin), request(.name("Studio Display"))],
                            screens: alone, desktops: two)
        XCTAssertEqual(outcomes, [.present(screen: 0, space: nil), .redirected(screen: 0, space: 2),
                                  .needsDesktops(screen: 0, count: 3)])
    }

    func testAnExplicitFallbackDesktopBeyondTheEndFails() {
        let fallback = ScreenAssignment.Fallback(screen: nil, space: 9)
        let outcomes = plan([request(.builtin, fallback: fallback)], screens: alone)
        XCTAssertEqual(outcomes, [.needsDesktops(screen: 0, count: 9)])
    }

    func testSkipPolicyLeavesTheAssignmentOut() {
        let outcomes = plan([request(.builtin)], screens: alone, policy: .skip)
        XCTAssertEqual(outcomes, [.skipped])
    }

    func testNoScreensAtAll() {
        XCTAssertEqual(plan([request(.builtin)], screens: []), [.skipped])
    }
}

final class DegradationModelTests: XCTestCase {
    func testAssignmentRoundTripWithTheNewFields() throws {
        let assignment = ScreenAssignment(
            screen: .name("DELL S2722QC"), layout: "Work · DELL S2722QC",
            slots: [Slot(regionID: "a", occupant: .panel(id: "dock"))], space: 3,
            fallback: .init(screen: .builtin, space: 1))
        var loadout = Loadout(name: "Work", layout: "Work · DELL S2722QC", slots: [], hotkey: nil,
                              screens: [assignment])
        loadout.whenScreenMissing = .skip
        let data = try JSONEncoder().encode(loadout)
        XCTAssertEqual(try JSONDecoder().decode(Loadout.self, from: data), loadout)
        XCTAssertEqual(loadout.screenMissingPolicy, .skip)
    }

    func testTheNewFieldsAreLeftOutOfOldStyleLoadouts() throws {
        let loadout = Loadout(name: "Work", layout: "Main",
                              slots: [Slot(regionID: "a", occupant: .panel(id: "dock"))], hotkey: nil)
        let written = String(decoding: try JSONEncoder().encode(loadout), as: UTF8.self)
        XCTAssertFalse(written.contains("whenScreenMissing"))
        XCTAssertFalse(written.contains("fallback"))
        XCTAssertEqual(loadout.screenMissingPolicy, .desktop)
    }

    func testAssignmentDesktopDecodesAndDefaultsToNil() throws {
        let json = """
        {"screen": {"builtin": true}, "layout": "Side", "slots": []}
        """
        let assignment = try JSONDecoder().decode(ScreenAssignment.self, from: Data(json.utf8))
        XCTAssertNil(assignment.space)
        XCTAssertNil(assignment.fallback)
    }

    /// The desktop a whole assignment was captured on stands in for its slots.
    func testAssignmentDesktopGroupsTheSlots() {
        let slots = [Slot(regionID: "a", occupant: .panel(id: "a")),
                     Slot(regionID: "b", occupant: .panel(id: "b"), space: 1)]
        let loadout = Loadout(name: "L", layout: "Main", slots: [], hotkey: nil,
                              screens: [ScreenAssignment(screen: .main, layout: "Main", slots: slots, space: 4)])
        let groups = LoadoutPlan.groups(for: loadout)
        XCTAssertEqual(groups.map(\.space), [1, 4])
        XCTAssertEqual(groups.map(\.assignment), [0, 0])
        XCTAssertEqual(groups[1].slots.map(\.regionID), ["a"])
    }
}
