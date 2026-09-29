import Foundation
import HUDKit

/// MacHUD's `text-feed` broker over its control socket: `feed add text= source= [title=]`, sent
/// the way the `machud` CLI sends it. MacHUD forwards the text to every running app that
/// provides `text-feed` and launches none; with none running it answers `delivered: []`.
///
/// Requests go out one at a time, in order, off the main thread; the reply is not waited for by
/// the caller, and a MacHUD that does not answer only costs this queue the timeout.
struct MacHUDFeed: TextFeeding {
    /// MacHUD's control socket: `$MACHUD_SOCKET`, else `/tmp/machud-<uid>.sock`.
    let socketPath: String
    var timeout: TimeInterval = 5
    private let queue = DispatchQueue(label: "machud-voice.feed", qos: .utility)

    init(socketPath: String, timeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// The request `add` sends.
    static func arguments(text: String, source: String, title: String?) -> [String: String] {
        var args = ["_": "add", "add": "1", "action": "add", "text": text, "source": source]
        if let title, !title.isEmpty { args["title"] = title }
        return args
    }

    func add(text: String, source: String, title: String?) {
        let args = Self.arguments(text: text, source: source, title: title)
        let path = socketPath
        let timeout = self.timeout
        queue.async {
            _ = try? HUDSocketClient(path: path, timeout: timeout).request("feed", args: args)
        }
    }
}
