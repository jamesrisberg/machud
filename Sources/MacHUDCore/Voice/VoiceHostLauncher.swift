import Foundation

/// A running voice host process.
protocol VoiceHostChild: AnyObject {
    var pid: Int32 { get }
    /// Asks it to exit. Its `onExit` still fires.
    func terminate()
}

/// How the voice host is started: the one seam between the supervisor and the process
/// mechanism, so launching it another way (a separate bundled app) changes only a launcher.
@MainActor
protocol VoiceHostLaunching {
    /// Starts `executable`. `onExit` gets the exit status (or signal) on any thread.
    func launch(_ executable: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> VoiceHostChild
}

/// Launches the helper as MacHUD's child with Foundation `Process`: a child is covered by
/// MacHUD's privacy grants (Microphone, Accessibility), where a separately launched app would
/// need its own. Its stdin is a pipe MacHUD holds open (`MACHUD_VOICE_PARENT_PIPE=1`), so the
/// helper sees EOF and exits whenever MacHUD goes away, a crash included.
struct ChildProcessLauncher: VoiceHostLaunching {
    final class Child: VoiceHostChild {
        let process: Process
        private let parentPipe: Pipe
        private let grace: TimeInterval

        init(process: Process, parentPipe: Pipe, grace: TimeInterval) {
            self.process = process
            self.parentPipe = parentPipe
            self.grace = grace
        }

        var pid: Int32 { process.processIdentifier }

        /// Closes the parent pipe so the host shuts down on its own (stopping the brain and
        /// releasing the microphone), and sends SIGTERM only if it is still running `grace`
        /// seconds later.
        func terminate() {
            closeParentPipe()
            let process = self.process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                if process.isRunning { process.terminate() }
            }
        }

        /// The helper reads EOF, as when MacHUD dies.
        func closeParentPipe() { try? parentPipe.fileHandleForWriting.close() }
    }

    /// How long `terminate()` waits for the host to exit on end-of-file before SIGTERM.
    let grace: TimeInterval

    nonisolated init(grace: TimeInterval = 2) { self.grace = grace }

    func launch(_ executable: URL, environment: [String: String],
                onExit: @escaping @Sendable (Int32) -> Void) throws -> VoiceHostChild {
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = pipe
        process.terminationHandler = { onExit($0.terminationStatus) }
        try process.run()
        // Only the child reads; MacHUD keeps the write end and never writes.
        try? pipe.fileHandleForReading.close()
        return Child(process: process, parentPipe: pipe, grace: grace)
    }
}
