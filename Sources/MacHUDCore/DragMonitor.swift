import AppKit
import ApplicationServices

/// Watches for the user dragging any app's window and snaps it to a region on drop.
final class DragMonitor {
    private let store: LayoutStore
    private let overlay = OverlayController()
    private var monitors: [Any] = []
    private var keyTap: CFMachPort?
    private var running = false
    /// Whether a window at this frame (Cocoa coordinates) is a desktop widget MacHUD placed.
    var isWidget: ((CGRect) -> Bool)?
    /// Set while the layout editor is open so drags are ignored.
    var suspended = false {
        didSet { if suspended { cancel() } }
    }
    /// Called (once per drag) when the user triggers snapping but no layout with regions
    /// exists. Dragging only ever snaps: the app answers with a toast that offers the
    /// editor, it never opens the editor from a drag.
    var onNoLayout: (() -> Void)?

    private struct Session {
        let window: AXWindow
        let startFrame: CGRect          // AX coords at mouse down
        var dragging = false            // becomes true once the window has actually moved
        var screen: NSScreen?
        var target: Int?
        var lastCheck: TimeInterval = 0
        /// The "no layout" toast was shown during this drag.
        var toldNoLayout = false
    }
    private var session: Session?

    init(store: LayoutStore) {
        self.store = store
        store.onChange = { [weak self] in self?.refreshTarget() }
    }

    func start() {
        guard !running else { return }
        running = true
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.mouseDown() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in self?.mouseDragged() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.mouseUp() } as Any)
        installKeyTap()
    }

    // MARK: Mouse

    private func mouseDown() {
        session = nil
        guard store.enabled, !suspended else { return }
        let p = NSEvent.mouseLocation
        guard let window = AXWindow.under(cocoaPoint: p), let frame = window.axFrame else { return }
        // A desktop widget moves on MacHUD's widget grid, never into a region.
        if let cocoa = window.cocoaFrame, isWidget?(cocoa) == true { return }
        session = Session(window: window, startFrame: frame)
    }

    private func mouseDragged() {
        guard var s = session else { return }
        let now = CACurrentMediaTime()

        if !s.dragging {
            // Poll the window's frame (throttled); a moved-but-not-resized window means a drag.
            guard now - s.lastCheck > 0.04 else { return }
            s.lastCheck = now
            guard let frame = s.window.axFrame else { session = nil; return }
            let moved = frame.origin != s.startFrame.origin
            let resized = frame.size != s.startFrame.size
            if resized { session = nil; return }
            guard moved else { session = s; return }
            s.dragging = true
        }
        session = s
        refreshTarget()
    }

    private func mouseUp() {
        guard let s = session else { return }
        session = nil
        guard s.dragging else { return }
        overlay.hide()
        guard store.trigger.isHeld(NSEvent.modifierFlags),
              let t = s.target, let screen = s.screen, let layout = store.activeLayout,
              layout.regions.indices.contains(t) else { return }

        let cocoa = regionRect(layout.regions[t], on: screen)
        let ax = ScreenCoords.axRect(fromCocoa: cocoa)
        s.window.setAXFrame(ax)
        // Some apps finish their own drag after mouse-up and overwrite our position; re-apply.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { s.window.setAXFrame(ax) }
    }

    private func cancel() {
        session = nil
        overlay.hide()
    }

    // MARK: Target computation

    /// Recompute which region the cursor is over and redraw the overlay.
    private func refreshTarget() {
        guard var s = session, s.dragging else { return }
        // Only engage while the trigger modifier is held; otherwise it is a plain drag.
        guard store.trigger.isHeld(NSEvent.modifierFlags) else {
            if s.screen != nil { overlay.hide() }
            s.screen = nil
            s.target = nil
            session = s
            return
        }
        // Nothing to snap to yet: say so once, let the drag carry on as a plain drag.
        guard let layout = store.activeLayout, !layout.regions.isEmpty else {
            if !s.toldNoLayout {
                s.toldNoLayout = true
                overlay.hide()
                onNoLayout?()
            }
            s.screen = nil
            s.target = nil
            session = s
            return
        }
        let p = NSEvent.mouseLocation
        guard let screen = ScreenCoords.screen(containing: p) else {
            s.target = nil; session = s; return
        }
        if s.screen != screen {
            s.screen = screen
            overlay.show(on: screen)
        }

        let visible = screen.visibleFrame
        let regions = layout.regions.map { regionRect($0, on: screen) }
        let hits = layout.regions.map { $0.hitRect.cocoaRect(in: visible) }

        // Smallest hit zone containing the cursor wins, so a small central hit zone
        // can sit inside a large region's hit zone.
        var best: (index: Int, area: CGFloat)?
        for (i, h) in hits.enumerated() where h.contains(p) {
            let area = h.width * h.height
            if best == nil || area < best!.area { best = (i, area) }
        }
        s.target = best?.index
        session = s

        overlay.update(
            regions: regions,
            hits: hits,
            names: layout.regions.enumerated().map { $0.element.name ?? "Region \($0.offset + 1)" },
            target: s.target,
            title: layout.name,
            triggerSymbol: store.trigger.symbol)
    }

    private func regionRect(_ region: Region, on screen: NSScreen) -> CGRect {
        LoadoutEngine.regionRect(region, visible: screen.visibleFrame, gap: store.gap)
    }

    // MARK: Keyboard (Tab cycles layouts, Esc cancels — only while dragging)

    private func installKeyTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<DragMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleKey(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("MacHUD: could not create key event tap (Tab/Esc during drag disabled)")
            return
        }
        keyTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleKey(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let s = session, s.dragging else { return Unmanaged.passUnretained(event) }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case 48: // Tab
            store.cycle()
            return nil
        case 53: // Escape
            cancel()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
