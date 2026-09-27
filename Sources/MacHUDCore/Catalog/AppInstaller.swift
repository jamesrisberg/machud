import AppKit
import CryptoKit
import HUDKit

/// Installs, updates and removes catalog apps.
///
/// Install: download the zip to a temp directory, check its size and sha256 against the
/// catalog, `ditto -x -k` it, check the bundle id, require Gatekeeper to accept it
/// (`spctl -a -vv -t install`: notarized), quit a running copy over its socket, then copy
/// it into the install directory (replacing the old copy, which goes to the Trash), rescan
/// and optionally launch. Uninstall: quit, then move the bundle to the Trash.
@MainActor
final class AppInstaller {
    enum Phase: Equatable {
        case queued
        case downloading(Double)
        case verifying, extracting, checking, quitting, installing, removing
        case done(String)
        case failed(String)

        var isBusy: Bool {
            switch self { case .done, .failed: return false; default: return true }
        }

        var text: String {
            switch self {
            case .queued: return "Waiting…"
            case .downloading(let f): return f > 0 ? "Downloading \(Int(f * 100))%" : "Downloading…"
            case .verifying: return "Verifying…"
            case .extracting: return "Unpacking…"
            case .checking: return "Checking Gatekeeper…"
            case .quitting: return "Quitting…"
            case .installing: return "Installing…"
            case .removing: return "Moving to Trash…"
            case .done(let what): return what
            case .failed(let why): return why
            }
        }

        var json: [String: Any] {
            switch self {
            case .downloading(let f): return ["phase": "downloading", "progress": f]
            case .done(let what): return ["phase": "done", "result": what]
            case .failed(let why): return ["phase": "failed", "error": why]
            default: return ["phase": "\(self)", "text": text]
            }
        }
    }

    struct InstallError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// What the installer needs from the system; replaced in tests.
    struct Hooks {
        /// Returns nil when Gatekeeper accepts the app, else why not. Runs off the main thread.
        var gatekeeper: (URL) -> String? = AppInstaller.spctl
        /// Whether the bundle at this URL (with this bundle id) is running. Another copy of
        /// the same app (a dev build) does not count.
        var isRunning: (String, URL) -> Bool = { id, url in !AppInstaller.running(id, at: url).isEmpty }
        /// Asks the copy at this URL to quit (over its socket); the completion runs once asked.
        var quit: (String, URL, @escaping () -> Void) -> Void = { id, url, done in
            AppInstaller.running(id, at: url).forEach { $0.terminate() }
            done()
        }
        /// Moves a bundle to the Trash. Runs off the main thread.
        var trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        var rescan: () -> Void = {}
        /// Launches the app with this bundle id (after the rescan).
        var launch: (String) -> Void = { _ in }
    }

    var hooks = Hooks()
    /// The configured install directory, if any.
    var configuredDirectory: () -> URL? = { nil }
    /// How long a quit may take before the install gives up.
    var quitTimeout: TimeInterval = 10
    private(set) var phases: [String: Phase] = [:]
    var onChange: ((String) -> Void)?
    private let work = DispatchQueue(label: "machud.installer", qos: .userInitiated)

    /// `MACHUD_INSTALL_SKIP_GATEKEEPER=1` skips the Gatekeeper check. Test-only: it lets a
    /// dev-signed build install; never set it for normal use.
    static var skipGatekeeper: Bool { Env.value("INSTALL_SKIP_GATEKEEPER") == "1" }

    func phase(_ id: String) -> Phase? { phases[id] }

    /// Running instances of `bundleID` launched from `url`.
    nonisolated static func running(_ bundleID: String, at url: URL) -> [NSRunningApplication] {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }
    func isBusy(_ id: String) -> Bool { phases[id]?.isBusy ?? false }

    private func set(_ id: String, _ phase: Phase) {
        phases[id] = phase
        onChange?(id)
    }

    // MARK: - Where

