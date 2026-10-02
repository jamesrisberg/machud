import AppKit

/// The card grown into the conversation: every row (what the user said, by voice or typed,
/// replies as they stream, progress lines, approvals with Allow and Deny, notices), newest at
/// the bottom, scrollable. Pinned it hangs where the card does and a click expands it;
/// expanded it adds a field for typing to the agent.
///
/// The list follows new rows while it is scrolled to the bottom and stays put once the user
/// scrolls up. Same near-black glass as the card, so it reads as the card grown larger.
final class ConversationPanelView: NSView, NSTextViewDelegate {
    enum Mode: Equatable {
        case pinned, expanded
    }

    var onApprove: ((String) -> Void)?
    var onDeny: ((String) -> Void)?
    /// Sends a typed message; nil once it is on its way, else why not (shown above the field).
    var onSend: ((String) -> String?)?
    var onExpand: (() -> Void)?
    /// Esc, or the close button while expanded.
    var onCollapse: (() -> Void)?
    /// The close button while pinned (closes the card, as the card's own close button does).
    var onClose: (() -> Void)?
    var onOpenSession: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private(set) var mode: Mode = .pinned
    private(set) var rows: [ConversationRow] = []
    private(set) var busy = false
    /// The list has been built once (an empty conversation still shows its note).
    private var built = false
    private var lastSent: String?

    static let inset: CGFloat = 14
    static let headerHeight: CGFloat = 20
    static let gap: CGFloat = 6
    static let radius: CGFloat = 16

    private let titleLabel = ConversationPanelView.label(size: 12, weight: .semibold, color: .secondaryLabelColor)
    private(set) lazy var closeButton = ConversationPanelView.iconButton(
        symbol: "xmark", label: "Close conversation", target: self, action: #selector(closeClicked))
    private(set) lazy var openSessionButton = ConversationPanelView.linkButton(target: self, action: #selector(openSession))
    private let header = NSStackView()
    let scrollView = NSScrollView()
    private let document = ConversationFlippedView()
    private let stack = NSStackView()
    private let emptyLabel = ConversationPanelView.label(size: 12, weight: .regular, color: .tertiaryLabelColor)
    private var rowViews: [String: ConversationRowView] = [:]
    private var followsBottom = true

    private let footer = NSStackView()
    private let hintLabel = ConversationPanelView.label(size: 10, weight: .regular, color: .tertiaryLabelColor)
    private let statusLabel = ConversationPanelView.label(size: 11, weight: .medium,
                                                          color: NSColor(srgbRed: 1, green: 0.72, blue: 0.35, alpha: 1))
    private let composerBox = NSView()
    private let composerScroll = NSScrollView()
    let composer = ComposerTextView()
    private var composerHeight: NSLayoutConstraint!
    private var widthConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Conversation with the agent")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Building

    private func build() {
        titleLabel.stringValue = "Conversation"
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [titleLabel, spacer, openSessionButton, closeButton] as [NSView] { header.addArrangedSubview(view) }
        addSubview(header)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 2, left: Self.inset, bottom: 8, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        emptyLabel.stringValue = "No conversation yet."
        addSubview(scrollView)
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: clip)

        composerBox.wantsLayer = true
        composerBox.layer?.cornerRadius = 10
        composerBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        composerBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        composerBox.layer?.borderWidth = 0.5
        composerBox.translatesAutoresizingMaskIntoConstraints = false
        composerScroll.drawsBackground = false
        composerScroll.hasVerticalScroller = true
        composerScroll.autohidesScrollers = true
        composerScroll.scrollerStyle = .overlay
        composerScroll.translatesAutoresizingMaskIntoConstraints = false
        composer.delegate = self
        composer.isRichText = false
        composer.allowsUndo = true
        composer.drawsBackground = false
        composer.font = .systemFont(ofSize: 13)
        composer.textColor = .labelColor
        composer.insertionPointColor = .labelColor
        composer.textContainerInset = NSSize(width: 4, height: 6)
        composer.isVerticallyResizable = true
        composer.isHorizontallyResizable = false
        composer.autoresizingMask = [.width]
        composer.textContainer?.widthTracksTextView = true
        composer.setAccessibilityLabel("Message to the agent")
        composerScroll.documentView = composer
        composerBox.addSubview(composerScroll)
        composerHeight = composerBox.heightAnchor.constraint(equalToConstant: ComposerTextView.minHeight)
        NSLayoutConstraint.activate([
            composerScroll.leadingAnchor.constraint(equalTo: composerBox.leadingAnchor, constant: 4),
            composerScroll.trailingAnchor.constraint(equalTo: composerBox.trailingAnchor, constant: -4),
            composerScroll.topAnchor.constraint(equalTo: composerBox.topAnchor, constant: 2),
            composerScroll.bottomAnchor.constraint(equalTo: composerBox.bottomAnchor, constant: -2),
            composerHeight,
        ])

        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        for view in [statusLabel, composerBox, hintLabel] as [NSView] { footer.addArrangedSubview(view) }
        addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Self.gap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -Self.gap),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        applyMode()
    }

