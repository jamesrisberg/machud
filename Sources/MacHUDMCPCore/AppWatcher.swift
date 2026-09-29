import Foundation

/// Keeps `MacHUDTools.apps` current: follows MacHUD's `state` stream (pushed on every panel
/// change and whenever an app is discovered, announced or goes away), re-reads `apps` a moment
/// after events settle, and calls `onChange` when the apps differ. When MacHUD is not running
/// or the stream ends it tries again every `retryInterval`.
public final class AppWatcher: @unchecked Sendable {
    let tools: MacHUDTools
    let retryInterval: TimeInterval
    let settle: TimeInterval
    let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "machud-mcp.watcher")
    private var subscription: MacHUDSubscription?
    private var refreshPending = false
    private var stopped = false

    public init(tools: MacHUDTools, retryInterval: TimeInterval = 5, settle: TimeInterval = 0.3,
                onChange: @escaping @Sendable () -> Void) {
        self.tools = tools
        self.retryInterval = retryInterval
        self.settle = settle
        self.onChange = onChange
    }

    /// Reads the apps once (so the first `tools/list` has them) and opens the stream.
    public func start() {
        queue.sync { connect() }
    }

    public func stop() {
        queue.sync {
            stopped = true
            subscription?.cancel()
            subscription = nil
        }
    }

    /// On `queue`.
    private func connect() {
        guard !stopped, subscription == nil else { return }
        refresh()
        do {
            subscription = try tools.transport.subscribe(
                onEvent: { [weak self] _ in self?.queue.async { self?.scheduleRefresh() } },
                onClose: { [weak self] in
                    self?.queue.async {
                        guard let self else { return }
                        self.subscription = nil
                        self.retryLater()
                    }
                })
        } catch {
            retryLater()
        }
    }

    private func retryLater() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in self?.connect() }
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        queue.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refresh()
        }
    }

    private func refresh() {
        let before = tools.apps
        guard let after = try? tools.refreshApps() else { return }
        if after != before { onChange() }
    }
}
