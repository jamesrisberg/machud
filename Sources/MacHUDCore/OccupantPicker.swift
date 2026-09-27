import AppKit

/// Popover content for assigning an `Occupant` to a region: a searchable list of
/// running (or, toggled, installed) apps, a URL field for web occupants, the
/// registered panels, and Clear. Anchored to the editor's fourth card button.
final class OccupantPicker: NSViewController {
    struct AppEntry {
        var bundleID: String
        var name: String
        var icon: NSImage?
    }

    /// Registered panels offered as `.panel(id:)` choices: MacHUD's own, then the
    /// sibling apps' (MacHUD-aware apps found on disk).
    var panelChoices: [PanelChoice] = []
    /// `Config.browser`, so a new web occupant defaults to the browser in use.
    var configuredBrowser: String?
    /// The occupant already assigned here, if any, used to prefill fields.
    var current: Occupant? {
        didSet { prefill() }
    }
    var onSelect: ((Occupant?) -> Void)?

    private let searchField = NSSearchField()
    private let titleMatchField = NSTextField()
    private let tableView = NSTableView()
    private let installedButton = NSButton(title: "Installed Apps…", target: nil, action: nil)
    private let urlField = NSTextField()
    /// Hosts offered for a web occupant: the browsers installed here, then MacHUD's own window.
    private let hosts: [WebHost] = OccupantPicker.availableHosts()
    private lazy var hostControl = NSSegmentedControl(labels: hosts.map(\.label), trackingMode: .selectOne,
                                                      target: nil, action: nil)
    private var panelButtons: [NSButton] = []

    private var runningApps: [AppEntry] = []
    private var installedApps: [AppEntry] = []
    private var showInstalled = false
    private var filtered: [AppEntry] = []

    private let contentWidth: CGFloat = 320

    override func loadView() {
        view = NSView(frame: CGRect(x: 0, y: 0, width: contentWidth, height: 10))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadRunningApps()
        buildUI()
        refreshFiltered()
        prefill()
    }

    // MARK: - Data

