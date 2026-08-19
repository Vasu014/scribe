import Foundation
import GRDB
import os

/// How long segment writes may be coalesced before they MUST be on disk
/// (item 25, bounded by SPEC §4.4).
///
/// SPEC §4.4 is the constraint that shapes this type: *"segments and fragments
/// hit SQLite within 5 s of finalization — never memory-only"*. A crash must
/// not cost more than 5 s of work, and `testSegmentsReachDiskWithinTheSpecBound`
/// is the kill-test for it. Batching is therefore bounded by **time as well as
/// count, whichever comes first**:
///
/// - `maxCount` segments buffered → commit immediately, in the calling thread.
/// - `maxDelay` after the FIRST buffered segment → commit from the timer,
///   even if nothing else ever arrives. This is the bound that matters for
///   crash safety, and it is clamped to `specPersistenceBound` at
///   construction so no policy can be written that violates §4.4.
///
/// The default 2 s leaves 3 s of headroom under the spec bound (timer slack,
/// a slow WAL commit, a machine under load) — the guarantee is what the app
/// promises the user, not what it hits on a good day.
public struct SegmentBatchPolicy: Sendable, Equatable {
    /// SPEC §4.4 hard bound. Nothing may buffer longer than this.
    public static let specPersistenceBound: TimeInterval = 5.0

    /// Buffer this many segments and the batch commits without waiting.
    public let maxCount: Int
    /// Longest a segment may sit unwritten. Clamped to `specPersistenceBound`.
    public let maxDelay: TimeInterval

    public init(maxCount: Int, maxDelay: TimeInterval) {
        self.maxCount = max(1, maxCount)
        // Clamp rather than trap: a bad policy must not be able to crash a
        // recording, and must not be able to break §4.4 either. The clamp IS
        // the guarantee — `testTheDelayBoundIsClampedToTheSpecGuarantee`.
        self.maxDelay = min(max(0, maxDelay), Self.specPersistenceBound)
    }

    /// Production default: 2 s / 32 segments (see type docs).
    public static let `default` = SegmentBatchPolicy(maxCount: 32, maxDelay: 2.0)

    /// No batching — every write commits in its own transaction (the
    /// pre-item-25 behaviour, kept for tests that need synchronous disk state).
    public static let immediate = SegmentBatchPolicy(maxCount: 1, maxDelay: 0)
}

/// Coalesces segment upserts into one transaction per batch.
///
/// WHY: every hypothesis used to be its own `dbQueue.write` — its own
/// transaction, its own WAL frame and fsync. Two channels emitting revisions
/// through a meeting is a steady drip of single-row commits, and the
/// per-commit cost is dominated by the transaction, not the row.
///
/// UPSERT SEMANTICS ARE PRESERVED (SPEC §4.2 hard rule). The buffer is keyed
/// by segment id: a revised hypothesis for an id already in the batch REPLACES
/// it in place, keeping its position in the batch, so a batch never contains
/// two rows for one id and never re-orders the stream. Whether a revision is
/// coalesced in memory or upserted over an already-committed row, the result
/// on disk is identical — one row per id, last writer wins.
///
/// FAILURES ARE NOT SWALLOWED. A timer-driven commit has no caller to throw
/// to, so a failed batch is (a) logged, (b) kept queued for the next flush,
/// and (c) re-thrown to the next caller of `enqueue`/`flush`. Silent write
/// loss is this app's defining defect (SPEC §4.4, both audits) and batching
/// must not reintroduce it.
final class SegmentBatcher: @unchecked Sendable {

    /// Ceiling on records held across failed flushes, so a store that has
    /// become unwritable cannot grow the buffer without bound.
    private static let maxRetained = 1_024

    private let policy: SegmentBatchPolicy
    private let commit: @Sendable ([SegmentRecord]) throws -> Void
    private let log = Logger(subsystem: "io.github.vasu014.scribe", category: "store")

