import Foundation
import Persistence

// MARK: - Engine gating

/// Minimal counting async semaphore. Foundation's `DispatchSemaphore` would
/// block a cooperative thread, and actor isolation alone does not give
/// mutual exclusion across `await` suspension points — this does.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            permits += 1
        }
    }
}

/// Enforces the SPEC §4.2 shared-model architecture rule from the consumer
/// side: at most ONE inference in flight across BOTH channels. The two
/// per-channel serial queues (one `ChannelWorker` actor each) still queue and
/// VAD independently — a busy channel lags, it never corrupts the other's
/// ordering (the accepted v0 trade-off, SPEC §4.2). Applied inside
/// `WhisperKitTranscriber` rather than inside `WhisperKitEngine` so the
/// guarantee holds for any engine, including test fakes.
struct GatedEngine: WhisperEngine {
    private let engine: any WhisperEngine
    private let gate = AsyncSemaphore(permits: 1)

    init(engine: any WhisperEngine) {
        self.engine = engine
    }

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        await gate.wait()
        do {
            let hypotheses = try await engine.transcribeBuffer(samples)
            await gate.signal()
            return hypotheses
        } catch {
            // Release the permit on failure too — `defer` cannot `await` an
            // actor call, so both exits signal explicitly.
            await gate.signal()
            throw error
        }
    }
}

// MARK: - Segment id stability

/// Window-start → segment-id map with bounded retention (SPEC §4.2 hard
/// rule): the id is minted at the FIRST hypothesis for a window; if the
/// engine re-emits a revision for the same window (same start), the same id
/// is reused so the store UPSERTs the row instead of appending a duplicate.
///
/// Keys are exact-match Doubles minted from our own window-start values
/// (the identical stored value is reused on lookup), so float equality is
/// safe here. An LRU keeps at most `capacity` windows; older windows are
/// forgotten — a revision after eviction mints a fresh id, an accepted
/// Phase 2 edge (v0 has no re-decode loop at all).
struct SegmentIdCache {
    private var ids: [Double: UUID] = [:]
    private var order: [Double] = []
    let capacity: Int

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    mutating func id(forWindowStart windowStart: TimeInterval) -> UUID {
        if let existing = ids[windowStart] { return existing }
        if order.count == capacity, let oldest = order.first {
            order.removeFirst()
            ids[oldest] = nil
        }
        let minted = UUID()
        ids[windowStart] = minted
        order.append(windowStart)
        return minted
    }
}

// MARK: - Per-channel worker (VAD windowing + serial inference)

