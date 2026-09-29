import AppKit
import HUDKit

/// Puts the onboarding on screen and takes it down. The live one is the full-screen overlay;
/// tests use a fake so nothing is ever shown.
@MainActor
protocol OnboardingPresenting: AnyObject {
    var isVisible: Bool { get }
    func present(_ model: OnboardingModel)
    func dismiss()
}

/// First-run onboarding: shown at launch until finished or skipped, on demand from the menu
/// and `machud onboarding show`, and resumable where it was left.
@MainActor
final class OnboardingServices {
    let model: OnboardingModel
    let store: OnboardingStore
    private let presenter: OnboardingPresenting
    /// Readies the Apps step: preselects the bundled tools and refreshes a stale catalog.
    var prepareApps: () -> Void = {}
    /// Whether this instance may show the onboarding by itself at launch: the real MacHUD, or
    /// an isolated one with `MACHUD_FIRST_RUN=1`.
    var launchAllowed: () -> Bool = { !Env.isIsolated || Env.value("FIRST_RUN") == "1" }
    private var timer: Timer?

    init(model: OnboardingModel, store: OnboardingStore = OnboardingStore(), presenter: OnboardingPresenting) {
        self.model = model
        self.store = store
        self.presenter = presenter
        model.onStepChange = { [weak self] _ in self?.save(.inProgress) }
        model.onProgress = { [weak self] in self?.save(self?.store.load()?.status ?? .inProgress) }
        model.onExit = { [weak self] exit in self?.exit(exit) }
    }

    var isVisible: Bool { presenter.isVisible }

    /// It will show at launch: never run, or left unfinished.
    var wantsLaunch: Bool { launchAllowed() && store.wantsLaunch }

    /// Shows it at launch when `wantsLaunch`. Returns whether it did.
    @discardableResult
    func showIfNeeded() -> Bool {
        guard wantsLaunch else { return false }
        show()
        return true
    }

    /// Shows the overlay at `step`, else where it was left (the start once finished or skipped).
    func show(step: OnboardingStep? = nil) {
        let record = store.load()
        let resume = step ?? (record?.status == .inProgress ? record?.step : nil) ?? .welcome
        prepareApps()
        model.restore(sections: record?.sections ?? [:], loadout: record?.loadout)
        model.resume(at: resume)
        save(.inProgress)
        if !presenter.isVisible { presenter.present(model) }
        startTicking()
    }

    /// Takes the overlay down; it resumes at this step.
    func hide() { exit(.later) }

    /// The record with the model's step, marked sections and first loadout.
    private func save(_ status: OnboardingRecord.Status) {
        store.save(status, step: model.step, sections: model.markedSections, loadout: model.firstLoadout?.name)
    }

    private func exit(_ exit: OnboardingModel.Exit) {
        switch exit {
        case .finished: save(.completed)
        case .skipped: save(.skipped)
        case .later: save(.inProgress)
        }
        stopTicking()
        presenter.dismiss()
    }

    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tick() }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Menu

    /// "Setup Guide…" in the status menu.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Setup Guide…", action: #selector(OnboardingMenuTarget.show), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menuTarget.services = self
        item.target = menuTarget
        return item
    }

    private let menuTarget = OnboardingMenuTarget()

    // MARK: - Control

    /// `onboarding [status]|show [step=]|hide|next|back|skip|reset|snapshot dir=`.
    func registerControl(_ control: HUDSocketServer) {
        control.register("onboarding") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            done(self.handle(args))
        }
    }

    static let actions = ["status", "show", "hide", "next", "back", "skip", "reset", "snapshot"]

    func handle(_ args: [String: String]) -> [String: Any] {
        // `machud onboarding show step=brain` arrives as `_: show, show: 1, step: brain`.
        let action = args["action"].flatMap { $0 == "1" ? nil : $0 } ?? args["_"]
            ?? Self.actions.first { args[$0] == "1" } ?? "status"
        switch action {
        case "status":
            return statusJSON
        case "show":
            var step: OnboardingStep?
            if let raw = args["step"] {
                guard let parsed = OnboardingStep(rawValue: raw) else {
                    return ["ok": false, "error": "step must be one of \(OnboardingStep.allCases.map(\.rawValue).joined(separator: ", "))"]
                }
                step = parsed
            }
            show(step: step)
        case "hide":
            guard isVisible else { return ["ok": false, "error": "the onboarding is not showing"] }
            hide()
        case "next", "back":
            guard isVisible else { return ["ok": false, "error": "the onboarding is not showing; `onboarding show` first"] }
            action == "next" ? model.next() : model.back()
        case "skip":
            exit(.skipped)
        case "reset":
            if isVisible { stopTicking(); presenter.dismiss() }
            store.reset()
        case "snapshot":
            guard let dir = args["dir"], !dir.isEmpty, dir != "1" else {
                return ["ok": false, "error": "onboarding snapshot needs dir=<folder>"]
            }
            do {
                let urls = try OnboardingSnapshot.writeAll(model, to: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
                var r = statusJSON
                r["files"] = urls.map(\.path)
                return r
            } catch {
                return ["ok": false, "error": "\(error)"]
            }
        default:
            return ["ok": false, "error": "onboarding takes \(Self.actions.joined(separator: ", ")), not \(action)"]
        }
        return statusJSON
    }

    var statusJSON: [String: Any] {
        var r: [String: Any] = ["ok": true, "visible": isVisible,
                                "record": store.load()?.json ?? NSNull(),
                                "steps": OnboardingStep.allCases.map(\.rawValue)]
        r.merge(model.json) { a, _ in a }
        return r
    }
}

@MainActor
final class OnboardingMenuTarget: NSObject {
    weak var services: OnboardingServices?
    @objc func show() { services?.show() }
}
