import XCTest
@testable import VoiceHostCore

/// The Parakeet speech model's status and download, with a fake in place of FluidAudio (no
/// network, nothing written).
@MainActor
final class ParakeetModelStoreTests: XCTestCase {
    private let english = "parakeet-tdt-0.6b-v2"
    private let multilingual = "parakeet-tdt-0.6b-v3"

    private func until(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    func testNotInstalledOffersSpeakFreesDefault() {
        let store = ParakeetModelStore(backend: FakeParakeet())
        XCTAssertEqual(store.status, VoiceModelStatus(installed: false, downloading: false, progress: 0,
                                                      bytes: ParakeetModelStore.estimatedBytes, id: english))
    }

    func testEitherModelCountsAsInstalledWhoeverDownloadedIt() {
        let backend = FakeParakeet()
        let store = ParakeetModelStore(backend: backend)
        backend.installed = [multilingual]   // SpeakFree fetched it, after the store was made.
        XCTAssertTrue(store.status.installed)
        XCTAssertEqual(store.status.id, multilingual)
        XCTAssertEqual(store.status.progress, 1)
        var changes = 0
        store.onChange = { changes += 1 }
        store.download()
        XCTAssertEqual(changes, 0, "installed: nothing to download")
        XCTAssertTrue(backend.prefetched.isEmpty)
    }

    func testDownloadReportsProgressThenInstalls() async {
        let backend = FakeParakeet()
        let store = ParakeetModelStore(backend: backend)
        var changes = 0
        store.onChange = { changes += 1 }
        store.download()
        XCTAssertTrue(store.status.downloading)
        store.download()   // Under way: continues.
        let installing = await until { backend.isInstalling }
        XCTAssertTrue(installing)
        XCTAssertEqual(backend.prefetched, [english])

        backend.reportBytes(250_000_000, of: 500_000_000)
        let halfway = await until { store.status.progress > 0.4 }
        XCTAssertTrue(halfway)
        XCTAssertEqual(store.status.progress, 0.46, accuracy: 0.001, "the direct fetch fills 92% of the bar")
        XCTAssertEqual(store.status.bytes, 500_000_000, "the real size once known")
        backend.reportBytes(500_000_000, of: 500_000_000)
        backend.reportInstall(0.5)
        let compiling = await until { store.status.progress > 0.95 }
        XCTAssertTrue(compiling)
        XCTAssertLessThan(store.status.progress, 1)
        backend.reportBytes(100, of: 500_000_000)   // Never backwards.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThan(store.status.progress, 0.95)

        backend.finish()
        let done = await until { !store.status.downloading }
        XCTAssertTrue(done)
        XCTAssertEqual(store.status, VoiceModelStatus(installed: true, downloading: false, progress: 1,
                                                      bytes: 500_000_000, id: english))
        XCTAssertEqual(backend.installs, [english])
        XCTAssertGreaterThanOrEqual(changes, 4)
    }

    func testAFailedDownloadSaysWhyAndCanBeRetried() async {
        let backend = FakeParakeet()
        backend.failure = URLError(.notConnectedToInternet)
        let store = ParakeetModelStore(backend: backend)
        store.download()
        _ = await until { backend.isInstalling }
        backend.finish()
        let failed = await until { !store.status.downloading }
        XCTAssertTrue(failed)
        XCTAssertFalse(store.status.installed)
        XCTAssertEqual(store.status.error, "The download failed: check the internet connection and try again.")
        backend.failure = nil
        store.download()
        XCTAssertNil(store.status.error)
        XCTAssertTrue(store.status.downloading)
        _ = await until { backend.isInstalling }
        backend.finish()
    }
}
