import CaptureKit
import Foundation
import Persistence
import TranscribeKit

/// Capture → per-channel transcription → store (SPEC §3.2 data flow).
///
/// Internal to SessionKit: the coordinator owns exactly one pipeline per
/// session. Splits the capture callback by channel into two
/// `AsyncStream<AudioChunk>` (one per channel — "me"/"them" separation,
/// SPEC §3.1), runs `transcriber.transcribe(stream:)` on each, and upserts
/// every emitted `TranscriptSegment` into the store.
///
/// PERSISTENCE CADENCE (SPEC §4.4 hard rule): segments must hit SQLite
/// within 5 s of finalization — never memory-only. This pipeline does better
/// and persists IMMEDIATELY on every hypothesis, final or not: a streaming
/// engine may revise a hypothesis several times, and each revision is an
/// upsert on the segment's stable UUID (SPEC §4.2 hard rule), so persisting
/// eagerly is idempotent and a crash mid-meeting loses nothing pending.
/// (A failed upsert is naturally retried by the next hypothesis revision on
/// the same UUID — errors are tolerated and dropped.)
///
/// Feed path is non-blocking by contract: the capture engine calls
/// `feed(_:)` on its internal queue ("handlers must not block",
/// `CaptureEngine.onAudio`), and this implementation only yields into
/// unbounded streams.
final class TranscriptPipeline: @unchecked Sendable {

    private let store: MeetingStore
    private let sessionId: UUID
    private let tasks: [Task<Void, Never>]
    private let lock = NSLock()
    private var continuations: [Channel: AsyncStream<AudioChunk>.Continuation]

    /// Runs `body` under `lock`; no call site awaits while holding it.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Wires both channel streams and starts both transcription consumers.
    /// Exactly two channels (`.local` = me, `.remote` = them, SPEC §3.2).
    init(store: MeetingStore, sessionId: UUID, transcriber: any Transcriber) {
        self.store = store
        self.sessionId = sessionId

        var built: [Channel: AsyncStream<AudioChunk>.Continuation] = [:]
        var consumers: [Task<Void, Never>] = []
        for channel in [Channel.local, Channel.remote] {
            let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
            built[channel] = continuation
            // One consumer per channel: upsert every hypothesis the moment
            // it is emitted (see class docs — beats the ≤5 s cadence).
            consumers.append(Task { [store, sessionId, transcriber] in
                for await segment in transcriber.transcribe(stream: stream) {
                    try? store.upsertSegment(segment.toRecord(sessionId: sessionId))
                }
            })
        }

        // No lock needed: nothing else can reference `self` yet.
        continuations = built
        tasks = consumers
    }

    /// Capture callback entry point. Called on the engine's internal queue;
    /// converts the `CapturedSample` (CaptureKit vocabulary) to an
    /// `AudioChunk` (TranscribeKit vocabulary) — the composition root does
    /// this translation; the two modules never import each other (SPEC §3.1).
    /// Unknown channels are dropped. After `finish()` this is a no-op.
    func feed(_ sample: CapturedSample) {
        let chunk = AudioChunk(
            channel: sample.channel,
            sessionOffset: sample.sessionOffset,
            sampleRate: sample.sampleRate,
            samples: sample.samples
        )
        let continuation = withLock { continuations[sample.channel] }
        continuation?.yield(chunk)
    }

    /// Ends both channel streams, then waits for both transcription
    /// consumers to drain everything they emitted into the store. Called by
    /// the coordinator at stop, BEFORE fusion runs (SPEC §4.4: stop
    /// finalizes pending segments → processing → fusion).
    func finish() async {
        let remaining = withLock {
            let remaining = continuations
            continuations = [:]
            return remaining
        }
        for continuation in remaining.values {
            continuation.finish()
        }
        for task in tasks {
            await task.value
        }
    }
}
