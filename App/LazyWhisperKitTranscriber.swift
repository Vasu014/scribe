import AppKit
import Foundation
import TranscribeKit
import os

/// Production `Transcriber` wiring (T8): ONE shared `WhisperKitEngine` model
/// instance (SPEC §4.2 shared-model rule — two model instances ≈ 1 GB RAM +
/// GPU contention are explicitly rejected), built LAZILY at the first
/// session start. Model load takes seconds; building at launch would delay
/// the menu bar for a download nobody asked for yet.
///
/// ## Why a fresh `WhisperKitTranscriber` per STREAM
/// `WhisperKitTranscriber` caches one `ChannelWorker` per channel for its
/// whole lifetime, with the first caller's emission sink baked in
/// (documented assumption on that type). An instance that outlives the
/// streams it was built for therefore routes a later stream's segments into
/// an earlier, already-finished continuation — the segments vanish — or
/// decodes the earlier stream's backlog into the later transcript at the
/// earlier session's offsets.
///
/// Scoping that instance to a SESSION cannot be enforced from here, and the
/// attempt to do so was itself the defect: this type is handed a bare
/// `AsyncStream` per channel and is never told where a session begins or
/// ends, so a session that ends ABNORMALLY never released its transcriber.
/// Concretely — stop a meeting while the model is still loading, and
/// `SessionCoordinator.stop()`'s bounded transcript drain (the T10 hang fix)
/// times out and abandons its consumers; those consumers are parked in
/// `await build.value`, which ignores the awaiting task's cancellation, so
/// the session-scoped cache stayed populated and the NEXT session was handed
/// the stalled session's transcriber and its channel workers.
///
/// So the scope is the STREAM — the only lifetime this type actually
/// observes. Every `transcribe(stream:)` call builds its own
/// `WhisperKitTranscriber`, with its own `ChannelWorker`, VAD window state
/// and `SegmentIdCache`, and drops it when that stream ends, normally or by
/// cancellation. Nothing crosses a session boundary except the model, and no
/// bookkeeping has to be correct for that to hold.
///
/// ## One inference in flight (SPEC §4.2)
/// `WhisperKitTranscriber` gates its own engine calls, but that gate is
/// per-instance and there is now one instance per stream, so the
/// cross-channel guarantee moves to where the sharing actually is:
/// `SharedInferenceGate` wraps the shared engine ONCE, for the app's
/// lifetime. Both of a session's channels — and any stream still unwinding
/// from a timed-out session — decode through that single permit, so there is
/// never more than one inference in flight on the one model.
///
/// ## Model changes
/// Engines are cached by variant name; changing the persisted model
/// (Settings → Whisper Model) applies at the next session start (SPEC §4.2),
/// never mid-session — a live stream keeps the engine it resolved.
///
/// ## Missing model fallback
/// If the model folder is missing at session start (download skipped or
/// deleted, or the user picked a variant they have not downloaded), the
/// session falls back to `UnimplementedTranscriber`: meetings still record,
/// fragments still persist, and fusion reports the empty transcript with a
/// clear error. This is NOT silent any more — it was, and it cost a whole
/// meeting with nothing on screen: `onModelUnavailable` fires, and with
/// nothing wired the user gets a warning naming the variant and a route to
/// Settings, where the model can be downloaded. Resolution is retried at the
/// next session start in case the model appeared meanwhile.
final class LazyWhisperKitTranscriber: Transcriber, @unchecked Sendable {

    /// Composition-root hook (`ScribeApp`): called on the main actor when a
    /// session starts and no usable model can be resolved, with the variant
    /// name. Wire it to own the presentation (a menu-bar notice, the setup
    /// wizard, …); when nothing is wired, `presentMissingModelNotice`
    /// warns and offers Settings, because "record an hour, transcribe
    /// nothing, log it" is not an acceptable default.
    @MainActor
    static var onModelUnavailable: ((String) -> Void)?

    /// Whether the persisted variant is present on disk — the cheap check a
    /// start-flow guard can run BEFORE a meeting begins (the TCC guards in
    /// `MenuBarController`/`ScratchpadPanelController`/`HistoryWindowController`
    /// are the model to follow). `false` means this launch would record a
    /// meeting with no transcript.
    static var selectedModelIsDownloaded: Bool {
        ModelDownloadManager().isDownloaded(SettingsKeys.whisperModelName)
    }

