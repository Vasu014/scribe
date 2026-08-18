import Foundation
import WhisperKit

/// One hypothesis line from a Whisper decode of a single VAD window.
/// Offsets are in seconds RELATIVE to the window buffer (SPEC §4.2: the
/// `Transcriber` layer converts them to session offsets).
public struct WhisperHypothesis: Sendable, Equatable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Narrow seam over WhisperKit so the rest of the module — and every test —
/// never imports WhisperKit directly (SPEC §4.2). Inputs are 16 kHz mono
/// Float32 PCM (SPEC §4.1 format contract from CaptureKit).
public protocol WhisperEngine: Sendable {
    /// Batch-transcribes one VAD window. Returns the hypothesis lines for
    /// that buffer (possibly empty when nothing intelligible was found).
    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis]
}

/// `WhisperEngine` backed by ONE `WhisperKit` model instance (SPEC §4.2
/// shared-model rule: two model instances ≈ 1 GB RAM + GPU contention are
/// explicitly rejected).
///
/// Being an actor does NOT by itself make concurrent `transcribeBuffer`
/// calls exclusive — actors are reentrant across suspension points, and
/// `whisper.transcribe` suspends. `WhisperKitTranscriber` therefore routes
/// every engine call through its `GatedEngine` (async semaphore, permit 1)
/// before it reaches this type. The actor here just keeps the non-Sendable
/// `WhisperKit` object confined.
public actor WhisperKitEngine: WhisperEngine {
    private let whisper: WhisperKit

    /// - Parameters:
    ///   - modelName: WhisperKit variant, e.g. `small.en` (user setting, SPEC §4.2).
    ///   - modelFolder: Local folder the model was fetched into
    ///     (`ModelDownloadManager.download` completion URL). `nil` lets
    ///     WhisperKit resolve its default search paths.
    public init(modelName: String = "small.en", modelFolder: String? = nil) async throws {
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            // Never download implicitly: network fetches happen only through
            // ModelDownloadManager (first-launch setup flow, SPEC §4.2), and a
            // missing model must surface as a load error, not a silent fetch.
            download: false,
            useBackgroundDownloadSession: false
        )
        self.whisper = try await WhisperKit(config)
    }

    public func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        guard !samples.isEmpty else { return [] }
        // In-memory batch API (0.18 single-buffer form of the
        // `transcribe(audioSamples:)`-style entry point; `segmentCallback: nil`
        // disambiguates the overload that returns the sorted result array).
        // SPEC §4.2 no-temp-audio rule: this path is pure in-memory — the only
        // file-based entry points in WhisperKit are the `audioPath(s:)`
        // overloads, which we never call. No cache/temp-write options exist
        // on this API; there is nothing left to disable.
        let results = try await whisper.transcribe(audioArray: samples, segmentCallback: nil)
        guard let result = results.first else { return [] }
        return result.segments.map { segment in
            WhisperHypothesis(
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end)
            )
        }
    }
}
