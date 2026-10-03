import Foundation

/// Loadouts that span several desktops or displays are experimental: they are offered, applied
/// and captured only while `experimental.multiDesktopLoadouts` is on. Everything that lists,
/// applies or captures a loadout asks here, so the rule and its wording live in one place.
enum ExperimentalLoadouts {
    /// The setting's key, as `settings get/set` and `layouts.json` spell it.
    static let settingKey = "experimental.multiDesktopLoadouts"
    /// The setting's title in MacHUD's settings.
    static let settingTitle = "Multi-desktop loadouts"

    /// The loadouts to offer: all of them while the feature is on, else the one-screen ones.
    static func offered(in config: Config) -> [Loadout] {
        let all = config.loadouts ?? []
        return config.multiDesktopLoadouts ? all : all.filter { !$0.spansScreensOrDesktops }
    }

    /// How many loadouts are held back while the feature is off.
    static func heldBack(in config: Config) -> Int {
        (config.loadouts ?? []).count - offered(in: config).count
    }

    /// Why `loadout` cannot be used now; nil when it can.
    static func refusal(for loadout: Loadout, in config: Config) -> String? {
        guard loadout.spansScreensOrDesktops, !config.multiDesktopLoadouts else { return nil }
        return "“\(loadout.name)” spans several desktops or displays, which is experimental. \(howToTurnOn)"
    }

    /// Why a multi-desktop action cannot run now; nil when it can. `action` starts the sentence
    /// ("Capturing every screen", "Walking desktops", "Switching desktops").
    static func refusal(forAction action: String, in config: Config) -> String? {
        guard !config.multiDesktopLoadouts else { return nil }
        return "\(action) is experimental. \(howToTurnOn)"
    }

    static let howToTurnOn = "Turn on \(settingTitle) under Experimental in MacHUD's settings to use it."
}

extension Config {
    /// Whether loadouts may span desktops and displays (`experimental.multiDesktopLoadouts`).
    var multiDesktopLoadouts: Bool { experimental?.multiDesktopLoadouts == true }
}
