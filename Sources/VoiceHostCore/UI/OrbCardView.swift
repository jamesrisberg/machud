import AppKit

/// The card under the orb: a failure message, and the agent's card (prompt, streaming reply,
/// progress lines, an approval with Approve and Deny, "Open in …" for the brain's session, a
/// close button). Drawn on the same near-black as the waveform body so it reads as grown out
/// of the notch, and so the text stays legible over whatever is underneath.
///
/// It grows out of the orb: `layoutGrow` places the shape between the orb and the card and
/// fades the content in once the shape is mostly open. The view never moves its content with
/// the window's edges; the shape and the content are placed in screen terms.
final class OrbCardView: NSView {
    var onApprove: ((String) -> Void)?
    var onDeny: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onOpenSession: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private(set) var card: VoiceCard?
    private(set) var errorMessage: String?
    private(set) var sessionLink: String?
    /// The background shape and its corner radius in this view; nil fills the bounds.
    private(set) var shapeRect: CGRect?
    private var shapeRadius: CGFloat?
    /// The card's own rect in this view; nil is the bounds.
    private var contentRect: CGRect?
    /// Clips the content to the shape, so text never shows outside it while it grows.
    private let clip = FlippedView()

    static let inset: CGFloat = 14
    private var contentWidth: CGFloat { OrbLayout.cardWidth - Self.inset * 2 }