    // MARK: Content

    /// Shows `rows` in `mode`; `busy` while the agent works on a turn, `sessionLink` titles
    /// "Open in …" (nil hides it). Rows are kept by id, so a streaming reply updates in place.
    func update(rows: [ConversationRow], mode: Mode, busy: Bool, sessionLink: String?) {
        let modeChanged = mode != self.mode
        self.mode = mode
        self.busy = busy
        openSessionButton.isHidden = sessionLink == nil
        openSessionButton.title = sessionLink ?? ""
        openSessionButton.setAccessibilityLabel(sessionLink ?? "")
        if modeChanged { applyMode() }
        updatePlaceholder()
        guard rows != self.rows || modeChanged || !built else { return }
        built = true
        let follow = followsBottom
        self.rows = rows
        let width = contentWidth
        var views: [NSView] = []
        var kept: [String: ConversationRowView] = [:]
        for row in rows {
            let view = rowViews[row.id].flatMap { $0.kind == row.kind ? $0 : nil } ?? makeRowView(row.kind)
            view.configure(row, width: width, shortcuts: mode == .expanded)
            kept[row.id] = view
            views.append(view)
        }
        rowViews = kept
        if rows.isEmpty { views = [emptyLabel] }
        if stack.arrangedSubviews != views {
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            views.forEach { stack.addArrangedSubview($0) }
        }
        layoutSubtreeIfNeeded()
        if follow { scrollToBottom() }
    }

    /// The panel's width less its insets, which every row fills.
    private var contentWidth: CGFloat { panelWidth - Self.inset * 2 }

    /// The width the panel is laid out for (the pinned or the expanded frame's); set before
    /// `update`.
    var panelWidth: CGFloat = OrbLayout.pinnedWidth {
        didSet {
            guard panelWidth != oldValue else { return }
            applyMode()
            for (id, view) in rowViews {
                if let row = rows.first(where: { $0.id == id }) {
                    view.configure(row, width: contentWidth, shortcuts: mode == .expanded)
                }
            }
        }
    }

    /// The height the pinned panel wants for its rows: header, list and hint.
    var fittingHeight: CGFloat {
        layoutSubtreeIfNeeded()
        let list = stack.fittingSize.height
        let foot = footer.fittingSize.height
        return 10 + Self.headerHeight + Self.gap + list + Self.gap + foot + 12
    }

    private func makeRowView(_ kind: ConversationRow.Kind) -> ConversationRowView {
        let view = ConversationRowView(kind: kind)
        view.onApprove = { [weak self] in self?.onApprove?($0) }
        view.onDeny = { [weak self] in self?.onDeny?($0) }
        return view
    }

    private func applyMode() {
        let expanded = mode == .expanded
        composerBox.isHidden = !expanded
        statusLabel.isHidden = true
        statusLabel.stringValue = ""
        hintLabel.stringValue = expanded
            ? "↩ send   ⇧↩ new line   ↑ last message   ⌘K clear   esc close"
            : "Click to type to the agent"
        closeButton.setAccessibilityLabel(expanded ? "Collapse conversation" : "Close reply")
        NSLayoutConstraint.deactivate(widthConstraints)
        let width = contentWidth
        widthConstraints = [composerBox.widthAnchor.constraint(equalToConstant: width)]
        NSLayoutConstraint.activate(widthConstraints)
        for label in [statusLabel, hintLabel] { label.preferredMaxLayoutWidth = width }
        emptyLabel.stringValue = expanded ? "No conversation yet. Talk to the orb or type below." : "No conversation yet."
        needsLayout = true
    }

    private func updatePlaceholder() {
        composer.placeholder = busy ? "The agent is working…" : "Message the agent"
    }

    // MARK: Scrolling

    @objc private func scrolled() {
        let clip = scrollView.contentView.bounds
        followsBottom = clip.maxY >= document.frame.height - 24
    }

    func scrollToBottom() {
        let clip = scrollView.contentView
        let y = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
        followsBottom = true
    }

    // MARK: Typing

    /// Focuses the field (the panel is key).
    func focusComposer() {
        window?.makeFirstResponder(composer)
    }

    var composerText: String {
        get { composer.string }
        set {
            composer.string = newValue
            composer.setSelectedRange(NSRange(location: (newValue as NSString).length, length: 0))
            composerChanged()
        }
    }

