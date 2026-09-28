import XCTest
@testable import VoiceHostCore

final class VoiceHostSettingsTests: XCTestCase {
    func testEmptyObjectDecodesToDefaults() throws {
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, VoiceHostSettings())
        XCTAssertEqual(settings.brainPort, 8791)
    }

    func testBadValuesFallBackToDefaults() throws {
        let json = #"{"keyMode":"edit","brainPort":80,"enabled":"yes"}"#
        let settings = try JSONDecoder().decode(VoiceHostSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.keyMode, .hold)
        XCTAssertEqual(settings.brainPort, 8791)
        XCTAssertTrue(settings.enabled)
    }

    func testStateRoundTrips() throws {
        let state = VoiceHostState(phase: .failed("No mic"), card: VoiceCard(prompt: "hi", approval: VoiceApproval(id: "a", summary: "Run ls")))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(VoiceHostState.self, from: data), state)
    }
}
