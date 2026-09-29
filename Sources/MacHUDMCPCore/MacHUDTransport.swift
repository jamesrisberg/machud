import Foundation
import HUDKit

/// How the tool server talks to MacHUD: one request per call on its control socket, and a
/// `subscribe` stream of `state` events (pushed on every panel change and whenever the set of
/// discovered apps changes).
public protocol MacHUDTransport: Sendable {
    /// Sends `command` with `args` and returns MacHUD's JSON reply (which may say `ok: false`).
    /// Throws when MacHUD cannot be reached.
    func request(_ command: String, _ args: [String: String]) throws -> [String: Any]
    /// Opens the `state` stream. `onEvent` and `onClose` run on a background thread.
    func subscribe(onEvent: @escaping @Sendable ([String: Any]) -> Void,
                   onClose: @escaping @Sendable () -> Void) throws -> MacHUDSubscription
}

public protocol MacHUDSubscription: AnyObject, Sendable {
    func cancel()
}

extension HUDSubscription: MacHUDSubscription {}

/// Why a call to MacHUD failed before MacHUD could answer.
public struct MacHUDUnreachable: Error, CustomStringConvertible {
    public let description: String
}

/// `MacHUDTransport` over the control socket, through HUDKit's socket client.
public struct SocketTransport: MacHUDTransport {
    public let path: String
    /// Long enough for an `apply` that launches apps and switches desktops.
    public var timeout: TimeInterval

    public init(path: String, timeout: TimeInterval = 120) {
        self.path = path
        self.timeout = timeout
    }

    /// `MACHUD_SOCKET` when set (an isolated MacHUD, or the one the voice host names), else
    /// MacHUD's contract socket.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        HUDAnnounce.machudSocketPath(environment: environment)
    }

    public func request(_ command: String, _ args: [String: String]) throws -> [String: Any] {
        do {
            return try HUDSocketClient(path: path, timeout: timeout).request(command, args: args)
        } catch {
            throw MacHUDUnreachable(description: HUDSocketClient.failureMessage(for: error, path: path, appName: "MacHUD"))
        }
    }

    public func subscribe(onEvent: @escaping @Sendable ([String: Any]) -> Void,
                          onClose: @escaping @Sendable () -> Void) throws -> MacHUDSubscription {
        try HUDSocketClient(path: path, timeout: 5).subscribe(events: ["state"], onEvent: onEvent, onClose: onClose)
    }
}