/// One channel's serial queue: an actor whose mailbox IS the queue. Chunks
/// are processed strictly in arrival order; while a window decode is in
/// flight (awaiting the shared, globally-gated engine) later chunks wait in
/// the mailbox, so VAD state stays consistent.
///
/// Energy VAD + hangover windowing (SPEC §4.2 — "WhisperKit is chunked batch
/// over rolling VAD windows"; this seam uses a simple energy detector
/// instead of WhisperKit's built-in VAD because we hand it pre-windowed
/// buffers). Constants are documented and tunable (dogfood, SPEC §7):
/// - Frame: 30 ms (480 samples @ 16 kHz) RMS decision.
/// - Speech frame: RMS ≥ `speechThresholdRMS` (0.02 ≈ −34 dBFS).
/// - Window OPENS at the first speech frame; windows with ≥
///   `minSpeechSeconds` (1 s) of speech qualify for inference — shorter
///   bursts are dropped (coughs, clicks).
/// - Window CLOSES (inference dispatched) once ≥ `hangoverSeconds`
///   (0.8 s) of trailing silence accumulates — the "≥800 ms silence after
///   ≥1 s speech" rule; with a ~2 s `small.en` decode on M-series that
///   lands finalization ~3–5 s after speech ends (SPEC §4.2).
/// - Hard cap `maxWindowSeconds` (30 s) forces emission during unbroken
///   monologues so buffers stay bounded.
/// - A session-clock gap > `gapTolerance` (device switch, SPEC §4.1 honest
///   gaps) closes the window instead of stitching across the gap.
actor ChannelWorker {
    // Tunables (see class docs).
    private let frameSamples: Int
    private let speechThresholdRMS: Float
    private let minSpeechSamples: Int
    private let hangoverSamples: Int
    private let maxWindowSamples: Int
    private let gapTolerance: Double = 0.05
    private let sampleRate: Double

    private let channel: Channel
    private let engine: any WhisperEngine
    private let emit: @Sendable (TranscriptSegment) -> Void

    // Accumulation state. `pending` holds pre-window silence plus sub-frame
    // remainders; once a window opens, frames flow into `window` instead.
    // `pendingAnchored` is false whenever `pending` is empty, so the next
    // chunk re-anchors `pendingStartOffset` (no stale-offset drift across
    // window boundaries).
    private var pending: [Float] = []
    private var pendingStartOffset: TimeInterval = 0
    private var pendingAnchored = false
    private var window: [Float] = []
    private var windowStartOffset: TimeInterval = 0
    private var windowOpen = false
    /// Consecutive-silence sample count since the last speech frame.
    private var trailingSilenceSamples = 0
    /// Index into `window` one past the last speech sample (trim point).
    private var speechEndIndex = 0
    /// Total speech-frame samples in the open window (min-duration gate).
    private var speechSampleCount = 0
    private var nextExpectedOffset: TimeInterval?
    private var ids = SegmentIdCache()

    init(
        channel: Channel,
        engine: any WhisperEngine,
        sampleRate: Double = 16_000,
        frameMilliseconds: Int = 30,
        speechThresholdRMS: Float = 0.02,
        minSpeechSeconds: Double = 1.0,
        hangoverSeconds: Double = 0.8,
        maxWindowSeconds: Double = 30.0,
        emit: @escaping @Sendable (TranscriptSegment) -> Void
    ) {
        self.channel = channel
        self.engine = engine
        self.sampleRate = sampleRate
        self.frameSamples = Int(sampleRate * Double(frameMilliseconds) / 1000)
        self.speechThresholdRMS = speechThresholdRMS
        self.minSpeechSamples = Int(minSpeechSeconds * sampleRate)
        self.hangoverSamples = Int(hangoverSeconds * sampleRate)
        self.maxWindowSamples = Int(maxWindowSeconds * sampleRate)
        self.emit = emit
    }

    // MARK: Feeding

    func feed(_ chunk: AudioChunk) async {
        // TranscribeKit's input contract is 16 kHz mono Float32 (SPEC §4.1);
        // CaptureKit downsamples before handing buffers over. A mismatched
        // rate would corrupt every sample-count computation below — treat it
        // as a hard boundary (close + reset) rather than mis-math.
        guard chunk.sampleRate == sampleRate else {
            await closeWindow(forced: speechSampleCount > 0)
            resetWindowState()
            pending = []
            pendingAnchored = false
            nextExpectedOffset = chunk.sessionOffset + Double(chunk.samples.count) / chunk.sampleRate
            return
        }

        // Honest gaps (SPEC §4.1): a jump in session offsets (device switch,
        // sleep) ends the window — never stitch silence we never received.
        if let expected = nextExpectedOffset, chunk.sessionOffset > expected + gapTolerance {
            await closeWindow(forced: false)
            resetWindowState()
            pending = []
            pendingAnchored = false
        }
        if !pendingAnchored {
            pendingStartOffset = chunk.sessionOffset
            pendingAnchored = true
        }
        nextExpectedOffset = chunk.sessionOffset + Double(chunk.samples.count) / sampleRate

        pending.append(contentsOf: chunk.samples)
        processFrames()
        await closeIfExpired()
    }

    /// Stream end (session stop): finalize whatever speech is pending so
    /// stop → processing → fusion sees the full transcript (SPEC §4.4
    /// "stop finalizes pending segments"). Speech shorter than
    /// `minSpeechSeconds` still emits here — better a short final segment
    /// than silently dropped audio at session end.
    func finish() async {
        if windowOpen {
            await closeWindow(forced: true)
        }
        resetWindowState()
        pending = []
        pendingAnchored = false
    }

    // MARK: VAD

    /// Decides 30 ms frames off full boundaries only; sub-frame remainders
    /// stay in `pending` for the next chunk. Pure synchronous state machine.
    private func processFrames() {
        while pending.count >= frameSamples {
            let frame = pending.prefix(frameSamples)
            let isSpeech = Self.rms(frame) >= speechThresholdRMS
            pending.removeFirst(frameSamples)
            pendingStartOffset += Double(frameSamples) / sampleRate

            if !windowOpen {
                guard isSpeech else { continue }
                // Window opens at this frame: everything from here on is
                // kept (internal pauses included — context for the decoder).
                windowStartOffset = pendingStartOffset - Double(frameSamples) / sampleRate
                window = Array(frame)
                windowOpen = true
                trailingSilenceSamples = 0
                speechEndIndex = window.count
                speechSampleCount = frameSamples
                continue
            }

            window.append(contentsOf: frame)
            if isSpeech {
                speechSampleCount += frameSamples
                trailingSilenceSamples = 0
                speechEndIndex = window.count
            } else {
                trailingSilenceSamples += frameSamples
            }
        }
        if pending.isEmpty {
            pendingAnchored = false
        }
    }

    private func closeIfExpired() async {
        guard windowOpen else { return }
        if trailingSilenceSamples >= hangoverSamples || window.count >= maxWindowSamples {
            await closeWindow(forced: false)
        }
    }

    /// Closes the open window: trims trailing silence back to the last
    /// speech sample and — when enough speech accumulated (or the close is
    /// forced by stream end) — decodes and emits exactly one segment
    /// (hypothesis lines joined; id from the per-channel `SegmentIdCache`).
    private func closeWindow(forced: Bool) async {
        defer { resetWindowState() }
        guard windowOpen else { return }

        let speechBuffer = Array(window.prefix(max(0, speechEndIndex)))
        let qualifies = forced || speechSampleCount >= minSpeechSamples
        guard qualifies, !speechBuffer.isEmpty else { return }

        await decodeAndEmit(samples: speechBuffer, windowStart: windowStartOffset)
    }

    private func resetWindowState() {
        window = []
        windowOpen = false
        trailingSilenceSamples = 0
        speechEndIndex = 0
        speechSampleCount = 0
    }

    // MARK: Inference + emission

    private func decodeAndEmit(samples: [Float], windowStart: TimeInterval) async {
        let hypotheses: [WhisperHypothesis]
        do {
            hypotheses = try await engine.transcribeBuffer(samples)
        } catch {
            // v0: drop the window (nothing consumes the transcript live,
            // SPEC §4.2). Phase 2 adds bounded retry / re-decode handling.
            return
        }
        guard !hypotheses.isEmpty else { return }

        // Single chokepoint for special-token stripping (SPEC §4.2): this is
        // the ONE place a `TranscriptSegment`'s text is produced from engine
        // output, so stripping here — rather than at each display site —
        // guarantees no token ever reaches the store, History, exports, the
        // fusion prompt, or the NotesValidator haystack, for ANY
        // `WhisperEngine` implementation. `strip` also normalises the
        // whitespace tokens leave behind, so segments never start with a
        // stray space; a hypothesis that was nothing but tokens becomes
        // empty and is filtered out (a window of only tokens emits nothing
        // instead of a blank segment).
        let text = hypotheses
            .map { WhisperSpecialTokens.strip($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return }

        // Offsets (SPEC §4.2): chunk sessionOffset + window position within
        // the accumulated buffer. Hypothesis seconds are relative to the
        // (trimmed) window buffer, so the window's own start on the session
        // clock anchors them. The 16 kHz sample-count math lives entirely in
        // `windowStartOffset`'s derivation: first speech frame's offset =
        // chunk sessionOffset + (sample index / 16_000).
        let start = windowStart + (hypotheses.map(\.startSeconds).min() ?? 0)
        let fallbackEnd = Double(samples.count) / sampleRate
        let end = windowStart + (hypotheses.map(\.endSeconds).max() ?? fallbackEnd)

        emit(TranscriptSegment(
            id: ids.id(forWindowStart: windowStart),
            channel: channel,
            text: text,
            startOffset: start,
            endOffset: end,
            // v0: first emission is final — there is no re-decode loop yet.
            // WhisperKit is batch, so the revision-based `isFinal = false`
            // paths (re-decode a window with more right context, upsert on
            // the stable id) are deferred to Phase 2 by design; the
            // SegmentIdCache machinery they need is already in place.
            isFinal: true,
            inferredAt: Date() // stamped at inference completion (SPEC §4.2)
        ))
    }

    private static func rms<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Double = 0
        var count = 0
        for sample in samples {
            sum += Double(sample) * Double(sample)
            count += 1
        }
        guard count > 0 else { return 0 }
        return Float((sum / Double(count)).squareRoot())
    }

    #if DEBUG
    /// TEST HOOK: simulates a Phase 2 revision — re-emits a hypothesis for an
    /// already-decoded window through the same id-cache lookup, proving the
    /// id is reused (upsert, not append; SPEC §4.2). Not called by production
    /// code paths: v0 has no re-decode loop.
    func reviseForTesting(windowStart: TimeInterval, text: String) {
        emit(TranscriptSegment(
            id: ids.id(forWindowStart: windowStart),
            channel: channel,
            text: text,
            startOffset: windowStart,
            endOffset: windowStart + 2.0,
            isFinal: true,
            inferredAt: Date()
        ))
    }
    #endif
}

