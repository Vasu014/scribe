import Foundation
import WhisperKit

/// Progress events for a first-launch model fetch (SPEC §4.2: "model
/// download on first launch with progress UI").
public enum ModelDownloadEvent: Sendable {
    /// Fraction 0…1 (monotonic within a run).
    case progress(Double)
    /// Fetch finished; the URL is the local model folder — pass its `.path`
    /// to `WhisperKitEngine(modelFolder:)`.
    case completed(URL)
    /// Fetch failed (network, storage, unknown variant).
    case failed(String)
}

/// Best-effort model-fetch plumbing over WhisperKit's model management.
/// Surface (name → progress stream → local path) is the stable contract for
/// the setup wizard (T8); internals track whatever the resolved WhisperKit
/// version offers. Resolved version 0.18.0 exposes
/// `WhisperKit.download(variant:downloadBase:useBackgroundSession:
/// progressCallback:)` returning the model folder URL, with progress via
/// Foundation.`Progress` — mapped onto `ModelDownloadEvent` here. If a future
/// version changes that API, only this file changes.
///
/// WhisperKit's Hub-backed fetch stores files under its own hub-cache layout
/// inside `modelRoot` (e.g. `models--argmaxinc--whisperkit-coreml/snapshots/
/// <hash>/openai_whisper-small.en`); the returned completion URL already
/// points at the variant folder inside that layout, and re-running a fetch
/// skips already-downloaded files, so `download` doubles as "ensure present".
public struct ModelDownloadManager: Sendable {
    /// `~/Library/Application Support/Scribe/models/` (SPEC §4.6 data home).
    public static let defaultModelRoot = URL(
        filePath: NSString(string: "~/Library/Application Support/Scribe/models")
            .expandingTildeInPath
    )

    private let modelRoot: URL

    public init(modelRoot: URL = ModelDownloadManager.defaultModelRoot) {
        self.modelRoot = modelRoot
    }

    /// Where a variant's files live under our root (informational — the
    /// hub-cache layout may add path components; use `isDownloaded(_:)` and
    /// the `download` completion URL instead of constructing paths).
    public func localFolder(forModelNamed name: String) -> URL {
        modelRoot.appending(path: name)
    }

    /// Best-effort presence check: looks for the exact variant folder and
    /// compiled Core ML model bundles. Heuristic —
    /// the authoritative check is attempting `WhisperKitEngine` load.
    public func isDownloaded(_ name: String) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: modelRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            // A variant folder holds compiled Core ML bundles (*.mlmodelc);
            // match a bundle whose parent folder is the named variant.
            if url.lastPathComponent.hasSuffix(".mlmodelc") {
                let parent = url.deletingLastPathComponent()
                if Self.folderName(parent.lastPathComponent, matchesVariant: name),
                   Self.hasWeights(url) {
                    return true
                }
            }
        }
        return false
    }

    /// WhisperKit's catalogue folders use `openai_whisper-<variant>` while
    /// converted/custom repositories may expose `<variant>` directly. Match
    /// only those two complete spellings: substring matching makes a shorter
    /// model name resolve whichever compressed/prefixed sibling happens to be
    /// enumerated first.
    public static func folderName(_ folderName: String, matchesVariant variant: String) -> Bool {
        folderName == variant || folderName == "openai_whisper-\(variant)"
    }

    /// A `.mlmodelc` bundle is only usable once its WEIGHTS are present.
    /// An interrupted fetch leaves the directory tree and the small metadata
    /// files behind, so "the folder exists and contains .mlmodelc bundles" is
    /// satisfied by a download that never finished: a real case left 9.7 MB of
    /// an 889 MB model on disk, reported "Downloaded · applies next session",
    /// and then failed to load at session start — producing an empty
    /// transcript with no error, the failure this check exists to prevent.
    private static func hasWeights(_ bundle: URL) -> Bool {
        let weights = bundle.appending(path: "weights")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: weights, includingPropertiesForKeys: [.fileSizeKey]
        ), !contents.isEmpty else { return false }
        // Any non-trivial weight blob is enough; a stub/partial file is not.
        return contents.contains { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 1_000_000
        }
    }

    /// Fetches a named model variant, reporting 0–1 progress. The stream
    /// finishes after `.completed` or `.failed`. Cancellation (stream
    /// termination) cancels the fetch task.
    /// Hugging Face repo a variant is fetched from. Defaults to Argmax's
    /// WhisperKit catalogue; a fine-tune (e.g. the Hinglish model) lives in
    /// someone else's repo, so this has to be per-variant rather than a
    /// constant.
    public static let defaultRepo = "argmaxinc/whisperkit-coreml"

    public func download(
        _ name: String,
        repo: String = ModelDownloadManager.defaultRepo
    ) -> AsyncStream<ModelDownloadEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let folder = try await WhisperKit.download(
                        variant: name,
                        downloadBase: self.modelRoot,
                        useBackgroundSession: false,
                        from: repo,
                        progressCallback: { progress in
                            continuation.yield(.progress(max(0, min(1, progress.fractionCompleted))))
                        }
                    )
                    continuation.yield(.completed(folder))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
