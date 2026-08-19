import Foundation
import GRDB
import XCTest
@testable import Persistence

/// Item 25: segment writes are coalesced into one transaction per batch.
///
/// The constraint is SPEC §4.4 — *segments hit SQLite within 5 s of
/// finalization, never memory-only* — so every test here is really asking the
/// same question two ways: **is the optimisation bounded**, and **did the
/// upsert rule survive it**.
final class SegmentBatchingTests: XCTestCase {

    private func segment(_ id: UUID, _ sessionId: UUID, text: String,
                         offset: Double = 0, isFinal: Bool = false) -> SegmentRecord {
        SegmentRecord(id: id, sessionId: sessionId, channel: .remote, text: text,
                      startOffset: offset, endOffset: offset + 2, isFinal: isFinal,
                      inferredAt: FixedTime.date(2026, 8, 19, 9, 0, in: FixedTime.utc),
                      createdAt: FixedTime.date(2026, 8, 19, 9, 0, in: FixedTime.utc))
    }

    /// Rows visible to a SECOND connection — the only proof that matters for
    /// crash recovery. Never goes through `MeetingStore`, so it cannot be
    /// satisfied by a flush-on-read.
    private func rowsOnDisk(_ path: String) throws -> Int {
        try RawStore.count(path, "segments")
    }

    // MARK: The bound (SPEC §4.4)

    /// THE KILL TEST for batching. One segment, no further writes, nobody
    /// calling flush: it must land on disk — visible to a second connection,
    /// with the writing store still open and unclosed — strictly inside the
    /// 5 s the spec promises the user.
    ///
    /// Fails for a real reason: remove the time bound from `SegmentBatcher`
    /// (keep only the count bound) and this hangs on until the deadline and
    /// fails; raise `SegmentBatchPolicy.default.maxDelay` past 5 s and the
    /// clamp is what keeps it passing.
    func testASingleSegmentReachesDiskWithinTheSpecBoundWithNobodyFlushing() throws {
        let dir = TempStoreDirectory("batch-bound")
        let store = try MeetingStore(path: dir.storePath)   // production policy
        let session = try store.createSession()
        let started = Date()

        try store.upsertSegment(segment(UUID(), session.id, text: "the crash happens now"))

        var landedAfter: TimeInterval?
        while Date().timeIntervalSince(started) < SegmentBatchPolicy.specPersistenceBound {
            if try rowsOnDisk(dir.storePath) == 1 {
                landedAfter = Date().timeIntervalSince(started)
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let elapsed = try XCTUnwrap(landedAfter,
                                    "a buffered segment never reached disk inside the SPEC §4.4 5 s bound")
        XCTAssertLessThanOrEqual(elapsed, SegmentBatchPolicy.specPersistenceBound)
        XCTAssertFalse(store.hasPendingSegmentWrites)
        print("ITEM 25 — unflushed segment reached disk after \(String(format: "%.2f", elapsed))s "
              + "(bound: \(SegmentBatchPolicy.specPersistenceBound)s, "
              + "policy: \(SegmentBatchPolicy.default.maxDelay)s)")
    }

    /// No policy may be constructed that breaks §4.4, however it is asked for.
    func testTheDelayBoundIsClampedToTheSpecGuarantee() {
        XCTAssertEqual(SegmentBatchPolicy(maxCount: 8, maxDelay: 30).maxDelay,
                       SegmentBatchPolicy.specPersistenceBound)
        XCTAssertLessThanOrEqual(SegmentBatchPolicy.default.maxDelay,
                                 SegmentBatchPolicy.specPersistenceBound)
        XCTAssertEqual(SegmentBatchPolicy(maxCount: 0, maxDelay: -1).maxCount, 1,
                       "a degenerate policy degrades to write-through, never to no-write")
    }

    /// The time bound fires on its own — no second write to piggyback on, no
    /// read to trigger a flush.
    func testTheTimeBoundFlushesWithNoFurtherActivity() throws {
        let dir = TempStoreDirectory("batch-timer")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 0.3))
        let session = try store.createSession()
        try store.upsertSegment(segment(UUID(), session.id, text: "alone in the batch"))

        XCTAssertEqual(try rowsOnDisk(dir.storePath), 0, "precondition: it really was buffered")
        let landed = expectation(description: "timer flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { landed.fulfill() }
        wait(for: [landed], timeout: 3)

        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1)
        XCTAssertFalse(store.hasPendingSegmentWrites)
    }

