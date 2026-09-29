import Foundation
import SpeakFreeLib

/// Parakeet's download, as `ParakeetModelStore` uses it.
protocol ParakeetDownloading: Sendable {
    /// The model's files are complete in FluidAudio's cache.
    func isDownloaded(_ id: String) -> Bool
    /// The large files fetched directly with byte progress (no-op for a model without a plan).
    func prefetch(_ id: String, progress: @escaping @Sendable (_ written: Int64, _ total: Int64) -> Void) async throws
    /// The rest fetched and compiled for this Mac; progress 0...1.
    func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// SpeakFreeLib's `ParakeetModelManager`: FluidAudio's cache
/// (`~/Library/Application Support/FluidAudio/Models`), the folder SpeakFree uses too, so either
/// app's download serves both.
struct SpeakFreeParakeet: ParakeetDownloading, @unchecked Sendable {
    private var manager: ParakeetModelManager { .shared }

    func isDownloaded(_ id: String) -> Bool { manager.isModelDownloaded(id) }

    func prefetch(_ id: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await manager.prefetchLargeFiles(id, progress: progress)
    }

    func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await manager.ensureDownloaded(id, progress: progress)
    }
}

/// The Parakeet speech model dictation transcribes with, downloaded as SpeakFree downloads it:
/// the large files first with byte progress, then FluidAudio fetches the rest and compiles the
/// model for this Mac. Installed means either of SpeakFree's Parakeet models is complete on
/// disk, whichever app fetched it; a download fetches SpeakFree's default (English).
@MainActor
final class ParakeetModelStore: VoiceModelProviding {
    var onChange: (() -> Void)?
    /// SpeakFree's download of the English model is about this size before the direct fetch
    /// reports the real total.
    nonisolated static let estimatedBytes: Int64 = 600_000_000
    /// The share of the bar the direct fetch fills; compiling fills the rest.
    nonisolated static let prefetchShare = 0.92

    /// Models dictation can use, in the order it picks them; the first is the one downloaded.
    let models: [String]
    private let backend: ParakeetDownloading
    private var downloading = false
    private var progress = 0.0
    private var bytes = ParakeetModelStore.estimatedBytes
    private var error: String?

    init(backend: ParakeetDownloading = SpeakFreeParakeet(),
         models: [String] = SpeakFreeDictation.parakeetModels) {
        self.backend = backend
        self.models = models
    }

    /// The model dictation would use now, if any is installed.
    var installedModel: String? { models.first { backend.isDownloaded($0) } }

    /// Read from disk each time, so a download by SpeakFree shows here too.
    var status: VoiceModelStatus {
        let installed = installedModel
        return VoiceModelStatus(installed: installed != nil, downloading: downloading,
                                progress: installed != nil ? 1 : progress, bytes: bytes, error: error,
                                id: installed ?? models.first)
    }

    func download() {
        guard !downloading, installedModel == nil, let id = models.first else { return }
        downloading = true
        progress = 0
        error = nil
        onChange?()
        let backend = self.backend
        // Progress arrives on FluidAudio's and URLSession's queues.
        let report: @Sendable (Double, Int64?) -> Void = { [weak self] fraction, total in
            Task { @MainActor in self?.advance(to: fraction, total: total) }
        }
        Task { [weak self] in
            do {
                try await backend.prefetch(id) { written, total in
                    guard total > 0 else { return }
                    report(min(Double(written) / Double(total), 1) * Self.prefetchShare, total)
                }
                try await backend.install(id) { fraction in
                    let value = Self.prefetchShare + min(max(fraction, 0), 1) * (1 - Self.prefetchShare)
                    report(min(value, 0.99), nil)
                }
                self?.finish(error: nil)
            } catch {
                self?.finish(error: Self.message(for: error))
            }
        }
    }

    /// Progress only moves forward, and is reported in whole-percent steps.
    private func advance(to fraction: Double, total: Int64?) {
        guard downloading else { return }
        if let total, total != bytes { bytes = total }
        guard fraction >= progress + 0.01 else { return }
        progress = fraction
        onChange?()
    }

    private func finish(error: String?) {
        downloading = false
        self.error = error
        if error == nil { progress = 1 }
        onChange?()
    }

    static func message(for error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "The download was stopped." }
        if let url = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(url.code) {
            return "The download failed: check the internet connection and try again."
        }
        return "The download failed: \(error.localizedDescription)"
    }
}
