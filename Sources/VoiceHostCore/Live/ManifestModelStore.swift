import Combine
import Foundation
import VoiceKit

/// A VoiceKit model's files through its `ModelStore` (the Kokoro reply voice, a wake model):
/// pinned by size and SHA-256, each verified before it is installed, readiness marked only
/// after the whole set passes. `ReplySpeaker` picks Kokoro up for the next reply, and the wake
/// word listens, once the files are in place.
@MainActor
final class ManifestModelStore: VoiceModelProviding {
    var onChange: (() -> Void)?
    private let store: ModelStore
    private var observation: AnyCancellable?

    init(manifest: ModelManifest, directory: URL,
         downloader: ModelStore.Downloader? = nil) {
        store = downloader.map { ModelStore(manifest: manifest, directory: directory, downloader: $0) }
            ?? ModelStore(manifest: manifest, directory: directory)
        // `objectWillChange` fires before the change lands; report it once it has.
        observation = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.onChange?() } }
    }

    var status: VoiceModelStatus {
        VoiceModelStatus(installed: store.isReady, downloading: store.isDownloading,
                         progress: store.isReady ? 1 : store.progress, bytes: store.manifest.totalBytes,
                         error: store.error.isEmpty ? nil : store.error)
    }

    func download() {
        guard !store.isReady, !store.isDownloading else { return }
        store.download()
    }
}
