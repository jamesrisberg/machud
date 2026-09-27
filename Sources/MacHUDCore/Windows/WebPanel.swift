import AppKit
import WebKit

/// A web page in a window MacHUD owns. Remembers nothing across launches: the
/// loadout is the source of truth for which page lives where.
@MainActor
final class WebPanel: NSObject, Panel, NSWindowDelegate {
    let url: String
    private(set) var window: NSWindow?
    private var web: WKWebView?
    /// Called when the user closes the window so the engine can forget it.
    var onClose: (() -> Void)?

    static func id(for url: String) -> String { "web:\(url)" }

    init(url: String) {
        self.url = url
        super.init()
    }

    var id: String { Self.id(for: url) }
    var title: String { URL(string: url)?.host ?? url }
    var symbol: String { "globe" }

    func show() {
        let window = window ?? makeWindow()
        window.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    func close() {
        onClose = nil
        window?.close()
        window = nil
        web = nil
    }

    func menuItems() -> [NSMenuItem] {
        let item = NSMenuItem(title: "Reload", action: #selector(reload), keyEquivalent: "")
        item.target = self
        return [item]
    }

    @objc private func reload() { web?.reload() }

    private func makeWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let w = NSWindow(contentRect: frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.managed, .fullScreenAuxiliary]
        w.delegate = self

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: frame, configuration: config)
        view.autoresizingMask = [.width, .height]
        if let target = URL(string: url) { view.load(URLRequest(url: target)) }
        w.contentView = view
        w.center()
        web = view
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        web = nil
        onClose?()
    }
}
