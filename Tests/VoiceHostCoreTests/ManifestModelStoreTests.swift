import CryptoKit
import VoiceKit
import XCTest
@testable import VoiceHostCore

/// The live model store over VoiceKit's `ModelStore`, with a tiny `file://` manifest: nothing is
/// downloaded from the network.
@MainActor
final class ManifestModelStoreTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro-store-\(UUID().uuidString)")
        source = root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("voices"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ files: [String: Data], corrupt: String? = nil) throws -> ModelManifest {
        let artifacts = try files.keys.sorted().map { path -> ModelArtifact in
            let data = files[path]!
            try data.write(to: source.appendingPathComponent(path))
            let hash = SHA256.hash(data: path == corrupt ? Data("other".utf8) : data)
                .map { String(format: "%02x", $0) }.joined()
            return ModelArtifact(path: path, size: Int64(data.count), sha256: hash)
        }
        return ModelManifest(id: "Test", displayName: "Test model", baseURL: source, artifacts: artifacts,
                             licence: "test", redistributable: false)
    }

    private func waitUntil(_ store: ManifestModelStore, _ done: @escaping (VoiceModelStatus) -> Bool) async {
        let reached = expectation(description: "status")
        reached.assertForOverFulfill = false
        store.onChange = { if done(store.status) { reached.fulfill() } }
        if done(store.status) { reached.fulfill() }
        await fulfillment(of: [reached], timeout: 5)
    }

    func testDownloadVerifiesAndInstalls() async throws {
        let manifest = try manifest(["config.json": Data("{}".utf8), "voices/af_heart.npy": Data(repeating: 7, count: 64)])
        let store = ManifestModelStore(manifest: manifest, directory: root.appendingPathComponent("installed"))
        XCTAssertEqual(store.status, VoiceModelStatus(installed: false, downloading: false, progress: 0, bytes: 66))
        store.download()
        XCTAssertTrue(store.status.downloading)
        await waitUntil(store) { $0.installed }
        XCTAssertEqual(store.status, VoiceModelStatus(installed: true, downloading: false, progress: 1, bytes: 66))
        XCTAssertTrue(ModelStore.isInstalled(manifest, in: root.appendingPathComponent("installed")))
    }

    func testAFileThatFailsVerificationIsNotInstalled() async throws {
        let manifest = try manifest(["config.json": Data("{}".utf8)], corrupt: "config.json")
        let store = ManifestModelStore(manifest: manifest, directory: root.appendingPathComponent("installed"))
        store.download()
        await waitUntil(store) { !$0.downloading && $0.error != nil }
        XCTAssertFalse(store.status.installed)
        XCTAssertEqual(store.status.error, "The downloaded config.json failed verification. Try again.")
    }
}