// MARK: - Transcriber

/// `Transcriber` conformance over a shared `WhisperEngine` (SPEC §4.2):
/// ONE engine, TWO serial inference queues — one `ChannelWorker` actor per
/// channel — with every engine call globally serialized through
/// `GatedEngine`. Two model instances are explicitly rejected by the spec;
/// this type makes two CONCURRENT inferences equally impossible.
///
/// SessionKit's `TranscriptPipeline` calls `transcribe(stream:)` once per
/// channel (one stream per channel, SPEC §3.1); workers are created lazily
/// from each chunk's `channel`, so a single shared instance serves both.
/// Assumption: at most one live stream per channel per transcriber instance
/// (what the pipeline does) — a second stream for the same channel would
/// share the worker and its emission sink.
public final class WhisperKitTranscriber: Transcriber, @unchecked Sendable {
    private let engine: any WhisperEngine
    private let lock = NSLock()
    private var workers: [Channel: ChannelWorker] = [:]

    public init(engine: any WhisperEngine) {
        // Gate at construction: the raw engine is never called ungated.
        self.engine = GatedEngine(engine: engine)
    }

    public func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                var lastWorker: ChannelWorker?
                for await chunk in stream {
                    guard let transcriber = self else {
                        continuation.finish()
                        return
                    }
                    let worker = transcriber.worker(for: chunk.channel, emit: { continuation.yield($0) })
                    lastWorker = worker
                    await worker.feed(chunk)
                }
                // Stream ended: flush this channel's pending window so stop
                // finalizes segments before fusion (SPEC §4.4).
                await lastWorker?.finish()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func worker(
        for channel: Channel,
        emit: @escaping @Sendable (TranscriptSegment) -> Void
    ) -> ChannelWorker {
        lock.lock()
        defer { lock.unlock() }
        if let existing = workers[channel] { return existing }
        let worker = ChannelWorker(channel: channel, engine: engine, emit: emit)
        workers[channel] = worker
        return worker
    }
}