    /// The count bound fires first when segments arrive faster than the timer.
    func testTheCountBoundCommitsWithoutWaitingForTheTimer() throws {
        let dir = TempStoreDirectory("batch-count")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 4, maxDelay: 5))
        let session = try store.createSession()
        for index in 0..<3 {
            try store.upsertSegment(segment(UUID(), session.id, text: "seg \(index)",
                                            offset: Double(index)))
        }
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 0, "under the count bound: still buffered")

        try store.upsertSegment(segment(UUID(), session.id, text: "seg 3", offset: 3))
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 4, "the 4th write commits the batch synchronously")
    }

    /// A store that goes away mid-batch must take nothing with it — the path
    /// a normal quit takes.
    func testABatchIsFlushedWhenTheStoreIsReleased() throws {
        let dir = TempStoreDirectory("batch-deinit")
        let sessionId = UUID()
        do {
            let store = try MeetingStore(path: dir.storePath,
                                         segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 5))
            _ = try store.createSession(id: sessionId)
            try store.upsertSegment(segment(UUID(), sessionId, text: "written at the last moment"))
            XCTAssertEqual(try rowsOnDisk(dir.storePath), 0)
        }
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1, "deinit must flush the batch")
    }

    // MARK: The upsert rule (SPEC §4.2) under batching

    /// Two hypotheses for the same window inside ONE batch: the revision
    /// replaces the buffered row rather than queuing a second insert.
    func testARevisionInsideOneBatchReplacesInsteadOfAppending() throws {
        let dir = TempStoreDirectory("batch-upsert-inside")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 5))
        let session = try store.createSession()
        let id = UUID()

        try store.upsertSegment(segment(id, session.id, text: "so we should deferring the migration"))
        try store.upsertSegment(segment(id, session.id, text: "so we should defer the migration",
                                        isFinal: true))
        try store.flushSegments()

        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1, "revised hypothesis must replace, not append")
        let segments = try store.segments(sessionId: session.id)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "so we should defer the migration")
        XCTAssertTrue(segments[0].isFinal)
    }

    /// …and ACROSS batches: the first hypothesis is already committed when
    /// the revision arrives, so the row is upserted on disk instead.
    func testARevisionAcrossBatchesStillReplacesTheCommittedRow() throws {
        let dir = TempStoreDirectory("batch-upsert-across")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 1, maxDelay: 0))
        let session = try store.createSession()
        let id = UUID()

        try store.upsertSegment(segment(id, session.id, text: "first pass"))
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1)
        try store.upsertSegment(segment(id, session.id, text: "revised", isFinal: true))

        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1)
        XCTAssertEqual(try store.segments(sessionId: session.id).map(\.text), ["revised"])
    }

    /// Batching must not re-order the transcript: the batch keeps insertion
    /// order, and a revision keeps the position it already had.
    func testABatchPreservesSegmentOrderIncludingRevisedRows() throws {
        let dir = TempStoreDirectory("batch-order")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 5))
        let session = try store.createSession()
        let first = UUID(), second = UUID(), third = UUID()

        try store.upsertSegment(segment(first, session.id, text: "one", offset: 0))
        try store.upsertSegment(segment(second, session.id, text: "two", offset: 1))
        try store.upsertSegment(segment(first, session.id, text: "one (revised)", offset: 0))
        try store.upsertSegment(segment(third, session.id, text: "three", offset: 2))

        XCTAssertEqual(try store.segments(sessionId: session.id).map(\.text),
                       ["one (revised)", "two", "three"])
    }

    // MARK: Reads and deletes see a current store

    func testAReadNeverSeesAStaleTranscript() throws {
        let dir = TempStoreDirectory("batch-read")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 5))
        let session = try store.createSession()
        try store.upsertSegment(segment(UUID(), session.id, text: "just spoken"))

        // Both readers flush first — fusion and History must never fuse a
        // transcript that is missing its last minute.
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 1)
        XCTAssertEqual(try store.segments(sessionId: session.id).map(\.text), ["just spoken"])
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 1)
    }

    func testDeletingASessionDoesNotResurrectABufferedSegment() throws {
        let dir = TempStoreDirectory("batch-delete")
        let store = try MeetingStore(path: dir.storePath,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 0.3))
        let session = try store.createSession()
        try store.upsertSegment(segment(UUID(), session.id, text: "deleted before it landed"))

        try store.deleteSession(id: session.id)

        let settled = expectation(description: "past the flush deadline")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(try rowsOnDisk(dir.storePath), 0, "a buffered row must not outlive its session")
    }

    // MARK: Failures stay loud

    /// Batching removes the caller that used to catch the write error, so the
    /// error has to be handed to the NEXT caller. Silent write loss is the
    /// defect this codebase is organised against (SPEC §4.4).
    func testAFailedBatchSurfacesToTheNextCallerInsteadOfVanishing() throws {
        let dir = TempStoreDirectory("batch-readonly")
        let path = dir.path("store.sqlite")
        let sessionId = UUID()
        do {
            let store = try MeetingStore(path: path)
            _ = try store.createSession(id: sessionId)
        }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path + suffix)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path) }

        let store = try MeetingStore(path: path,
                                     segmentBatch: SegmentBatchPolicy(maxCount: 64, maxDelay: 5))
        try store.upsertSegment(segment(UUID(), sessionId, text: "nowhere to go"))
        XCTAssertThrowsError(try store.flushSegments()) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_READONLY,
                           "a failed batch must reach a caller, not just a log line: \(error)")
        }
        // …and the segment is still queued, not dropped, so a store that
        // becomes writable again does not lose the meeting.
        XCTAssertTrue(store.hasPendingSegmentWrites)

        // A read must still work: showing the rows that DID reach disk beats
        // failing the History window because a later write could not.
        XCTAssertNoThrow(try store.segments(sessionId: sessionId))
    }

    // MARK: What the batching is worth

    /// Measured before/after for item 25: the same 400 segment upserts as
    /// individual transactions (the pre-change behaviour, `.immediate`) and as
    /// batches. Printed; the assertion is only the direction.
    func testBatchedWritesCostLessThanPerSegmentCommits() throws {
        let count = 400
        let sessionId = UUID()

        func run(_ policy: SegmentBatchPolicy, label: String) throws -> TimeInterval {
            let dir = TempStoreDirectory("batch-bench-\(label)")
            let store = try MeetingStore(path: dir.storePath, segmentBatch: policy)
            _ = try store.createSession(id: sessionId)
            let start = Date()
            for index in 0..<count {
                try store.upsertSegment(segment(UUID(), sessionId, text: "segment \(index)",
                                                offset: Double(index)))
            }
            try store.flushSegments()
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(try store.segmentCount(sessionId: sessionId), count)
            return elapsed
        }

        let perSegment = try run(.immediate, label: "immediate")
        let batched = try run(.default, label: "batched")
        print("""
        ITEM 25 — \(count) segment upserts on disk (WAL):
          per-segment transactions: \(String(format: "%.1f", perSegment * 1000)) ms \
        (\(String(format: "%.3f", perSegment / Double(count) * 1000)) ms each)
          batched (\(SegmentBatchPolicy.default.maxCount)/batch): \
        \(String(format: "%.1f", batched * 1000)) ms \
        (\(String(format: "%.3f", batched / Double(count) * 1000)) ms each) — \
        \(String(format: "%.1f", perSegment / max(batched, 0.000001)))× faster
        """)
        XCTAssertLessThan(batched, perSegment)
    }
}