    private let stack = NSStackView()
    private var stackWidth: NSLayoutConstraint!
    private var stackTop: NSLayoutConstraint!
    private var stackLeading: NSLayoutConstraint!
    private let sessionRow = NSStackView()
    private let errorLabel = OrbCardView.label(size: 12, weight: .medium, color: NSColor(srgbRed: 1, green: 0.5, blue: 0.47, alpha: 1))
    private let promptLabel = OrbCardView.label(size: 12, weight: .regular, color: .secondaryLabelColor)
    private let replyLabel = OrbCardView.label(size: 13, weight: .regular, color: .labelColor)
    private let progressLabel = OrbCardView.label(size: 11, weight: .regular, color: .tertiaryLabelColor, monospaced: true)
    private let approvalBox = NSStackView()
    private let approvalSummary = OrbCardView.label(size: 13, weight: .semibold, color: .labelColor)
    private let approvalDetail = OrbCardView.label(size: 11, weight: .regular, color: .secondaryLabelColor, monospaced: true)
    private let promptRow = NSStackView()
    private(set) lazy var closeButton = OrbCardView.iconButton(symbol: "xmark", label: "Close reply", target: self, action: #selector(close))
    private(set) lazy var approveButton = OrbCardView.textButton("Approve", target: self, action: #selector(approve))
    private(set) lazy var denyButton = OrbCardView.textButton("Deny", target: self, action: #selector(deny))
    private(set) lazy var openSessionButton = OrbCardView.linkButton(target: self, action: #selector(openSession))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func build() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.inset - 2, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(stack)
        // Pinned to the card's place, not to the view's or the shape's edges: while the card
        // grows the view also covers the orb, and the content must not ride moving edges.
        stackTop = stack.topAnchor.constraint(equalTo: clip.topAnchor)
        stackLeading = stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor)
        stackWidth = stack.widthAnchor.constraint(equalToConstant: OrbLayout.cardWidth)
        NSLayoutConstraint.activate([stackTop, stackLeading, stackWidth])

        promptRow.orientation = .horizontal
        promptRow.alignment = .top
        promptRow.spacing = 8
        promptLabel.maximumNumberOfLines = 2
        promptLabel.preferredMaxLayoutWidth = contentWidth - 26
        promptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.widthAnchor.constraint(equalToConstant: contentWidth - 26).isActive = true
        promptRow.addArrangedSubview(promptLabel)
        promptRow.addArrangedSubview(closeButton)
        promptRow.translatesAutoresizingMaskIntoConstraints = false

        replyLabel.maximumNumberOfLines = 14
        progressLabel.maximumNumberOfLines = OrbCardText.progressLimit

        approvalBox.orientation = .vertical
        approvalBox.alignment = .leading
        approvalBox.spacing = 6
        approvalBox.wantsLayer = true
        approvalBox.layer?.cornerRadius = 10
        approvalBox.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 0.12).cgColor
        approvalBox.layer?.borderColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 0.35).cgColor
        approvalBox.layer?.borderWidth = 0.5
        approvalBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        approvalSummary.maximumNumberOfLines = 3
        approvalDetail.maximumNumberOfLines = 4
        let buttons = NSStackView(views: [NSView(), denyButton, approveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        approvalBox.addArrangedSubview(approvalSummary)
        approvalBox.addArrangedSubview(approvalDetail)
        approvalBox.addArrangedSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        approvalBox.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: approvalBox.widthAnchor, constant: -20).isActive = true
        for label in [approvalSummary, approvalDetail] { label.preferredMaxLayoutWidth = contentWidth - 20 }
        for label in [errorLabel, replyLabel, progressLabel] { label.preferredMaxLayoutWidth = contentWidth }

        sessionRow.orientation = .horizontal
        sessionRow.addArrangedSubview(NSView())
        sessionRow.addArrangedSubview(openSessionButton)
        sessionRow.translatesAutoresizingMaskIntoConstraints = false

        for view in [errorLabel, promptRow, replyLabel, progressLabel, approvalBox, sessionRow] as [NSView] {
            stack.addArrangedSubview(view)
        }
        promptRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        approvalBox.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        sessionRow.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    }

    /// Shows `card` (nil hides the card part), `errorMessage` (nil hides the message) and the
    /// "Open in …" button titled `sessionLink` (nil hides it).
    func update(card: VoiceCard?, errorMessage: String?, sessionLink: String? = nil) {
        self.card = card
        self.errorMessage = errorMessage
        self.sessionLink = card == nil ? nil : sessionLink
        sessionRow.isHidden = self.sessionLink == nil
        openSessionButton.title = self.sessionLink ?? ""
        openSessionButton.setAccessibilityLabel(self.sessionLink ?? "")
        errorLabel.stringValue = errorMessage ?? ""
        errorLabel.isHidden = errorMessage == nil
        promptRow.isHidden = card == nil
        promptLabel.stringValue = card?.prompt ?? ""
        let reply = OrbCardText.replyTail(card?.reply ?? "")
        replyLabel.stringValue = reply
        replyLabel.isHidden = card == nil || reply.isEmpty
        let progress = OrbCardText.progressTail(card?.progress ?? [])
        progressLabel.stringValue = progress.map { "› " + $0 }.joined(separator: "\n")
        progressLabel.isHidden = card == nil || progress.isEmpty
        approvalBox.isHidden = card?.approval == nil
        approvalSummary.stringValue = card?.approval?.summary ?? ""
        approvalDetail.stringValue = card?.approval?.detail ?? ""
        approvalDetail.isHidden = (card?.approval?.detail ?? "").isEmpty
        if let approval = card?.approval {
            approveButton.setAccessibilityLabel("Approve: \(approval.summary)")
            denyButton.setAccessibilityLabel("Deny: \(approval.summary)")
        }
        stack.spacing = card == nil ? 0 : 8
        // A message alone is a compact pill sized to its text.
        let width = card == nil ? Self.messageWidth(errorMessage ?? "", font: errorLabel.font) : OrbLayout.cardWidth
        stackWidth.constant = width
        errorLabel.preferredMaxLayoutWidth = width - Self.inset * 2
        errorLabel.alignment = card == nil ? .center : .left
        stack.alignment = card == nil ? .centerX : .leading
        stack.edgeInsets = card == nil
            ? NSEdgeInsets(top: 7, left: Self.inset, bottom: 7, right: Self.inset)
            : NSEdgeInsets(top: Self.inset - 2, left: Self.inset, bottom: Self.inset, right: Self.inset)
        needsDisplay = true
    }

    private static func messageWidth(_ message: String, font: NSFont?) -> CGFloat {
        let text = (message as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        return min(OrbLayout.cardWidth, max(OrbLayout.orbDiameter * 4, ceil(text) + 8 + inset * 2))
    }

    /// The size the card wants for its current content.
    var fittingCardSize: CGSize {
        layoutSubtreeIfNeeded()
        return CGSize(width: stackWidth.constant, height: ceil(stack.fittingSize.height))
    }

    /// Lays the card out at grow progress `t` between the orb and the card (screen frames) and
    /// returns the frame the card's window takes: the shape travels from the orb to the card
    /// while the content stays in the card's place, fading in once the shape is mostly open.
    @discardableResult
    func layoutGrow(progress t: CGFloat, card: CGRect, orb: CGRect) -> CGRect {
        let frame = OrbLayout.growWindowFrame(progress: t, orb: orb, card: card)
        let shape = OrbLayout.growShape(progress: t, orb: orb, card: card)
        // Screen rects to this flipped view, whose frame is `frame`.
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
        }
        shapeRect = local(shape.rect)
        shapeRadius = shape.radius
        contentRect = local(card)
        stack.alphaValue = OrbLayout.contentAlpha(progress: t)
        needsLayout = true
        needsDisplay = true
        return frame
    }

    override func layout() {
        let shape = shapeRect ?? bounds
        clip.frame = shape
        clip.layer?.cornerRadius = min(shapeRadius ?? OrbLayout.cardRadius(shape.size), shape.width / 2, shape.height / 2)
        let content = contentRect ?? bounds
        stackTop.constant = content.minY - shape.minY
        stackLeading.constant = content.minX - shape.minX
        super.layout()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = shapeRect ?? bounds
        let radius = min(shapeRadius ?? OrbLayout.cardRadius(rect.size), rect.width / 2, rect.height / 2)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        NSColor(white: 0.04, alpha: 0.94).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    // MARK: Actions

    @objc private func approve() { if let id = card?.approval?.id { onApprove?(id) } }
    @objc private func deny() { if let id = card?.approval?.id { onDeny?(id) } }
    @objc private func close() { onClose?() }
    @objc private func openSession() { onOpenSession?() }

    /// Only the shape takes clicks; while it grows, the rest of the window is empty.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let shapeRect else { return super.hitTest(point) }
        return shapeRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    // MARK: Building blocks

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor, monospaced: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    private static func iconButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 18).isActive = true
        button.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return button
    }

    /// A quiet text button with an arrow: "Open in …".
    private static func linkButton(target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: target, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        button.imagePosition = .imageTrailing
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.contentTintColor = NSColor(srgbRed: 0.45, green: 0.8, blue: 1, alpha: 1)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private static func textButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        return button
    }
}

/// A top-down container.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
