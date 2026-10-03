import Foundation

/// Files only the user may read (the conversation, the take journal): written whole to a new
/// file created with mode 0600, then renamed over the old one, so neither a partial file nor one
/// with the default permissions is ever at the path.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw lastError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var isOpen = true
        do {
            // The umask can only narrow the mode `open` was given; this sets it exactly.
            guard fchmod(descriptor, 0o600) == 0 else { throw lastError() }
            try handle.write(contentsOf: data)
            isOpen = false
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw lastError() }
        } catch {
            if isOpen { try? handle.close() }
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