    /// All mutable state lives in this actor; `transcribe` is a thin,
    /// lock-free entry that awaits it.
    private let resolver = Resolver()

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task {
                // One transcriber for THIS stream only (see class docs). It
                // is released with this task, so a stream abandoned by a
                // timed-out drain takes its channel worker with it.
                if let impl = await self.resolver.makeStreamTranscriber() {
                    for await segment in impl.transcribe(stream: stream) {
                        continuation.yield(segment)
                    }
                } else {
                    // Model unavailable: consume via the placeholder so the
                    // pipeline still drains (see class docs).
                    let fallback = UnimplementedTranscriber()
                    for await _ in fallback.transcribe(stream: stream) {}
                }
                // EVERY path finishes. A continuation that is merely dropped
                // does NOT end its stream — it is owned by the stream's own
                // storage — so the missing `finish()` on the model-loaded
                // path left `SessionCoordinator.stop()`'s pipeline drain
                // waiting forever: the session never reached `processing`,
                // Stop went dead and the elapsed readout froze at 00:00
                // (T10 dogfood bug). The model-MISSING path did finish,
                // which is why stopping worked right up until the model
                // actually loaded.
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Missing-model notice

    /// Default presentation for `onModelUnavailable`. Modal by intent: the
    /// user is starting a meeting that will produce no transcript, and every
    /// other signal this failure had (an OSLog line) has already proved
    /// invisible. All the app's timers run in `.common` run-loop modes, so
    /// the recording UI keeps ticking behind the alert, and capture itself
    /// runs off the main thread.
    @MainActor
    fileprivate static func presentMissingModelNotice(variant: String) {
        if let hook = onModelUnavailable {
            hook(variant)
            return
        }
        // Both channels can fail their resolution at once, and a stream that
        // unwinds late can fail again; one warning per occasion is enough.
        guard !noticeIsVisible else { return }
        noticeIsVisible = true
        defer { noticeIsVisible = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This meeting won’t be transcribed"
        alert.informativeText = """
        The speech model “\(variant)” isn’t downloaded, so Scribe is recording your \
        notes but cannot produce a transcript of what is said.

        Open Settings → Whisper Model to download it. Transcription resumes at the \
        next meeting.
        """
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Continue Without Transcription")
        // Accessory app (LSUIElement): without this the alert opens behind
        // whatever the user is actually looking at.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.current?.show()
        }
    }

    /// Guards against stacking one alert per channel stream.
    @MainActor
    private static var noticeIsVisible = false

    #if DEBUG
    /// TEST SEAM (dev tooling; sibling of
    /// `WhisperKitTranscriber.reviseForTesting`): replaces model resolution,
    /// so a harness can drive session boundaries — a stalled load, a
    /// timed-out drain, a back-to-back restart — without a 500 MB Core ML
    /// load and without speech audio. Never set on any app path.
    nonisolated(unsafe) static var engineFactoryForTesting: (@Sendable (String) async -> (any WhisperEngine)?)?
    #endif
}

// MARK: - App-wide inference gate

/// SPEC §4.2 "at most one inference in flight" enforced around the SHARED
/// MODEL rather than around a transcriber instance.
///
/// `TranscribeKit.GatedEngine` does the same job one level up, but it is
/// per-`WhisperKitTranscriber` and internal to that module, and this file
/// deliberately builds one transcriber per stream (see
/// `LazyWhisperKitTranscriber`'s docs). Wrapping the engine here — once, when
/// it is built — is what keeps the two channels of a session, and any stream
/// still unwinding from an abandoned one, off the model at the same time.
/// Copies of the struct share the same `gate` actor, so passing it to several
/// transcribers is exactly one permit.
private struct SharedInferenceGate: WhisperEngine {
    private let engine: any WhisperEngine
    private let gate = InferenceGate()

    init(engine: any WhisperEngine) {
        self.engine = engine
    }

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        await gate.acquire()
        do {
            let hypotheses = try await engine.transcribeBuffer(samples)
            await gate.release()
            return hypotheses
        } catch {
            // Release on failure too — `defer` cannot `await` an actor call,
            // so both exits release explicitly.
            await gate.release()
            throw error
        }
    }
}

/// One-permit async semaphore. `DispatchSemaphore` would block a cooperative
/// thread, and actor reentrancy means actor isolation alone does not survive
/// the `await` inside a decode.
private actor InferenceGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Resolution actor

