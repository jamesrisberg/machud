import AppKit
import HUDKit

/// MacHUD's search bar: a keyable glass panel centred on the screen with the pointer, its text
/// field focused at once, that launches apps, opens files, applies loadouts and inserts Stash's
/// snippets. It never activates MacHUD (a non-activating panel takes the keyboard without
/// that), so the app you were in stays frontmost. Closes on Esc, when it loses the keyboard,
/// and before a row runs.
@MainActor
final class SearchBar: NSObject, SearchBarPresenting, NSWindowDelegate, NSTextFieldDelegate {
    let model: SearchModel
    private var window: SearchPanelWindow?
    private var content: SearchBarContentView?
    /// The top edge stays put as the rows come and go.
    private var top: CGFloat = 0

    init(model: SearchModel) {
        self.model = model
        super.init()
        model.onHide = { [weak self] in self?.hide() }
        model.onResultsChange = { [weak self] in self?.fitHeight() }
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var query: String { model.query }

    /// Opens the bar on the screen with the pointer, with `query` typed (empty when nil), or
    /// brings it back with that query if it is open.
    func show(query: String? = nil) {
        model.engine.apps.refreshIfStale()
        let window = window ?? makeWindow()
        let text = query ?? ""
        content?.field.stringValue = text
        model.setQuery(text)
        if !window.isVisible { place(window) }
        fitHeight()
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content?.field)
        content?.field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        model.stop()
    }

    // MARK: Window

    private func makeWindow() -> SearchPanelWindow {
        let size = CGSize(width: SearchBarMetrics.width, height: SearchBarMetrics.maxHeight)
        let w = SearchPanelWindow(contentRect: CGRect(origin: .zero, size: size), keyable: true, level: .floating)
        // Over other floating HUD panels (the tool dock, sibling apps' panels).
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        w.identifier = NSUserInterfaceItemIdentifier("machud.search")
        w.isMovableByWindowBackground = false
        w.delegate = self
        w.onCommand = { [weak self] command in self?.model.handle(command) ?? false }
        let glass = HUDGlassView(frame: CGRect(origin: .zero, size: size), style: .panel)
        glass.autoresizingMask = [.width, .height]
        let content = SearchBarContentView(model: model, frame: glass.bounds)
        content.autoresizingMask = [.width, .height]
        content.field.delegate = self
        glass.addSubview(content)
        w.contentView = glass
        self.window = w
        self.content = content
        return w
    }

    /// Centred on the screen with the pointer, placed so the bar at its tallest is centred.
    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        top = visible.midY + SearchBarMetrics.maxHeight / 2
        window.setFrame(frame(rows: model.results.count, centredIn: visible), display: false)
    }

    private func frame(rows: Int, centredIn visible: CGRect? = nil) -> CGRect {
        let height = SearchBarMetrics.height(rows: rows)
        let midX = visible?.midX ?? window?.frame.midX ?? 0
        return CGRect(x: (midX - SearchBarMetrics.width / 2).rounded(), y: top - height,
                      width: SearchBarMetrics.width, height: height)
    }

    private func fitHeight() {
        guard let window else { return }
        let target = frame(rows: model.results.count)
        if target != window.frame { window.setFrame(target, display: window.isVisible) }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = content?.field else { return }
        model.setQuery(field.stringValue)
    }

    // MARK: Snapshot

    func writeSnapshot(to url: URL, query: String, results: [SearchResult]) throws {
        try SearchBarSnapshot.write(query: query, results: results, to: url)
    }
}

/// The bar's window: a HUD panel that gives the bar's keys (arrows, Return, ⌘1–9, Esc) to the
/// bar before the text field sees them, unless an input method is composing; every other key
/// edits the field.
final class SearchPanelWindow: HUDPanelWindow {
    var onCommand: ((SearchCommand) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           let command = SearchKeys.command(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                            modifiers: event.modifierFlags,
                                            composing: (firstResponder as? NSTextView)?.hasMarkedText() ?? false),
           onCommand?(command) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// Runs what the bar's rows do.
@MainActor
final class SearchPerformer {
    /// Applies, previews or clears and applies a loadout by name (the loadout menu's own paths).
    var loadout: (String, SearchAction.LoadoutRun) -> Void = { _, _ in }
    var snippets: SnippetSource?

    func perform(_ action: SearchAction) {
        switch action {
        case .launch(let path):
            let url = URL(fileURLWithPath: path)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            // A running app is activated rather than launched again.
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    Toast.show("Could not open \(url.deletingPathExtension().lastPathComponent)", detail: message, seconds: 4)
                }
            }
        case .openFile(let path):
            if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
                Toast.show("Could not open \((path as NSString).lastPathComponent)", seconds: 4)
            }
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .loadout(let name, let run):
            loadout(name, run)
        case .insertSnippet(let id):
            guard let snippets else { return }
            snippets.insert(id: id) { reply in
                guard let problem = StashSnippets.problem(in: reply) else { return }
                Toast.show("Snippet not inserted", detail: problem, seconds: 4)
            }
        }
    }
}

/// The bar rendered offscreen, for review: in a window that is never ordered in, over a dark
/// stand-in for the glass (the live blur cannot render offscreen).
@MainActor
enum SearchBarSnapshot {
    static func render(query: String, results: [SearchResult], selection: Int = 0) -> NSBitmapImageRep? {
        let size = CGSize(width: SearchBarMetrics.width, height: SearchBarMetrics.height(rows: results.count))
        let model = SearchModel(engine: SearchEngine(apps: NoApps(), counts: { [:] }, loadouts: { [] }, snippets: nil, files: nil))
        model.present(query: query, results: results, selection: selection)
        let host = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).cgColor
        root.layer?.cornerRadius = SearchBarMetrics.cornerRadius
        root.appearance = NSAppearance(named: .darkAqua)
        let content = SearchBarContentView(model: model, frame: root.bounds)
        content.field.stringValue = query
        root.addSubview(content)
        host.contentView = root
        for _ in 0..<4 {
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return nil }
        root.cacheDisplay(in: root.bounds, to: rep)
        host.contentView = nil
        host.close()
        return rep
    }

    @discardableResult
    static func write(query: String, results: [SearchResult], selection: Int = 0, to url: URL) throws -> URL {
        guard let rep = render(query: query, results: results, selection: selection),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @MainActor
    private final class NoApps: AppSource {
        var apps: [AppEntry] { [] }
        func refreshIfStale() {}
    }
}
