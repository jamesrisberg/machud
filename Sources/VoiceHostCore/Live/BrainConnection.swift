import BrainKit
import Combine
import Foundation

/// BrainKit's supervised companion plus a client for it. Ready once the companion is running
/// and the client has connected; a restart of the companion reconnects. Its health carries the
/// supervisor's reason whenever it is not running.
///
/// The runtime the companion runs follows the configuration. `BrainService` keeps the process
/// when only the runtime changes and leaves the switch to its host (`POST /v1/runtime`), so this
/// connection makes it: whenever the connected companion reports another runtime than the one
/// configured, it asks the companion to switch. That covers a runtime changed in settings and a
/// companion started earlier on another one. The companion refuses a switch during a turn; the
/// switch is asked again once a snapshot shows the turn over. After each configuration it waits
/// `settle` first, so a change that restarts the companion is not sent to the process on its way out.
@MainActor
final class BrainConnection: BrainDriving {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The brain is not running yet" }
    }

    var onHealthChanged: ((BrainHealth) -> Void)?
    var onSnapshot: ((AgentSessionSnapshot) -> Void)?
    var onStopped: (() -> Void)?

    /// Longer than `BrainService`'s debounce (0.4 s), so the configuration has been applied.
    nonisolated static let defaultSettle: TimeInterval = 1

    private let service: BrainService
    private let scheduler: ServiceScheduling
    private let settle: TimeInterval
    private let makeClient: @MainActor (ServiceEndpoint) -> AgentSessionClient
    private var client: AgentSessionClient?
    private var clientObservers = Set<AnyCancellable>()
    private var serviceObserver: AnyCancellable?
    private var serviceState: ManagedService.State = .stopped
    private var clientConnected = false
    private var reported: BrainHealth?
    /// The runtime the configuration asks for; nil while stopped.
    private var wantedRuntime: AgentRuntime?
    /// A configuration was just given and may still restart the companion.
    private var settling: ScheduledAction?
    /// The switch asked of the snapshot it was asked on (runtime, instance, revision), so an
    /// unchanged snapshot does not ask again.
    private var switchAsked: String?
    private var switching = false

    convenience init() {
        self.init(service: BrainService())
    }

    /// - Parameters:
    ///   - scheduler: runs the settle wait (tests step it by hand).
    ///   - makeClient: the client for a ready companion (tests give it a stubbed URL session).
    init(service: BrainService, scheduler: ServiceScheduling = DispatchServiceScheduler(),
         settle: TimeInterval = BrainConnection.defaultSettle,
         makeClient: (@MainActor (ServiceEndpoint) -> AgentSessionClient)? = nil) {
        self.service = service
        self.scheduler = scheduler
        self.settle = settle
        self.makeClient = makeClient ?? { AgentSessionClient(endpoint: $0.url, token: $0.token) }
        service.service.onReady = { [weak self] in self?.connect() }
        serviceObserver = service.service.$state.sink { [weak self] state in
            // `$state` publishes before the change lands; act on the new value.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.serviceState = state
                if state != .running {
                    self.dropClient()
                    self.onStopped?()
                }
                self.report()
            }
        }
    }

    func configure(_ configuration: BrainServiceConfiguration?) {
        wantedRuntime = configuration?.runtime
        service.configure(configuration)
        settling?.cancel()
        settling = nil
        guard configuration != nil else { return }
        settling = scheduler.schedule(after: settle) { [weak self] in
            self?.settling = nil
            self?.followRuntime()
        }
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
                MainActor.assumeIsolated {
                    self?.onSnapshot?(snapshot)
                    self?.followRuntime(snapshot)
                }
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

    /// Asks the companion to run the configured runtime when it reports another one and is
    /// between turns. `snapshot` is the one just published (the client's own may lag it).
    private func followRuntime(_ snapshot: AgentSessionSnapshot? = nil) {
        guard settling == nil, !switching, let wanted = wantedRuntime, let client,
              let snapshot = snapshot ?? client.snapshot else { return }
        let running = snapshot.runtime ?? AgentRuntime.codex.rawValue
        guard running != wanted.rawValue, !snapshot.isWorking else { return }
        let asked = "\(wanted.rawValue) \(snapshot.instanceId ?? "") \(snapshot.revision)"
        guard asked != switchAsked else { return }
        switchAsked = asked
        switching = true
        Task { [weak self] in
            // A refusal (a turn started meanwhile) or a runtime that fails to start comes back
            // as an error; the next snapshot decides whether to ask again.
            _ = try? await client.setRuntime(wanted)
            guard let self else { return }
            switching = false
            if self.client === client { followRuntime() }
        }
    }

    private func dropClient() {
        guard let client else { return }
        clientObservers.removeAll()
        client.disconnect()
        self.client = nil
        clientConnected = false
        switchAsked = nil
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
