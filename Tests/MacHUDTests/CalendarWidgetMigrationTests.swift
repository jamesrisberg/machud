import XCTest
import HUDKit
@testable import MacHUDCore

final class CalendarWidgetMigrationTests: XCTestCase {
    private let record = #"{"instance":"A","app":"xyz.machud.widgethud","type":"calendar","size":"large","screen":{"builtin":true},"x":0.25,"y":0.4,"layer":"float","settings":{"calendars":"Work","daysAhead":7,"timeFormat":"24h"}}"#

    func testCalendarMovesProviderWithoutChangingPlacementOrSettings() throws {
        let widget = try JSONDecoder().decode(WidgetRecord.self, from: Data(record.utf8))
        XCTAssertEqual(widget.app, "xyz.machud.calhud")
        XCTAssertEqual(widget.instance, "A")
        XCTAssertEqual(widget.type, "calendar")
        XCTAssertEqual(widget.size, .large)
        XCTAssertEqual(widget.x, 0.25)
        XCTAssertEqual(widget.y, 0.4)
        XCTAssertEqual(widget.layer, .float)
        XCTAssertEqual(widget.settings?["calendars"], .string("Work"))
        XCTAssertEqual(widget.settings?["daysAhead"], .int(7))
        let encoded = try JSONEncoder().encode(widget)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["screen"] as? [String: Any])?["builtin"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(WidgetRecord.self, from: encoded), widget)
    }

    func testOtherProvidersAndWidgetTypesArePreserved() throws {
        for (app, type) in [("xyz.machud.widgethud", "clock"), ("xyz.machud.widgethud", "weather"), ("other", "calendar"), ("xyz.machud.calhud", "calendar")] {
            let data = Data("{\"instance\":\"A\",\"app\":\"\(app)\",\"type\":\"\(type)\"}".utf8)
            XCTAssertEqual(try JSONDecoder().decode(WidgetRecord.self, from: data).app, app)
        }
    }

    func testLoadoutWidgetsAndLegacyCellsMoveWithTheirProvider() throws {
        let data = Data(#"{"widgets":[{"instance":"B","app":"xyz.machud.widgethud","type":"calendar","col":2,"row":3}]}"#.utf8)
        let loadout = try JSONDecoder().decode(HUDLoadout.self, from: data)
        XCTAssertEqual(loadout.widgets?.first?.app, "xyz.machud.calhud")
        XCTAssertEqual(loadout.widgets?.first?.legacyCell, .init(col: 2, row: 3))
    }
}
