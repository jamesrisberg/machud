import Foundation
import HUDKit

/// MacHUD's line to the voice host's socket: one-off requests, and a `subscribe` stream that
/// keeps the host's latest state (the menu's Mute/Unmute reads it) and its models' progress.
/// Socket I/O runs off the main thread; results come back on it.
@MainActor
final class VoiceHostConnection {
    let path: String
    /// The host's last `state` (a `VoiceHostState` object), nil until it is connected.
    private(set) var state: [String: Any]?
    private(set) var isConnected = false
    /// Connected or disconnected. State events do not fire it: they arrive many times a second
    /// during a take.
    var onConnectionChange: (() -> Void)?
    /// A new state arrived.
    var onStateChange: (() -> Void)?
    /// A `models` event arrived (`{kokoro: {…}}`, the `models status` reply without `ok`).
    var onModelsChange: (([String: Any]) -> Void)?

    private var subscription: HUDSubscription?
    private var wanted = false
    /// An attempt to subscribe is on its way; `connect()` waits for it rather than starting another.
    private var attempting = false
    /// Bumped by `disconnect()`, so an attempt or a stream from before it is dropped.
    private var generation = 0
    private var retry = 0
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(path: String, schedule: ((TimeInterval, @escaping @MainActor () -> Void) -> Void)? = nil) {
        self.path = path
        self.schedule = schedule ?? { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { work() } }
        }
    }

    var muted: Bool? { state?["muted"] as? Bool }

    struct Unreachable: Error, CustomStringConvertible {
        let description: String
    }

    /// Sends one request. A host that is not listening answers `Unreachable`.
    func request(_ command: String, _ args: [String: String], timeout: TimeInterval = 10,
                 completion: @escaping @MainActor (Result<[String: Any], Error>) -> Void) {
        let path = self.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[String: Any], Error> = Result {
                do {
                    return try HUDSocketClient(path: path, timeout: timeout).request(command, args: args)
                } catch HUDSocketError.notRunning {
                    throw Unreachable(description: "no socket at \(path)")
                }
            }
            let box = UncheckedBox(result)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(box.value) } }
        }
    }

    /// Keeps one `subscribe` stream open while the host runs, retrying until it listens.
    func connect() {
        wanted = true
        attempt()
    }

    func disconnect() {
        wanted = false
        generation += 1
        attempting = false
        subscription?.cancel()
        subscription = nil
        setDisconnected()
    }

    private func attempt() {
        guard wanted, subscription == nil, !attempting else { return }
        attempting = true
        let path = self.path
        let current = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let client = HUDSocketClient(path: path, timeout: 3)
            let initial = try? client.request("state")
            let result = Result {
                try client.subscribe(events: ["state", "models"], onEvent: { event in
                    let box = UncheckedBox(event)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(box.value, generation: current) } }
                }, onClose: {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(generation: current) } }
                })
            }
            let box = UncheckedBox((initial, result))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.attempted(box.value.0, box.value.1, generation: current) }
            }
        }
    }

    private func attempted(_ initial: [String: Any]?, _ result: Result<HUDSubscription, Error>, generation current: Int) {
        guard current == generation else {
            // Disconnected meanwhile: this stream belongs to nobody.
            if case .success(let sub) = result { sub.cancel() }
            return
        }
        attempting = false
        switch result {
        case .success(let sub):
            guard wanted else { sub.cancel(); return }
            subscription = sub
            retry = 0
            isConnected = true
            if let state = initial?["state"] as? [String: Any] { self.state = state }
            onConnectionChange?()
        case .failure:
            retry += 1
            // The host needs a moment to listen after launch; then back off.
            schedule(min(5, 0.25 * pow(2, Double(min(retry, 5) - 1)))) { [weak self] in self?.attempt() }
        }
    }

    private func received(_ event: [String: Any], generation current: Int) {
        guard current == generation else { return }
        if event["event"] as? String == "models" {
            onModelsChange?(event)
            return
        }
        guard event["event"] as? String == "state", let state = event["state"] as? [String: Any] else { return }
        self.state = state
        onStateChange?()
    }

    private func closed(generation current: Int) {
        guard current == generation, subscription != nil else { return }
        subscription = nil
        setDisconnected()
        if wanted { schedule(0.5) { [weak self] in self?.attempt() } }
    }

    private func setDisconnected() {
        guard isConnected || state != nil else { return }
        isConnected = false
        state = nil
        onConnectionChange?()
    }
}
