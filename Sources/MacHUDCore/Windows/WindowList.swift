import AppKit

/// The window server's view of what is on screen, filtered down to the windows a
/// user would call a window.
enum WindowList {
    struct Entry {
        var number: Int
        var pid: pid_t
        var owner: String
        var title: String
        /// Cocoa screen coordinates (bottom-left origin).
        var frame: CGRect
    }

    /// System chrome that lives on layer 0 but is not a user window.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.WindowManager", "com.apple.Spotlight",
        "com.apple.screencaptureui", "com.apple.wallpaper.agent",
    ]
    static let minimumSize = CGSize(width: 60, height: 40)

    static func onScreen() -> [Entry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        var entries: [Entry] = []
        for info in raw {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  // Normal windows live on layer 0; our own floating panels do not.
                  info[kCGWindowLayer as String] as? Int == 0 || pid == getpid(),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= minimumSize.width, bounds.height >= minimumSize.height else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            if let bundleID, excludedBundleIDs.contains(bundleID) { continue }
            entries.append(Entry(number: number, pid: pid, owner: owner,
                                 title: info[kCGWindowName as String] as? String ?? "",
                                 frame: CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                               width: bounds.width, height: bounds.height)))
        }
        return entries
    }

    /// Frames (Cocoa coordinates) of the ordered-in windows of `pids` on any layer, largest
    /// first: where a sibling's floating panel is, parked ones included.
    static func frames(pids: Set<pid_t>) -> [CGRect] {
        guard !pids.isEmpty,
              let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryHeight = ScreenCoords.primaryHeight
        return raw.compactMap { info -> CGRect? in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  b.width >= minimumSize.width, b.height >= minimumSize.height,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01 else { return nil }
            return CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        }.sorted { $0.width * $0.height > $1.width * $1.height }
    }
}
