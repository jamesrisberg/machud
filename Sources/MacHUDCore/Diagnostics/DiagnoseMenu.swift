import AppKit

/// The status menu's Save Diagnostics item. It runs the same `DiagnoseService` path as the
/// `diagnose` verb, then says what happened, as captures do: a toast with how many things look
/// wrong, and the file selected in Finder. Only the menu item reveals the file; the verb never
/// does, so a script (or an isolated test instance) is not pulled into Finder.
@MainActor
final class DiagnoseMenu: NSObject {
    static let title = "Save Diagnostics"

    private let service: DiagnoseService
    /// Shows a toast: the headline and its detail line.
    var toast: (String, String?) -> Void = { Toast.show($0, detail: $1, seconds: 4) }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    init(service: DiagnoseService) {
        self.service = service
        super.init()
    }

    /// A fresh item for each menu build; AppKit holds its target weakly, so the app keeps this object.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.title, action: #selector(save), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func save() {
        service.run { [weak self] reply in self?.report(reply) }
    }

    /// The toast for a `diagnose` reply: the headline and the file's name (or the reason it failed).
    static func message(for reply: [String: Any]) -> (headline: String, detail: String?) {
        guard reply["ok"] as? Bool == true else {
            return ("Could not save diagnostics", reply["error"] as? String ?? "no reason given")
        }
        let count = (reply["anomalies"] as? [String])?.count ?? 0
        let file = (reply["path"] as? String).map { ($0 as NSString).lastPathComponent }
        switch count {
        case 0: return ("Diagnostics saved. Nothing looks wrong.", file)
        case 1: return ("Diagnostics saved. 1 thing looks wrong.", file)
        default: return ("Diagnostics saved. \(count) things look wrong.", file)
        }
    }

    private func report(_ reply: [String: Any]) {
        let message = Self.message(for: reply)
        toast(message.headline, message.detail)
        if reply["ok"] as? Bool == true, let path = reply["path"] as? String { reveal(URL(fileURLWithPath: path)) }
    }
}
