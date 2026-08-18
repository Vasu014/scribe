import Foundation
import TranscribeKit
import os

/// Production `Transcriber` wiring (T8): ONE shared `WhisperKitEngine` model
/// instance (SPEC §4.2 shared-model rule — two model instances ≈ 1 GB RAM +
/// GPU contention are explicitly rejected), built LAZILY at the first
/// session start. Model load takes seconds; building at launch would delay
/// the menu bar for a download nobody asked for yet.
///
/// ## Why per-session `WhisperKitTranscriber` instances
/// `WhisperKitTranscriber` caches one `ChannelWorker` per channel for its
/// whole lifetime, with the stream's emission sink baked in (documented
/// assumption on that type). Reusing a single instance across sessions would
/// route session 2's segments into session 1's finished stream. So: the
/// MODEL (expensive part) is loaded once per app lifetime and shared, while
/// a fresh `WhisperKitTranscriber` — whose single `GatedEngine` serializes
/// both channels onto that shared model — is created per session and shared
/// by both of that session's channel streams (the SPEC §4.2 one-in-flight
/// guarantee is exactly what the per-session gate preserves).
///
/// ## Model changes
/// Engines are cached by variant name; changing the persisted model
/// (Settings → Whisper Model) applies at the next session start (SPEC §4.2),
/// never mid-session — a live session keeps using its session-scoped
/// transcriber.
///
/// ## Missing model fallback
/// If the model folder is missing at first session start (download skipped
/// or deleted — the setup wizard normally prevents this), the session falls
/// back to `UnimplementedTranscriber`: meetings still record, fragments
/// still persist, and fusion reports the empty transcript with a clear
/// error. Logged loudly; retried at the next session start in case the model
/// appeared meanwhile.
final class LazyWhisperKitTranscriber: Transcriber, @unchecked Sendable {

    /// All mutable state lives in this actor; `transcribe` is a thin,
    /// lock-free entry that awaits it.
    private let resolver = Resolver()

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task {
                await self.resolver.beginStream()
                if let impl = await self.resolver.sessionTranscriber() {
                    for await segment in impl.transcribe(stream: stream) {
                        continuation.yield(segment)
                    }
                } else {
                    // Model unavailable: consume via the placeholder so the
                    // pipeline still drains (see class docs).
                    let fallback = UnimplementedTranscriber()
                    for await _ in fallback.transcribe(stream: stream) {}
                    continuation.finish()
                }
                await self.resolver.endStream()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Resolution actor

/// Engine + session-transcriber lifecycle. Actor confinement gives the
/// single-flight behavior for free across the two concurrent
/// `transcribe(stream:)` calls a session start produces (one per channel).
private actor Resolver {

    private static let logger = Logger(subsystem: "com.example.scribe", category: "transcriber")

    // Model cache — one engine per app lifetime, keyed by variant.
    private var engineVariant: String?
    private var engine: (any WhisperEngine)?
    private var engineBuild: Task<(variant: String, engine: any WhisperEngine)?, Never>?
    private var engineBuildVariant: String?

    // Session scope — one transcriber per session, shared by both channels.
    private var sessionTranscriber: (any Transcriber)?
    private var sessionBuild: Task<(any Transcriber)?, Never>?
    private var liveStreams = 0

    // MARK: Session scoping

    func beginStream() {
        liveStreams += 1
    }

    /// When the session's last channel stream ends, the session-scoped
    /// transcriber (and its channel workers) is released; the next session
    /// start builds a fresh one around the same shared model.
    func endStream() {
        liveStreams -= 1
        if liveStreams <= 0 {
            liveStreams = 0
            sessionTranscriber = nil
            sessionBuild = nil
        }
    }

    func sessionTranscriber() async -> (any Transcriber)? {
        if let sessionTranscriber {
            return sessionTranscriber
        }
        if let sessionBuild {
            return await sessionBuild.value // second channel, same session
        }
        let build = Task { await self.buildSessionTranscriber() }
        sessionBuild = build
        let impl = await build.value
        // Cache only if this session is still live: a build completing after
        // the streams ended must not leak into the next session.
        if liveStreams > 0 {
            sessionTranscriber = impl
        }
        return impl
    }

    private func buildSessionTranscriber() async -> (any Transcriber)? {
        guard let engine = await resolveEngine() else { return nil }
        return WhisperKitTranscriber(engine: engine)
    }

    // MARK: Model resolution

    private func resolveEngine() async -> (any WhisperEngine)? {
        let variant = SettingsKeys.whisperModelName

        // Fast path: cached engine matches the persisted variant.
        if engineVariant == variant, let engine {
            return engine
        }
        // Another build for this variant is already in flight (the sibling
        // channel's call) — never build the model twice.
        if let engineBuild, engineBuildVariant == variant {
            if let outcome = await engineBuild.value, outcome.variant == variant {
                return outcome.engine
            }
        }

        let build = Task { await Self.buildEngine(variant: variant) }
        engineBuild = build
        engineBuildVariant = variant
        let outcome = await build.value
        if engineBuildVariant == variant {
            engineBuild = nil
            engineBuildVariant = nil
        }
        if let outcome {
            engineVariant = outcome.variant
            engine = outcome.engine
        }
        return outcome?.engine
    }

    /// Nonisolated build (no actor state): locate the variant folder, then
    /// load. Returns `nil` (with a loud log) when the model is missing or
    /// failed to load — callers fall back to `UnimplementedTranscriber`.
    private static func buildEngine(variant: String) async -> (variant: String, engine: any WhisperEngine)? {
        guard let folder = locateModelFolder(variant: variant) else {
            logger.error("""
            Whisper model '\(variant, privacy: .public)' not found under the models root — \
            transcription is disabled this session (the setup wizard downloads it). \
            Retrying at the next session start.
            """)
            return nil
        }
        do {
            let engine = try await WhisperKitEngine(modelName: variant, modelFolder: folder.path())
            logger.info("WhisperKit engine loaded for '\(variant, privacy: .public)' (lazy, first session start).")
            return (variant, engine)
        } catch {
            logger.error("""
            WhisperKit engine failed to load for '\(variant, privacy: .public)': \
            \(String(describing: error), privacy: .public) — falling back to no \
            transcription this session.
            """)
            return nil
        }
    }

    /// Locates a downloaded variant's folder under
    /// `ModelDownloadManager.defaultModelRoot`, mirroring the heuristic
    /// `ModelDownloadManager.isDownloaded` uses: a compiled Core ML bundle
    /// (`*.mlmodelc`) whose parent folder is the named variant (the Hub
    /// cache nests it as `…/snapshots/<hash>/openai_whisper-<variant>/`).
    /// Returns the variant folder for `WhisperKitEngine(modelFolder:)`.
    private static func locateModelFolder(variant: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: ModelDownloadManager.defaultModelRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension == "mlmodelc" else { continue }
            let variantFolder = url.deletingLastPathComponent()
            if variantFolder.lastPathComponent.contains(variant) {
                return variantFolder
            }
        }
        return nil
    }
}