    /// Return sends, Shift-Return starts a new line, Esc collapses, ↑ in an empty field recalls
    /// the last typed message, Tab moves to the approval buttons.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                send()
            }
            return true
        case #selector(NSResponder.insertLineBreak(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCollapse?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard textView.string.isEmpty, let recalled = lastSent ?? lastTyped else { return false }
            composerText = recalled
            return true
        case #selector(NSResponder.insertTab(_:)):
            window?.selectNextKeyView(nil)
            return true
        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        composerChanged()
    }

    private func composerChanged() {
        if !statusLabel.isHidden {
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        }
        composerHeight.constant = composer.fittingTextHeight
        composer.needsDisplay = true
    }

    /// The newest typed message in the conversation.
    private var lastTyped: String? {
        rows.last { $0.kind == .user && $0.source == .typed }?.text
    }

    /// Shows `message` above the field until the text changes.
    func showStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.isHidden = false
    }

    func send() {
        let text = composer.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let refusal = onSend?(text) {
            showStatus(refusal)
        } else {
            lastSent = text.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = ""
            scrollToBottom()
        }
    }

    /// ⌘K clears the field; ⌘Y allows and ⌘N denies the newest approval waiting for an answer.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard mode == .expanded, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "k":
            composerText = ""
            return true
        case "y", "n":
            guard let id = rows.last(where: \.isPendingApproval)?.approvalId else { return false }
            if event.charactersIgnoringModifiers?.lowercased() == "y" { onApprove?(id) } else { onDeny?(id) }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCollapse?()
    }

    // MARK: Mouse

    @objc private func closeClicked() {
        if mode == .expanded { onCollapse?() } else { onClose?() }
    }

    @objc private func openSession() { onOpenSession?() }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if mode == .pinned {
            onExpand?()
        } else {
            focusComposer()
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Set while the panel appears under a resting pointer, so leaving it reports an exit
    /// without an entry first.
    var assumesPointerInside = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        if assumesPointerInside { options.insert(.assumeInside) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: Self.radius, yRadius: Self.radius)
        NSColor(white: 0.04, alpha: 0.95).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
    }

    // MARK: Building blocks

    static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor, monospaced: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
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
}

/// One conversation row. A row keeps its kind; its content updates in place.
final class ConversationRowView: NSView {
    let kind: ConversationRow.Kind
    var onApprove: ((String) -> Void)?
    var onDeny: ((String) -> Void)?

