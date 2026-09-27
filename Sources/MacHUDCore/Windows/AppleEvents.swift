import AppKit

enum AppleEvents {
    /// The event a Dock click sends. Apps launched in the background sometimes come
    /// up without a window or even a menu bar until they get one.
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAEMiscStandards),
                                           eventID: AEEventID(kAEActivate),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do {
            try event.sendEvent(options: [.noReply], timeout: 2)
            return true
        } catch {
            NSLog("MacHUD: activate event to pid %d failed: %@", pid, "\(error)")
            return false
        }
    }
}
