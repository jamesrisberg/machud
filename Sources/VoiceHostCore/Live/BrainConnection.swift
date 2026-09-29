import BrainKit
import Combine
import Foundation

/// BrainKit's supervised companion plus a client for it. Ready once the companion is running
/// and the client has connected; a restart of the companion reconnects. Its health carries the
/// supervisor's reason whenever it is not running. `BrainService` brings the companion to the
/// configured runtime itself; `activeRuntime` reports the one it runs.
@MainActor
final class BrainConnection: BrainDriving {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The brain is not running yet" }
    }

    var onHealthChanged: ((BrainHealth) -> Void)?
    var onSnapshot: ((AgentSessionSnapshot) -> Void)?
    var onStopped: (() -> Void)?

    private let service: BrainService
    private let makeClient: @MainActor (ServiceEndpoint) -> AgentSessionClient
    private var client: AgentSessionClient?
    private var clientObservers = Set<AnyCancellable>()
    private var serviceObserver: AnyCancellable?
    private var serviceState: ManagedService.State = .stopped
    private var clientConnected = false
    private var reported: BrainHealth?

    convenience init() {
        self.init(service: BrainService())
    }

    /// `makeClient` gives the client for a ready companion (tests give it a stubbed URL session).
    init(service: BrainService, makeClient: (@MainActor (ServiceEndpoint) -> AgentSessionClient)? = nil) {
        self.service = service
        self.makeClient = makeClient ?? { AgentSessionClient(endpoint: $0.url, token: $0.token) }
        service.service.onReady = { [weak self] in self?.connect() }
        serviceObserver = service.service.$state.sink { [weak self] state in
            // `$state` publishes before the change lands; act on the new value.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only a companion that ran can have lost a turn; the first start is not a stop.
                let stopped = self.serviceState == .running && state != .running
                self.serviceState = state
                if state != .running { self.dropClient() }
                if stopped { self.onStopped?() }
                self.report()
            }
        }
    }

    func configure(_ configuration: BrainServiceConfiguration?) {
        service.configure(configuration)
    }

    /// The runtime the connected companion reports; nil while none is connected.
    var activeRuntime: String? {
        guard clientConnected, let snapshot = client?.snapshot else { return nil }
        return snapshot.runtime ?? AgentRuntime.codex.rawValue
    }

    func submit(_ text: String, requestId: String) async throws {
        guard let client else { throw Unavailable() }
        try await client.submit(text: text, requestId: requestId)
    }

    func approve(id: String, allow: Bool) async throws {
        guard let client else { throw Unavailable() }
        try await client.approve(id: id, allow: allow)
    }

    func cancel() async throws {
        guard let client else { throw Unavailable() }
        try await client.cancel()
    }

    private func connect() {
        dropClient()
        guard let endpoint = service.endpoint() else { return }
        let client = makeClient(endpoint)
        self.client = client
        client.$snapshot.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.onSnapshot?(snapshot) }
            }
            .store(in: &clientObservers)
        client.$isConnected.removeDuplicates()
            .sink { [weak self] connected in
                MainActor.assumeIsolated {
                    self?.clientConnected = connected
                    self?.report()
                }
            }
            .store(in: &clientObservers)
        Task { [weak self] in
            // The companion is listening once ready; retry briefly in case it is still settling.
            for attempt in 0..<3 {
                guard self?.client === client else { return }
                if (try? await client.connect()) != nil { return }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
    }

    private func dropClient() {
        guard let client else { return }
        clientObservers.removeAll()
        client.disconnect()
        self.client = nil
        clientConnected = false
        report()
    }

    private func report() {
        let health = Self.health(serviceState, clientConnected: clientConnected)
        guard health != reported else { return }
        reported = health
        onHealthChanged?(health)
    }

    static func health(_ state: ManagedService.State, clientConnected: Bool) -> BrainHealth {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return clientConnected ? .ready : .connecting
        case .unavailable(let reason): return .unavailable(reason)
        case .backingOff(_, _, let reason): return .restarting(reason)
        case .failed(let reason): return .failed(reason)
        }
    }
}