/// Model lifecycle. Actor confinement gives single-flight loading for free
/// across the two concurrent `transcribe(stream:)` calls a session start
/// produces (one per channel) — and across the calls a NEW session makes
/// while an old session's streams are still parked on the same load.
///
/// The only state here is the model cache. Per-session state was removed on
/// purpose: see `LazyWhisperKitTranscriber`'s class docs.
private actor Resolver {

    private static let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "transcriber")

    // Model cache — one engine per app lifetime, keyed by variant.
    private var engineVariant: String?
    private var engine: (any WhisperEngine)?
    private var engineBuild: Task<(variant: String, engine: any WhisperEngine)?, Never>?
    private var engineBuildVariant: String?
    /// Identifies a build across suspensions: a build superseded by a variant
    /// change must not adopt the cache when it finally lands.
    private var engineBuildToken = 0

    /// A transcriber for ONE stream, over the shared model. `nil` when no
    /// model is available — the caller drains through
    /// `UnimplementedTranscriber` and the user has already been warned.
    func makeStreamTranscriber() async -> (any Transcriber)? {
        let variant = SettingsKeys.whisperModelName
        guard let engine = await resolveEngine(variant: variant) else { return nil }
        return WhisperKitTranscriber(engine: engine)
    }

    // MARK: Model resolution

    private func resolveEngine(variant: String) async -> (any WhisperEngine)? {
        // Fast path: cached engine matches the persisted variant.
        if engineVariant == variant, let engine {
            return engine
        }
        // A build for this variant is already in flight (the sibling
        // channel's call, or a still-unwinding stream from a previous
        // session) — never load the model twice, and share its FAILURE too:
        // retrying inside the same session would just stall the second
        // channel behind a second doomed load. The retry is the next session
        // start (class docs).
        if let engineBuild, engineBuildVariant == variant {
            return (await engineBuild.value)?.engine
        }

        engineBuildToken += 1
        let token = engineBuildToken
        let build = Task { await Self.buildEngine(variant: variant) }
        engineBuild = build
        engineBuildVariant = variant
        let outcome = await build.value
        // Only the build that is still current adopts the app-lifetime
        // cache. If the variant changed while this load was in flight, a
        // newer engine is already cached and this (older) result must not
        // clobber it — it is handed to its own caller and then dropped.
        if engineBuildToken == token {
            engineBuild = nil
            engineBuildVariant = nil
            if let outcome {
                engineVariant = outcome.variant
                engine = outcome.engine
            } else {
                // Exactly one warning per failed load: the sibling channel
                // joined this build above and returns without re-reporting.
                Task { @MainActor in
                    LazyWhisperKitTranscriber.presentMissingModelNotice(variant: variant)
                }
            }
        }
        return outcome?.engine
    }

    /// Nonisolated build (no actor state): locate the variant folder, then
    /// load, then wrap in the app-wide inference gate. Returns `nil` (with a
    /// loud log) when the model is missing or failed to load — callers fall
    /// back to `UnimplementedTranscriber` and the user is warned.
    private static func buildEngine(variant: String) async -> (variant: String, engine: any WhisperEngine)? {
        #if DEBUG
        if let factory = LazyWhisperKitTranscriber.engineFactoryForTesting {
            guard let engine = await factory(variant) else { return nil }
            return (variant, SharedInferenceGate(engine: engine))
        }
        #endif
        guard let folder = WhisperModelLocator.locateModelFolder(variant: variant) else {
            logger.error("""
            Whisper model '\(variant, privacy: .public)' not found under the models root — \
            transcription is disabled this session (Settings → Whisper Model downloads it). \
            Retrying at the next session start.
            """)
            return nil
        }
        // Log the ATTEMPT, not just success: first load of a large model
        // compiles it for the Neural Engine and can take minutes, during which
        // there was previously no log at all — the session simply drained,
        // timed out and reported an empty transcript with nothing to explain it.
        logger.info("Loading WhisperKit model '\(variant, privacy: .public)' — first load of a large model compiles it and can take minutes.")
        let loadStart = Date()
        do {
            let engine = try await WhisperKitEngine(
                modelName: variant,
                modelFolder: WhisperModelLocator.modelFolderArgument(folder)
            )
            logger.info("WhisperKit engine loaded for '\(variant, privacy: .public)' in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)), privacy: .public)s.")
            return (variant, SharedInferenceGate(engine: engine))
        } catch {
            logger.error("""
            WhisperKit engine failed to load for '\(variant, privacy: .public)': \
            \(String(describing: error), privacy: .public) — falling back to no \
            transcription this session.
            """)
            return nil
        }
    }

}

// MARK: - Model location

/// Where a downloaded Whisper variant lives on disk, and how that location is
/// spelled for `WhisperKitEngine(modelFolder:)`.
///
/// Split out of `Resolver` (which is a private actor around a Core ML load,
/// so nothing in it could ever be exercised) because BOTH halves of this
/// have already shipped broken and both are pure string/filesystem work.
enum WhisperModelLocator {

    /// The filesystem path string to hand `WhisperKitEngine(modelFolder:)`.
    ///
    /// `URL.path()` percent-ENCODES (macOS 13+), so the default models root —
    /// which lives under `~/Library/Application Support/…` — reached WhisperKit
    /// as `Application%20Support`, no such directory existed, and every model
    /// load failed with `modelsUnavailable`. Transcription was silently
    /// disabled for months of real use. `path(percentEncoded: false)` is the
    /// decoded filesystem spelling, which is the only thing a POSIX API can
    /// open.
    ///
    /// The deprecated `.path` property is NOT the fix to reach for here: it is
    /// deprecated precisely because callers kept confusing the two, and being
    /// explicit is what the next reader needs to see.
    static func modelFolderArgument(_ folder: URL) -> String {
        folder.path(percentEncoded: false)
    }

    /// Locates a downloaded variant's folder under `root`, mirroring the
    /// heuristic `ModelDownloadManager.isDownloaded` uses: a compiled Core ML
    /// bundle (`*.mlmodelc`) whose parent folder is named for the variant (the
    /// Hub cache nests it as `…/snapshots/<hash>/openai_whisper-<variant>/`).
    /// Returns the variant folder for `WhisperKitEngine(modelFolder:)`.
    ///
    /// `root` is a parameter only so this can be pointed at a fixture tree;
    /// every app path takes the default.
    static func locateModelFolder(
        root: URL = ModelDownloadManager.defaultModelRoot,
        variant: String
    ) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
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
