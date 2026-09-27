import AppKit

/// Runs AppleScript off the main thread: an Apple event to a browser can take
/// seconds and the loadout engine polls on the main thread.
enum AppleScriptRunner {
    enum Failure: Error, Equatable {
        /// The user has not granted (or has refused) Automation access for this app.
        case automationDenied
        case timedOut
        case failed(String)

        var reason: String {
            switch self {
            case .automationDenied: return "automationDenied"
            case .timedOut: return "timed out"
            case .failed(let message): return message
            }
        }
    }

    /// Apple event error for "Not authorized to send Apple events to <app>".
    static let notAuthorized = -1743

    private static let queue = DispatchQueue(label: "com.jrisberg.machud.applescript")

    static func run(_ source: String, completion: @escaping (Result<String, Failure>) -> Void) {
        queue.async {
            let result = execute(source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocks the caller for at most `timeout` seconds; for the few places that
    /// need the value inline (capture reading a browser's front tab).
    static func run(_ source: String, timeout: TimeInterval) -> Result<String, Failure> {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            box.value = execute(source)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success, let value = box.value else {
            return .failure(.timedOut)
        }
        return value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<String, Failure>?
    }

    private static func execute(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("invalid script")) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == notAuthorized { return .failure(.automationDenied) }
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)"
            return .failure(.failed(message))
        }
        return .success(output.stringValue ?? "")
    }

    /// An AppleScript string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Bound an Apple event so a wedged browser cannot hold a script open.
    static func withTimeout(_ seconds: Int, _ body: String) -> String {
        "with timeout of \(seconds) seconds\n\(body)\nend timeout"
    }
}