    private let content = NSStackView()
    private let text = ConversationPanelView.label(size: 13, weight: .regular, color: .labelColor)
    private let icon = NSImageView()
    private let detail = ConversationPanelView.label(size: 11, weight: .regular, color: .secondaryLabelColor, monospaced: true)
    private let status: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()
    private let buttons = NSStackView()
    private(set) lazy var allowButton = KeyboardButton(title: "Allow", target: self, action: #selector(allow))
    private(set) lazy var denyButton = KeyboardButton(title: "Deny", target: self, action: #selector(deny))
    private var widthConstraint: NSLayoutConstraint!
    private var buttonsWidth: NSLayoutConstraint?
    private var approvalID: String?

    init(kind: ConversationRow.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.alignment = .leading
        addSubview(content)
        widthConstraint = widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthConstraint,
        ])
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        switch kind {
        case .user:
            // The icon beside the first line, the text wrapping beside it.
            content.isHidden = true
            layer?.cornerRadius = 10
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            icon.contentTintColor = .secondaryLabelColor
            text.textColor = NSColor(white: 0.92, alpha: 1)
            for view in [icon, text] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.userInset),
                icon.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -4),
                icon.widthAnchor.constraint(equalToConstant: Self.userIcon),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.userInset),
                text.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            ])
        case .reply:
            content.orientation = .vertical
            content.addArrangedSubview(text)
        case .progress:
            content.orientation = .vertical
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.textColor = .tertiaryLabelColor
            content.addArrangedSubview(text)
        case .notice:
            content.orientation = .vertical
            text.font = .systemFont(ofSize: 11, weight: .medium)
            content.addArrangedSubview(text)
        case .approval:
            content.orientation = .vertical
            content.spacing = 6
            content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            layer?.cornerRadius = 10
            layer?.backgroundColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 0.12).cgColor
            layer?.borderColor = NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 0.35).cgColor
            layer?.borderWidth = 0.5
            text.font = .systemFont(ofSize: 13, weight: .semibold)
            for button in [denyButton, allowButton] {
                button.bezelStyle = .rounded
                button.controlSize = .small
            }
            buttons.orientation = .horizontal
            buttons.spacing = 8
            buttons.addArrangedSubview(status)
            buttons.addArrangedSubview(NSView())
            buttons.addArrangedSubview(denyButton)
            buttons.addArrangedSubview(allowButton)
            for view in [text, detail, buttons] as [NSView] { content.addArrangedSubview(view) }
        }
    }

    func configure(_ row: ConversationRow, width: CGFloat, shortcuts: Bool) {
        widthConstraint.constant = width
        let inner = width - content.edgeInsets.left - content.edgeInsets.right
        switch kind {
        case .user:
            let typed = row.source == .typed
            icon.image = NSImage(systemSymbolName: typed ? "keyboard" : "mic.fill",
                                 accessibilityDescription: typed ? "Typed" : "Spoken")
            text.stringValue = row.text
            text.preferredMaxLayoutWidth = width - Self.userInset * 2 - Self.userIcon - 8
            setAccessibilityLabel("You \(typed ? "typed" : "said"): \(row.text)")
        case .reply:
            text.stringValue = row.text
            text.preferredMaxLayoutWidth = inner
            // Selectable only in the expanded panel, which takes key; pinned, a click expands.
            text.isSelectable = shortcuts
        case .progress:
            let attributed = NSMutableAttributedString(string: "● ", attributes: [
                .foregroundColor: Self.color(for: row.step ?? .done),
                .font: NSFont.systemFont(ofSize: 8),
            ])
            attributed.append(NSAttributedString(string: row.text, attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            ]))
            text.attributedStringValue = attributed
            text.preferredMaxLayoutWidth = inner
        case .notice:
            text.stringValue = row.text
            text.textColor = row.isError == true ? NSColor(srgbRed: 1, green: 0.5, blue: 0.47, alpha: 1) : .secondaryLabelColor
            text.preferredMaxLayoutWidth = inner
        case .approval:
            approvalID = row.approvalId
            text.stringValue = row.text
            text.preferredMaxLayoutWidth = inner
            detail.stringValue = row.detail ?? ""
            detail.isHidden = (row.detail ?? "").isEmpty
            detail.preferredMaxLayoutWidth = inner
            let answerable = row.isPendingApproval
            denyButton.isHidden = !answerable
            allowButton.isHidden = !answerable
            allowButton.toolTip = shortcuts ? "Allow (⌘Y)" : nil
            denyButton.toolTip = shortcuts ? "Deny (⌘N)" : nil
            allowButton.setAccessibilityLabel("Allow: \(row.text)")
            denyButton.setAccessibilityLabel("Deny: \(row.text)")
            status.stringValue = Self.status(for: row, shortcuts: shortcuts)
            status.isHidden = status.stringValue.isEmpty
            if buttonsWidth == nil {
                buttons.translatesAutoresizingMaskIntoConstraints = false
                buttonsWidth = buttons.widthAnchor.constraint(equalToConstant: inner)
                buttonsWidth?.isActive = true
            }
            buttonsWidth?.constant = inner
        }
    }

    private static let userInset: CGFloat = 10
    private static let userIcon: CGFloat = 14

    static func status(for row: ConversationRow, shortcuts: Bool) -> String {
        switch row.decision ?? .pending {
        case .pending: return shortcuts ? "⌘Y allow · ⌘N deny" : ""
        case .delivering: return "Sending…"
        case .allowed: return "Allowed"
        case .denied: return "Denied"
        case .resolved: return "Answered"
        case .failed: return "Couldn't send: \(row.error ?? "try again")"
        }
    }

    private static func color(for step: ConversationRow.Step) -> NSColor {
        switch step {
        case .running: NSColor(srgbRed: 0.45, green: 0.8, blue: 1, alpha: 1)
        case .done: NSColor(white: 0.5, alpha: 1)
        case .failed: NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1)
        case .denied: NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 1)
        }
    }

    @objc private func allow() { if let approvalID { onApprove?(approvalID) } }
    @objc private func deny() { if let approvalID { onDeny?(approvalID) } }
}

/// A button Tab reaches whether or not Full Keyboard Access is on, so an approval can be
/// answered from the keyboard; Space presses it.
final class KeyboardButton: NSButton {
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }
    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { performClick(nil) } else { super.keyDown(with: event) }
    }
}

/// The message field: grows with its text up to a few lines, with a placeholder while empty.
final class ComposerTextView: NSTextView {
    static let minHeight: CGFloat = 34
    static let maxHeight: CGFloat = 120

    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }

    /// The box height for the text: one line at least, `maxHeight` at most (it scrolls beyond).
    var fittingTextHeight: CGFloat {
        guard let layoutManager, let textContainer else { return Self.minHeight }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2 + 4
        return min(max(ceil(used), Self.minHeight), Self.maxHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}

final class ConversationFlippedView: NSView {
    override var isFlipped: Bool { true }
}