    private static func pidsWithOnScreenWindows() -> Set<pid_t> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids = Set<pid_t>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int else { continue }
            pids.insert(pid_t(pid))
        }
        return pids
    }

    private func loadRunningApps() {
        let withWindows = Self.pidsWithOnScreenWindows()
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && withWindows.contains($0.processIdentifier) }
            .compactMap { app -> AppEntry? in
                guard let bid = app.bundleIdentifier else { return nil }
                return AppEntry(bundleID: bid, name: app.localizedName ?? bid, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadInstalledApps() {
        guard installedApps.isEmpty else { return }
        let fm = FileManager.default
        var entries: [AppEntry] = []
        var seen = Set<String>()
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = dir + "/" + item
                guard let bundle = Bundle(path: path), let bid = bundle.bundleIdentifier, !seen.contains(bid) else { continue }
                seen.insert(bid)
                let name = fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                entries.append(AppEntry(bundleID: bid, name: name, icon: NSWorkspace.shared.icon(forFile: path)))
            }
        }
        installedApps = entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshFiltered() {
        let pool = showInstalled ? installedApps : runningApps
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = q.isEmpty ? pool : pool.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        tableView.reloadData()
    }

    private func prefill() {
        guard isViewLoaded else { return }
        switch current {
        case .app(let bundleID, let titleMatch):
            titleMatchField.stringValue = titleMatch ?? ""
            if let i = filtered.firstIndex(where: { $0.bundleID == bundleID }) {
                tableView.selectRowIndexes([i], byExtendingSelection: false)
            }
        case .web(let url, let host):
            urlField.stringValue = url
            select(host: host)
        case .panel, .none:
            break
        }
    }

    // MARK: - UI

    private func buildUI() {
        var y: CGFloat = 12

        func row(_ v: NSView, height: CGFloat, x: CGFloat = 12, width: CGFloat? = nil) {
            v.frame = CGRect(x: x, y: 0, width: width ?? (contentWidth - x * 2), height: height)
            view.addSubview(v)
        }

        // Built bottom-up in the flipped sense is fiddly with plain NSView; lay out
        // top-down by tracking a descending cursor and placing frames afterward.
        var elements: [(NSView, CGFloat)] = []

        let clearButton = NSButton(title: "Clear Occupant", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        elements.append((clearButton, 28))

        let sep3 = separator()
        elements.append((sep3, 1))

        let urlLabel = NSTextField(labelWithString: "Web URL")
        urlLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        urlLabel.textColor = .secondaryLabelColor
        elements.append((urlLabel, 16))

        urlField.placeholderString = "https://example.com"
        urlField.target = self
        urlField.action = #selector(setURLTapped)
        elements.append((urlField, 22))

        hostControl.segmentStyle = .rounded
        hostControl.segmentDistribution = .fillEqually
        select(host: WebHost.preferred(configuredBrowser: configuredBrowser, defaultHandler: SystemDefaultBrowser.bundleID))
        elements.append((hostControl, 24))

        let setURLButton = NSButton(title: "Set URL", target: self, action: #selector(setURLTapped))
        setURLButton.bezelStyle = .rounded
        elements.append((setURLButton, 24))

        let sep2 = separator()
        elements.append((sep2, 1))

        let groups: [(String, [PanelChoice])] = [("Panels", panelChoices.filter { !$0.isExternal }),
                                                 ("Sibling Apps", panelChoices.filter(\.isExternal))]
        for (heading, choices) in groups where !choices.isEmpty {
            let label = NSTextField(labelWithString: heading)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            elements.append((label, 16))
            for choice in choices {
                let b = NSButton(title: choice.label, target: self, action: #selector(panelTapped(_:)))
                b.bezelStyle = .rounded
                b.alignment = .left
                b.identifier = NSUserInterfaceItemIdentifier(choice.id)
                b.toolTip = choice.id
                if case .panel(let id)? = current, id == choice.id { b.state = .on }
                panelButtons.append(b)
                elements.append((b, 24))
            }
            elements.append((separator(), 1))
        }

        let titleMatchLabel = NSTextField(labelWithString: "Title match (regex, optional)")
        titleMatchLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleMatchLabel.textColor = .secondaryLabelColor
        elements.append((titleMatchLabel, 16))
        titleMatchField.placeholderString = "e.g. Inbox"
        elements.append((titleMatchField, 22))

        installedButton.target = self
        installedButton.action = #selector(toggleInstalled)
        installedButton.bezelStyle = .rounded
        elements.append((installedButton, 24))

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = contentWidth - 24 - 16
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(appRowClicked)
        tableView.rowHeight = 28
        scroll.documentView = tableView
        elements.append((scroll, 190))

        searchField.placeholderString = "Search running apps…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.delegate = self
        elements.append((searchField, 24))

        let appsLabel = NSTextField(labelWithString: "Apps")
        appsLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        appsLabel.textColor = .secondaryLabelColor
        elements.append((appsLabel, 16))

        // Reverse (we built bottom-to-top) and lay out top-down.
        let ordered = elements.reversed()
        let gap: CGFloat = 6
        for (v, h) in ordered {
            v.translatesAutoresizingMaskIntoConstraints = true
            row(v, height: h)
            y += h + gap
        }
        var cursor = y - gap
        for (v, h) in ordered {
            cursor -= h
            v.setFrameOrigin(CGPoint(x: v.frame.origin.x, y: cursor))
            cursor -= gap
        }
        view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: y)
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: - Actions

    @objc private func searchChanged() { refreshFiltered() }
    @objc private func toggleInstalled() {
        showInstalled.toggle()
        if showInstalled { loadInstalledApps() }
        installedButton.title = showInstalled ? "Running Apps" : "Installed Apps…"
        searchField.placeholderString = showInstalled ? "Search installed apps…" : "Search running apps…"
        refreshFiltered()
    }

    @objc private func appRowClicked() {
        let i = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard filtered.indices.contains(i) else { return }
        let entry = filtered[i]
        let title = titleMatchField.stringValue.trimmingCharacters(in: .whitespaces)
        onSelect?(.app(bundleID: entry.bundleID, titleMatch: title.isEmpty ? nil : title))
    }

    @objc private func setURLTapped() {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let host = hosts.indices.contains(hostControl.selectedSegment) ? hosts[hostControl.selectedSegment] : .builtin
        onSelect?(.web(url: url, host: host))
    }

    /// A host the user picked earlier may no longer be installed; fall back to the
    /// built-in window rather than showing nothing selected.
    private func select(host: WebHost) {
        hostControl.selectedSegment = hosts.firstIndex(of: host) ?? hosts.firstIndex(of: .builtin) ?? 0
    }

    static func availableHosts() -> [WebHost] {
        var hosts: [WebHost] = []
        for kind in BrowserWindow.Kind.allCases where BrowserWindow.isInstalled(kind) { hosts.append(kind.host) }
        if ChromeApp.resolve(preferred: nil) != nil { hosts.append(.chromeApp) }
        hosts.append(.builtin)
        return hosts
    }

    @objc private func panelTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelect?(.panel(id: id))
    }

    @objc private func clearTapped() { onSelect?(nil) }
}

extension OccupantPicker: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let id = NSUserInterfaceItemIdentifier("appCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            let imageView = NSImageView()
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            cell.imageView = imageView
            cell.textField = textField
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.identifier = id
        }
        cell.imageView?.frame = CGRect(x: 4, y: 4, width: 20, height: 20)
        cell.imageView?.image = entry.icon
        cell.textField?.frame = CGRect(x: 30, y: 6, width: (tableColumn?.width ?? 260) - 34, height: 16)
        cell.textField?.stringValue = "\(entry.name)  ·  \(entry.bundleID)"
        cell.textField?.font = .systemFont(ofSize: 12)
        return cell
    }
}

extension OccupantPicker: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refreshFiltered() }
}
