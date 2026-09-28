import AppKit
import HUDKit

/// MacHUD's side of the built-in voice host: the supervisor that runs it, the connection to its
/// socket, the `voice` control verb, the status menu's Voice submenu and the Voice and Brain
/// settings tabs.
@MainActor
final class VoiceServices: NSObject {
    let supervisor: VoiceHostSupervisor
    let connection: VoiceHostConnection
    let settingsModel: VoiceSettingsModel
    /// Opens the settings window on a tab ("voice" or "brain").
    var openSettings: ((String) -> Void)?
    /// The menu or the settings may look different now.
    var onChange: (() -> Void)?

    init(supervisor: VoiceHostSupervisor, socketPath: String) {
        self.supervisor = supervisor
        connection = VoiceHostConnection(path: socketPath)
        settingsModel = VoiceSettingsModel()
        super.init()
        settingsModel.services = self
        let previous = supervisor.onStatusChange
        supervisor.onStatusChange = { [weak self] status in
            previous?(status)
            self?.statusChanged(status)
        }
        connection.onChange = { [weak self] in
            guard let self else { return }
            self.settingsModel.hostAvailabilityChanged()
            self.onChange?()
        }
        statusChanged(supervisor.status)
    }

    /// The real thing: the helper beside this binary, voice.json beside layouts.json.
    static func live() -> VoiceServices {
        let socket = VoiceHostPaths.socketPath()
        let settingsURL = VoiceHostPaths.settingsURL()
        let supervisor = VoiceHostSupervisor(
            launcher: ChildProcessLauncher(),
            helper: { VoiceHostPaths.helperURL(executable: Bundle.main.executableURL) },
            isEnabled: { VoiceHostPaths.isEnabled(settingsURL: settingsURL) },
            socketPath: socket, environment: ProcessInfo.processInfo.environment)
        return VoiceServices(supervisor: supervisor, socketPath: socket)
    }

    func start() { supervisor.start() }

    func stop() {
        connection.disconnect()
        supervisor.stop()
    }

    /// Turns voice on: starts the host even though voice.json says off, then stores
    /// `enabled: true` through its socket (the host is the only writer of voice.json).
    func turnOn(completion: ((String?) -> Void)? = nil) {
        supervisor.start(force: true)
        connection.connect()
        waitForHost(tries: 40) { [weak self] ready in
            guard let self else { return }
            guard ready else { completion?("the voice host did not start"); return }
            self.perform(.mergeSettings(["enabled": "true"])) { reply in
                completion?(reply["ok"] as? Bool == true ? nil : reply["error"] as? String ?? "could not turn voice on")
            }
        }
    }

    private func waitForHost(tries: Int, _ done: @escaping @MainActor (Bool) -> Void) {
        connection.request("hello", [:], timeout: 2) { [weak self] result in
            if case .success = result { done(true); return }
            guard tries > 1, let self, self.supervisor.isRunning else { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self.waitForHost(tries: tries - 1, done) }
            }
        }
    }

    private func statusChanged(_ status: VoiceHostSupervisor.Status) {
        if status.name == "running" { connection.connect() } else { connection.disconnect() }
        settingsModel.hostAvailabilityChanged()
        onChange?()
    }

    // MARK: - Control

    /// `voice state|status|action|settings|secret …`, forwarded to the voice host's socket.
    func registerControl(_ control: HUDSocketServer) {
        control.register("voice") { [weak self] args, done in
            guard let self else { done(["ok": false, "error": "app gone"]); return }
            self.handle(args, done: done)
        }
    }

    func handle(_ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        do {
            perform(try VoiceCommand.parse(args), done: done)
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    func perform(_ command: VoiceCommand, done: @escaping ([String: Any]) -> Void) {
        switch command {
        case .status:
            done(statusJSON)
        case .forward(let verb, let args):
            send(verb, args, done: done)
        case .mergeSettings(let pairs):
            send("settings", ["action": "get"]) { [weak self] reply in
                guard let self else { done(["ok": false, "error": "app gone"]); return }
                guard reply["ok"] as? Bool == true, let current = reply["settings"] as? [String: Any] else {
                    done(reply); return
                }
                do {
                    let merged = try VoiceSettingsJSON.merging(current, pairs)
                    self.sendSettings(merged, done: done)
                } catch {
                    done(["ok": false, "error": "\(error)"])
                }
            }
        }
    }

    /// `settings set` with the whole object.
    func sendSettings(_ settings: [String: Any], done: @escaping ([String: Any]) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) else {
            done(["ok": false, "error": "settings are not JSON"]); return
        }
        send("settings", ["action": "set", "settings": String(decoding: data, as: UTF8.self)], done: done)
    }

    private func send(_ verb: String, _ args: [String: String], done: @escaping ([String: Any]) -> Void) {
        connection.request(verb, args) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let reply):
                if verb == "settings", args["action"] == "set", reply["ok"] as? Bool == true,
                   let enabled = (reply["settings"] as? [String: Any])?["enabled"] as? Bool {
                    self.supervisor.settingsChanged(enabled: enabled)
                }
                done(reply)
            case .failure(let error):
                done(["ok": false, "error": "voice host is not reachable: \(self.supervisor.status.text) (\(error))",
                      "status": self.supervisor.status.name])
            }
        }
    }

    var statusJSON: [String: Any] {
        var d: [String: Any] = ["ok": true, "status": supervisor.status.name, "socket": supervisor.socketPath,
                                "connected": connection.isConnected]
        if let pid = supervisor.pid { d["pid"] = Int(pid) }
        if case .failed(let why) = supervisor.status { d["error"] = why }
        if let muted = connection.muted { d["muted"] = muted }
        return d
    }

    // MARK: - Menu

    /// The status menu's "Voice" item: Mute/Unmute (or why it is unavailable) and Voice Settings….
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: connection.muted == true ? "mic.slash" : "mic", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        for entry in menuEntries() {
            let mi = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: "")
            mi.target = self
            mi.isEnabled = entry.action != nil
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    /// The submenu's titles, for tests.
    func menuTitles() -> [String] { menuEntries().map(\.title) }

    private func menuEntries() -> [(title: String, action: Selector?)] {
        var entries: [(String, Selector?)] = []
        if connection.isConnected, let muted = connection.muted {
            entries.append(muted ? ("Unmute Voice", #selector(unmute)) : ("Mute Voice", #selector(mute)))
        } else if supervisor.status == .disabled {
            entries.append(("Voice is off", nil))
            entries.append(("Turn On Voice", #selector(turnOnFromMenu)))
        } else {
            entries.append((supervisor.status.text, nil))
        }
        entries.append(("Voice Settings…", #selector(showSettings)))
        return entries
    }

    @objc private func mute() { perform(.forward("action", ["name": "mute"])) { Self.report($0, "Mute") } }
    @objc private func unmute() { perform(.forward("action", ["name": "unmute"])) { Self.report($0, "Unmute") } }
    @objc private func showSettings() { openSettings?("voice") }
    @objc private func turnOnFromMenu() {
        turnOn { error in if let error { Toast.show("Could not turn voice on", detail: error) } }
    }

    private static func report(_ reply: [String: Any], _ what: String) {
        guard reply["ok"] as? Bool != true else { return }
        Toast.show("Voice: \(what) failed", detail: reply["error"] as? String ?? "")
    }
}