    /// The configured directory, else /Applications when writable, else ~/Applications.
    func destinationDirectory() throws -> URL {
        let fm = FileManager.default
        if let dir = configuredDirectory() {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if fm.isWritableFile(atPath: "/Applications") { return URL(fileURLWithPath: "/Applications", isDirectory: true) }
        let home = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// Directories whose bundles MacHUD may replace or remove: /Applications,
    /// ~/Applications and the configured install directory. A dev build elsewhere is
    /// never touched.
    var managedDirectories: [URL] {
        var dirs = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        if let dir = configuredDirectory() { dirs.insert(dir, at: 0) }
        return dirs
    }

    func isManaged(_ bundleURL: URL) -> Bool {
        let parent = bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        return managedDirectories.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == parent }
    }

    // MARK: - Install

    /// Installs `entry` (or updates `existing`, the copy found installed). `completion`
    /// gets the installed bundle.
    func install(_ entry: CatalogEntry, download: URL?, existing: InstalledCopy?, launch: Bool,
                 completion: @escaping (Result<URL, InstallError>) -> Void) {
        let id = entry.id
        let fail = { [weak self] (why: String) in
            self?.set(id, .failed(why))
            completion(.failure(InstallError(why)))
        }
        guard !isBusy(id) else { completion(.failure(InstallError("\(entry.name) is already being installed"))); return }
        guard !entry.isUmbrella else {
            fail("MacHUD does not update itself; download \(entry.version) from its release page"); return
        }
        guard let download else { fail("\(entry.name) has no download in the catalog"); return }
        guard let sha = entry.sha256?.lowercased(), sha.count == 64 else { fail("\(entry.name) has no sha256 in the catalog"); return }
        let destination: URL
        do { destination = try destinationDirectory() } catch { fail("no install directory: \(error.localizedDescription)"); return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("machud-install-\(UUID().uuidString)", isDirectory: true)
        let cleanup = { try? FileManager.default.removeItem(at: temp) }
        do { try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true) } catch { fail("\(error)"); return }
        set(id, .downloading(0))

        fetch(download, to: temp.appendingPathComponent("download.zip"), id: id) { [self] result in
            let zip: URL
            switch result {
            case .failure(let error): cleanup(); fail("download failed: \(error.description)"); return
            case .success(let url): zip = url
            }
            set(id, .verifying)
            let gatekeeper = hooks.gatekeeper
            let skip = Self.skipGatekeeper
            work.async {
                let prepared = Result<URL, Error> {
                    try Self.verify(zip, size: entry.size, sha256: sha)
                    Self.onMain { self.set(id, .extracting) }
                    let app = try Self.extract(zip, into: temp.appendingPathComponent("x", isDirectory: true))
                    let copy = InstalledCopy.read(app)
                    if entry.id.contains("."), let bundleID = copy?.bundleID, bundleID != entry.id {
                        throw InstallError("\(app.lastPathComponent) is \(bundleID), not \(entry.id)")
                    }
                    if !skip {
                        Self.onMain { self.set(id, .checking) }
                        if let why = gatekeeper(app) {
                            throw InstallError("Gatekeeper rejected \(app.lastPathComponent) (not notarized?): \(why)")
                        }
                    } else {
                        NSLog("MacHUD: MACHUD_INSTALL_SKIP_GATEKEEPER=1, not checking %@ (test only)", app.path)
                    }
                    return app
                }
                Self.onMain {
                    switch prepared {
                    case .failure(let error): cleanup(); fail("\(error)")
                    case .success(let app):
                        let bundleID = InstalledCopy.read(app)?.bundleID ?? entry.id
                        let target = existing.map(\.bundleURL).flatMap { self.isManaged($0) ? $0 : nil }
                            ?? destination.appendingPathComponent(app.lastPathComponent, isDirectory: true)
                        // Only the copy being replaced is quit; nothing to quit for a fresh install.
                        self.quitIfRunning(bundleID, at: target, id: id) { quitError in
                            if let quitError { cleanup(); fail(quitError); return }
                            self.set(id, .installing)
                            let trash = self.hooks.trash
                            self.work.async {
                                let placed = Result<URL, Error> { try Self.place(app, at: target, trash: trash) }
                                cleanup()
                                Self.onMain {
                                    switch placed {
                                    case .failure(let error): fail("\(error)")
                                    case .success(let url):
                                        self.hooks.rescan()
                                        if launch { self.hooks.launch(bundleID) }
                                        self.set(id, .done(existing == nil ? "Installed \(entry.version)" : "Updated to \(entry.version)"))
                                        completion(.success(url))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Quits `entry`'s installed copy and moves it to the Trash.
    func uninstall(_ entry: CatalogEntry, installed: InstalledCopy?, completion: @escaping (Result<URL, InstallError>) -> Void) {
        let id = entry.id
        let fail = { [weak self] (why: String) in
            self?.set(id, .failed(why))
            completion(.failure(InstallError(why)))
        }
        guard !isBusy(id) else { completion(.failure(InstallError("\(entry.name) is busy"))); return }
        guard !entry.isUmbrella else { fail("MacHUD cannot remove itself"); return }
        guard let installed else { fail("\(entry.name) is not installed"); return }
        guard isManaged(installed.bundleURL) else {
            fail("\(installed.bundleURL.path) is not in an Applications folder; remove it yourself"); return
        }
        quitIfRunning(installed.bundleID ?? id, at: installed.bundleURL, id: id) { [self] quitError in
            if let quitError { fail(quitError); return }
            set(id, .removing)
            let trash = hooks.trash
            work.async {
                let result = Result<URL, Error> {
                    do { try trash(installed.bundleURL) } catch { throw InstallError("could not move to Trash: \(error.localizedDescription)") }
                    return installed.bundleURL
                }
                Self.onMain {
                    self.hooks.rescan()
                    switch result {
                    case .failure(let error): fail("\(error)")
                    case .success(let url):
                        self.set(id, .done("Removed"))
                        completion(.success(url))
                    }
                }
            }
        }
    }

    // MARK: - Steps

    private func quitIfRunning(_ bundleID: String, at url: URL, id: String, completion: @escaping (String?) -> Void) {
        guard hooks.isRunning(bundleID, url) else { completion(nil); return }
        set(id, .quitting)
        let deadline = Date().addingTimeInterval(quitTimeout)
        hooks.quit(bundleID, url) { [self] in
            Self.onMain { self.pollQuit(bundleID, at: url, deadline: deadline, completion: completion) }
        }
    }

    private func pollQuit(_ bundleID: String, at url: URL, deadline: Date, completion: @escaping (String?) -> Void) {
        if !hooks.isRunning(bundleID, url) { completion(nil); return }
        if Date() > deadline { completion("\(url.lastPathComponent) did not quit; quit it and try again"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { self.pollQuit(bundleID, at: url, deadline: deadline, completion: completion) }
        }
    }

    private var observations: [String: NSKeyValueObservation] = [:]

    /// Downloads `url` to `file`, reporting progress. A file URL is copied.
    private func fetch(_ url: URL, to file: URL, id: String, completion: @escaping (Result<URL, InstallError>) -> Void) {
        if url.isFileURL {
            work.async {
                var r: Result<URL, InstallError> = .success(file)
                do { try FileManager.default.copyItem(at: url, to: file) } catch { r = .failure(InstallError(error.localizedDescription)) }
                Self.onMain { completion(r) }
            }
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            var r: Result<URL, InstallError>
            if let error { r = .failure(InstallError(error.localizedDescription)) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 { r = .failure(InstallError("HTTP \(http.statusCode)")) }
            else if let location {
                do { try FileManager.default.moveItem(at: location, to: file); r = .success(file) }
                catch { r = .failure(InstallError(error.localizedDescription)) }
            } else { r = .failure(InstallError("no data")) }
            let box = UncheckedBox(r)
            Self.onMain {
                self.observations[id] = nil
                completion(box.value)
            }
        }
        observations[id] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let f = progress.fractionCompleted
            Self.onMain { if case .downloading = self?.phases[id] { self?.set(id, .downloading(f)) } }
        }
        task.resume()
    }

    nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        let box = UncheckedBox(work)
        DispatchQueue.main.async { MainActor.assumeIsolated { box.value() } }
    }

    /// Size (when the catalog gives one) and sha256 must both match.
    nonisolated static func verify(_ zip: URL, size: Int?, sha256: String) throws {
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: zip.path))?[.size] as? Int ?? -1
        if let size, size != actualSize {
            throw InstallError("size mismatch: catalog says \(size) bytes, downloaded \(actualSize)")
        }
        let digest = try sha256Hex(zip)
        guard digest == sha256.lowercased() else {
            throw InstallError("sha256 mismatch: catalog says \(sha256.lowercased()), downloaded \(digest)")
        }
    }

    nonisolated static func sha256Hex(_ file: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw InstallError("cannot read \(file.path)") }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `ditto -x -k`, then the one `.app` at the top of the archive.
    nonisolated static func extract(_ zip: URL, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (status, output) = run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard status == 0 else { throw InstallError("could not unzip: \(output)") }
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".app") }
        guard apps.count == 1 else {
            throw InstallError(apps.isEmpty ? "the zip has no .app at its top level" : "the zip has several apps: \(apps.joined(separator: ", "))")
        }
        return dir.appendingPathComponent(apps[0], isDirectory: true)
    }

    /// Copies `app` next to `target` then swaps it in; the old copy goes to the Trash.
    nonisolated static func place(_ app: URL, at target: URL, trash: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).installing", isDirectory: true)
        try? fm.removeItem(at: staging)
        let (status, output) = run("/usr/bin/ditto", [app.path, staging.path])
        guard status == 0 else { throw InstallError("could not copy into \(target.deletingLastPathComponent().path): \(output)") }
        if fm.fileExists(atPath: target.path) {
            do { try trash(target) } catch {
                try? fm.removeItem(at: staging)
                throw InstallError("could not move the old \(target.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }
        do { try fm.moveItem(at: staging, to: target) } catch {
            throw InstallError("could not install \(target.path): \(error.localizedDescription)")
        }
        return target
    }

    /// `spctl -a -vv -t install <app>`: nil when accepted, else its output.
    nonisolated static func spctl(_ app: URL) -> String? {
        let (status, output) = run("/usr/sbin/spctl", ["-a", "-vv", "-t", "install", app.path])
        guard status != 0 else { return nil }
        let text = output.replacingOccurrences(of: app.path + ": ", with: "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return text.isEmpty ? "spctl exited \(status)" : text.joined(separator: "; ")
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
