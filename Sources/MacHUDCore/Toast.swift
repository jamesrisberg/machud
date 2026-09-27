import AppKit

/// A brief, non-interactive HUD pill (jelly glass) near the top of a screen.
/// Used to report what an apply or capture did, since those run from hotkeys
/// with no window of their own.
@MainActor
enum Toast {
    private static var window: NSWindow?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, detail: String? = nil, on screen: NSScreen? = nil, seconds: TimeInterval = 2.5) {
        let screen = screen ?? ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else { return }
        hideWork?.cancel()
        window?.orderOut(nil)

        let view = ToastView(text: text, detail: detail)
        let size = view.fittingSize
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 48)
        let w = NSWindow(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; w.animator().alphaValue = 1 }
        window = w

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.3; w.animator().alphaValue = 0 },
                                                completionHandler: { w.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension Toast {
    private static var askWindow: NSPanel?
    private static var askHide: DispatchWorkItem?
    private static var askAction: (() -> Void)?

    /// A toast with one button, for offers ("No layout, open the editor?"). Clicking it
    /// does not activate MacHUD until the action itself does; it fades after `seconds`.
    static func ask(_ text: String, button: String, on screen: NSScreen? = nil, seconds: TimeInterval = 5,
                    action: @escaping () -> Void) {
        let screen = screen ?? ScreenCoords.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else { return }
        askHide?.cancel()
        askWindow?.orderOut(nil)
        askAction = action

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        let target = AskTarget.shared
        let b = NSButton(title: button, target: target, action: #selector(AskTarget.pressed))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        let dismiss = NSButton(title: "Not Now", target: target, action: #selector(AskTarget.dismissed))
        dismiss.bezelStyle = .rounded
        let stack = NSStackView(views: [label, dismiss, b])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 12)
        let pill = ToastView(text: "", detail: nil)
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor), stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor), stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
        let size = stack.fittingSize
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 48)
        let w = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = pill
        w.orderFrontRegardless()
        askWindow = w
        let work = DispatchWorkItem { dismissAsk() }
        askHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    fileprivate static func dismissAsk(run: Bool = false) {
        askHide?.cancel()
        askWindow?.orderOut(nil)
        askWindow = nil
        let action = askAction
        askAction = nil
        if run { action?() }
    }

    /// True while an offer is on screen (tests and `menu` introspection).
    static var isAsking: Bool { askWindow != nil }
}

@MainActor
private final class AskTarget: NSObject {
    static let shared = AskTarget()
    @objc func pressed() { Toast.dismissAsk(run: true) }
    @objc func dismissed() { Toast.dismissAsk() }
}

private final class ToastView: NSView {
    private let text: String
    private let detail: String?

    init(text: String, detail: String?) {
        self.text = text
        self.detail = detail
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var attributed: NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
        if let detail, !detail.isEmpty {
            s.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8), .paragraphStyle: para]))
        }
        return s
    }

    override var fittingSize: NSSize {
        let s = attributed.boundingRect(with: CGSize(width: 520, height: 200), options: [.usesLineFragmentOrigin]).size
        return CGSize(width: ceil(s.width) + 40, height: ceil(s.height) + 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor(calibratedWhite: 0.1, alpha: 0.9).setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let top = CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.02)])?.draw(in: top, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        path.lineWidth = 1
        path.stroke()
        attributed.draw(in: bounds.insetBy(dx: 20, dy: 11))
    }
}
