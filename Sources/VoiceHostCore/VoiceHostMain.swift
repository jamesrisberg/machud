import AppKit

/// Process entry for the voice host.
public enum VoiceHostMain {
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
