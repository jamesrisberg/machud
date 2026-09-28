import BrainKit
import Combine
import Foundation

/// BrainKit's supervised companion plus a client for it. Available once the companion is
/// running and the client has connected; a restart of the companion reconnects.
@MainActor
final class BrainConnection: BrainDriving {
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "The brain is not running yet" }
    }

    var onAvailabilityChanged: ((Bool) -> Void)?
    var onSnapshot: ((AgentSessionSnapshot) -> Void)?
    var onStopped: (() -> Void)?

    private let service: BrainService
    private var client: AgentSessionClient?
    private var clientObservers = Set<AnyCancellable>()
    private var serviceObserver: AnyCancellable?

    convenience init() {
        self.init(service: BrainService())
    }

    init(service: BrainService) {
        self.service = service
        service.service.onReady = { [weak self] in self?.connect() }
        serviceObserver = service.service.$state.sink { [weak self] state in
            // `$state` publishes before the change lands; act on the new value.
            guard state != .running else { return }
            MainActor.assumeIsolated {
                self?.dropClient()
                self?.onStopped?()
            }
        }
    }

    func configure(_ configuration: BrainServiceConfiguration?) {
        service.configure(configuration)
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
        guard let client = service.makeClient() else { return }
        self.client = client
        client.$snapshot.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] snapshot in MainActor.assumeIsolated { self?.onSnapshot?(snapshot) } }
            .store(in: &clientObservers)
        client.$isConnected.removeDuplicates()
            .sink { [weak self] connected in MainActor.assumeIsolated { self?.onAvailabilityChanged?(connected) } }
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
        onAvailabilityChanged?(false)
    }
}
