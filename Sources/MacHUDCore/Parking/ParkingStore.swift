import Foundation
import HUDKit

/// One parked window as persisted, so a crash or quit can put it back.
struct ParkedRecord: Codable, Equatable {
    enum Kind: String, Codable {
        /// Another app's window, moved through Accessibility.
        case ax
        /// One of MacHUD's own panel windows.
        case own
        /// A HUDKit app's panel, parked by asking the app over its socket.
        case cooperative
    }

    /// Slot region id, or `w<window number>` for a window parked by hand.
    var id: String
    var label: String
    var kind: Kind
    var pid: Int32?
    var bundleID: String?
    var title: String?
    var windowNumber: Int?
    /// Own panel id, or the cooperative app's panel id.
    var panelID: String?
    /// Cooperative app's socket path.
    var socket: String?
    /// Where the window lives when revealed.
    var rest: CGRect
    /// Where it sits while parked (what macOS actually allowed, for AX windows).
    var parked: CGRect
    var edge: HUDEdge
    var peek: Double
    /// Points still showing because macOS refused to move the window further; nil when
    /// it went where it was sent.
    var sliver: Double?
}

/// Everything parking persists: parked windows and where the user put each orb.
struct ParkingState: Codable, Equatable {
    var parked: [ParkedRecord] = []
    /// Orb origin per edge (`HUDEdge.rawValue`), once dragged or set.
    var orbs: [String: CGPoint] = [:]
    /// Orbs hidden with `orb hide`.
    var orbsHidden: Bool? = nil
}

/// Reads and writes `ParkingState` as JSON. Lives in a `state` folder beside the config
/// so writing it does not wake the config directory watcher.
struct ParkingStore {
    let url: URL

    static var defaultURL: URL {
        LayoutStore.configDirectory.appendingPathComponent("state/parking.json")
    }

    func load() -> ParkingState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ParkingState.self, from: data) else { return ParkingState() }
        return state
    }

    func save(_ state: ParkingState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            NSLog("MacHUD: failed to save %@: %@", url.path, "\(error)")
        }
    }
}
