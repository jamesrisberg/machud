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

    /// Why a capture or HUD save may not be saved as `name`: a loadout held back while the
    /// feature is off already has it, and saving would replace that loadout unseen. Nil when
    /// the name is free, belongs to an offered loadout (a recapture replaces it, as always), or
    /// the feature is on.
    static func refusal(forName name: String, in config: Config) -> String? {
        guard let existing = config.loadouts?.first(where: { $0.name == name }) else { return nil }
        return refusal(for: existing, in: config)
    }

    static let howToTurnOn = "Turn on \(settingTitle) under Experimental in MacHUD's settings to use it."

    /// What to say about `count` loadouts held back while the feature is off; nil for none.
    static func heldBackNote(count: Int) -> String? {
        guard count > 0 else { return nil }
        let one = count == 1
        return "\(count) loadout\(one ? " is" : "s are") hidden: \(one ? "it spans" : "they span") several desktops or "
            + "displays. Turn on \(settingTitle) under Experimental in MacHUD's settings to use \(one ? "it" : "them")."
    }
}

extension Config {
    /// Whether loadouts may span desktops and displays (`experimental.multiDesktopLoadouts`).
    var multiDesktopLoadouts: Bool { experimental?.multiDesktopLoadouts == true }
}