    private let lock = NSLock()
    private let timerQueue = DispatchQueue(label: "scribe.store.segment-batch")

    /// Insertion-ordered batch; `index` maps segment id → position for the
    /// replace-in-place upsert rule.
    private var pending: [SegmentRecord] = []
    private var index: [UUID: Int] = [:]
    private var flushScheduled = false
    /// Error from a flush nobody could catch, handed to the next caller.
    private var deferredError: Error?

    init(policy: SegmentBatchPolicy, commit: @escaping @Sendable ([SegmentRecord]) throws -> Void) {
        self.policy = policy
        self.commit = commit
    }

    /// Buffers one segment, committing synchronously when the count bound is
    /// reached and arming the time bound otherwise.
    func enqueue(_ record: SegmentRecord) throws {
        var immediate: [SegmentRecord] = []
        var arm = false

        lock.lock()
        if let position = index[record.id] {
            pending[position] = record       // revision replaces, never appends
        } else {
            index[record.id] = pending.count
            pending.append(record)
        }
        if pending.count >= policy.maxCount {
            immediate = drainLocked()
        } else if !flushScheduled {
            flushScheduled = true
            arm = true
        }
        let pendingError = takeDeferredErrorLocked()
        lock.unlock()

        if arm {
            // Deadline runs from the FIRST record of the batch, so every
            // record is on disk within `maxDelay` of ITS OWN enqueue at worst.
            timerQueue.asyncAfter(deadline: .now() + policy.maxDelay) { [weak self] in
                self?.flushFromTimer()
            }
        }
        if !immediate.isEmpty {
            try write(immediate)
        }
        if let pendingError { throw pendingError }
    }

    /// Commits everything buffered, now. Throws the batch's error (and any
    /// error a timer flush could not report).
    func flush() throws {
        lock.lock()
        let batch = drainLocked()
        let pendingError = takeDeferredErrorLocked()
        lock.unlock()

        if !batch.isEmpty {
            try write(batch)
        }
        if let pendingError { throw pendingError }
    }

    /// True when nothing is waiting — used by tests to prove the time bound
    /// fired without polling the database.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty
    }

    // MARK: Internals

    private func flushFromTimer() {
        lock.lock()
        flushScheduled = false
        let batch = drainLocked()
        lock.unlock()
        guard !batch.isEmpty else { return }
        do {
            try write(batch)
        } catch {
            // Already logged + requeued in `write`; nothing left to throw to.
        }
    }

    private func write(_ batch: [SegmentRecord]) throws {
        do {
            try commit(batch)
        } catch {
            requeue(batch, after: error)
            throw error
        }
    }

    /// Puts a failed batch back at the FRONT of the buffer (ids that were
    /// revised in the meantime keep the newer version) and remembers why.
    private func requeue(_ batch: [SegmentRecord], after error: Error) {
        lock.lock()
        let newer = Set(index.keys)
        var restored = batch.filter { !newer.contains($0.id) }
        restored.append(contentsOf: pending)
        if restored.count > Self.maxRetained {
            let dropped = restored.count - Self.maxRetained
            restored.removeFirst(dropped)
            log.error("""
            Segment batch overflow: \(dropped, privacy: .public) unwritable segments dropped \
            after repeated commit failures.
            """)
        }
        pending = restored
        index = Dictionary(uniqueKeysWithValues: restored.enumerated().map { ($0.element.id, $0.offset) })
        deferredError = error
        let queued = pending.count
        lock.unlock()

        log.error("""
        Segment batch commit FAILED (\(queued, privacy: .public) segments still queued, \
        retried on the next flush): \(String(describing: error), privacy: .public)
        """)
    }

    private func drainLocked() -> [SegmentRecord] {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        index.removeAll(keepingCapacity: true)
        return batch
    }

    private func takeDeferredErrorLocked() -> Error? {
        defer { deferredError = nil }
        return deferredError
    }
}
