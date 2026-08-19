import Foundation
import GRDB

/// The store. All components write to / read from it — nothing calls anything
/// else across module boundaries (SPEC §3.1 architectural rule).
///
/// WAL mode (GRDB default for on-disk queues) is what makes the crash-recovery
/// guarantee cheap: committed rows survive kill -9 without a clean close.
/// Typed failures the store raises for itself, on top of GRDB's
/// `DatabaseError`. Kept `LocalizedError` because the composition root puts
/// `error.localizedDescription` straight into the blocking store-failure
/// alert — the user must be told what is wrong, not shown an enum.
public enum MeetingStoreError: Error, Equatable, Sendable {
    /// The file was written by a NEWER build of Scribe: its
    /// `meta.schema_version` is beyond what this build understands.
    case schemaTooNew(found: Int, supported: Int)
}

extension MeetingStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .schemaTooNew(let found, let supported):
            return """
            This meeting database was created by a newer version of Scribe \
            (database format \(found); this version reads up to \(supported)). \
            Update Scribe to open it — an older version could lose data written by the newer one.
            """
        }
    }
}

public final class MeetingStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    /// Segment writes are coalesced into one transaction per batch, bounded
    /// by count AND time (item 25; SPEC §4.4 ≤ 5 s). See `SegmentBatcher`.
    /// `@unchecked Sendable` because of the batcher's internal buffer — it
    /// does its own locking; `DatabaseQueue` is already thread-safe.
    private let segmentBatcher: SegmentBatcher

    // MARK: Lifecycle

    public convenience init(path: String) throws {
        try self.init(path: path, segmentBatch: .default)
    }

    /// - Parameter segmentBatch: write-coalescing policy for segments. Tests
    ///   that need a different bound (or none — `.immediate`) pass it here;
    ///   the app always takes the default.
    public init(path: String, segmentBatch: SegmentBatchPolicy) throws {
        dbQueue = try DatabaseQueue(path: path)
        let queue = dbQueue
        segmentBatcher = SegmentBatcher(policy: segmentBatch) { batch in
            // ONE transaction for the whole batch — the point of item 25.
            // `save` keeps the SPEC §4.2 upsert rule per row.
            try queue.write { db in
                for record in batch {
                    try record.save(db)
                }
            }
        }
        try Migrations.migrator.migrate(dbQueue)
        // A store from the FUTURE is not a store this build can use.
        //
        // `DatabaseMigrator` skips migration identifiers it does not know, so
        // a database written by a newer Scribe opens here without a murmur:
        // History lists the meetings, recording works, and every write goes
        // into a schema this build only half understands — new NOT NULL
        // columns are missed, new tables are never maintained, and the newer
        // build's own invariants are quietly broken by the older one. That is
        // the same shape as the in-memory-store fallback the app removed:
        // everything LOOKS fine and the damage is only visible later.
        //
        // `meta.schema_version` exists precisely so this can be checked
        // (SPEC §4.6, "REQUIRED from day one") — until now nothing read it
        // outside tests. Refuse, with a typed error the alert can explain.
        let version = try schemaVersion
        guard version <= Migrations.currentVersion else {
            throw MeetingStoreError.schemaTooNew(found: version, supported: Migrations.currentVersion)
        }
    }

    public static func inMemory() throws -> MeetingStore {
        let store = try MeetingStore(path: ":memory:")
        return store
    }

    /// Last chance for buffered segments: a store going away takes its
    /// unwritten batch with it otherwise. (`deinit` cannot throw; the failure
    /// path inside the batcher has already logged.)
    deinit {
        try? segmentBatcher.flush()
    }

    /// Default on-disk location: ~/Library/Application Support/Scribe/store.sqlite
    public static func openDefault() throws -> MeetingStore {
        try MeetingStore(path: defaultStorePath().path)
    }

    public static func defaultStorePath() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Scribe", isDirectory: true)
        // Best-effort; the caller surfaces errors from init if this failed.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    // MARK: Meta

    public var schemaVersion: Int {
        get throws {
            try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT schema_version FROM meta LIMIT 1") ?? -1
            }
        }
    }

    // MARK: Sessions

    @discardableResult
    public func createSession(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        deviceEvents: [DeviceEvent] = []
    ) throws -> SessionRecord {
        let events = String(data: try JSONEncoder().encode(deviceEvents), encoding: .utf8) ?? "[]"
        let record = SessionRecord(id: id, startedAt: startedAt, deviceEvents: events)
        try dbQueue.write { db in
            try record.insert(db)
        }
        return record
    }

    public func updateSession(_ session: SessionRecord) throws {
        try dbQueue.write { db in
            try session.update(db)
        }
    }

    public func session(id: UUID) throws -> SessionRecord? {
        try dbQueue.read { db in
            try SessionRecord.filter(Column("id") == id).fetchOne(db)
        }
    }

    /// Sessions stuck in `recording` — the crash-recovery scan (SPEC §4.4).
    public func sessionsInState(_ state: SessionState) throws -> [SessionRecord] {
        try dbQueue.read { db in
            try SessionRecord
                .filter(Column("state") == state)
                .order(Column("startedAt").desc)
                .fetchAll(db)
        }
    }

    public func allSessions() throws -> [SessionRecord] {
        try dbQueue.read { db in
            try SessionRecord.order(Column("startedAt").desc).fetchAll(db)
        }
    }

    /// Records why the last fusion attempt failed (SPEC §4.5), on the session
    /// row so the reason survives a relaunch — see
    /// `SessionRecord.fusionErrorMessage`.
    ///
    /// A targeted UPDATE rather than a read-modify-write of the whole record:
    /// fusion is a long call, and the row's `title`/`state` may have been
    /// rewritten by someone else while it ran. Only the two failure columns
    /// are touched. No-op for an unknown id.
    public func recordFusionFailure(sessionId: UUID, message: String, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET fusionErrorMessage = ?, fusionFailedAt = ? WHERE id = ?",
                arguments: [message, date, sessionId]
            )
        }
    }

    /// Clears a recorded fusion failure — a later attempt stored a note, or a
    /// retry is starting, so the stale reason must stop being displayed
    /// (SPEC §4.5 Retry). Targeted UPDATE, for the reason on
    /// `recordFusionFailure`. No-op for an unknown id.
    public func clearFusionFailure(sessionId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sessions SET fusionErrorMessage = NULL, fusionFailedAt = NULL WHERE id = ?",
                arguments: [sessionId]
            )
        }
    }

    public func deleteSession(id: UUID) throws {
        // Flush FIRST: a buffered segment committed after the cascade would
        // resurrect a row for a session that no longer exists.
        try flushSegments()
        _ = try dbQueue.write { db in
            try SessionRecord.filter(Column("id") == id).deleteAll(db)
            try SegmentRecord.filter(Column("sessionId") == id).deleteAll(db)
            try FragmentRecord.filter(Column("sessionId") == id).deleteAll(db)
            try NoteRecord.filter(Column("sessionId") == id).deleteAll(db)
        }
    }

    // MARK: Segments

    /// Upsert on segment id — the hard rule (SPEC §4.2). A revised hypothesis
    /// with the same UUID replaces the row; recovery stays duplicate-free.
    ///
    /// BATCHED (item 25): the row is buffered and committed with the rest of
    /// its batch — after `SegmentBatchPolicy.maxCount` rows or
    /// `maxDelay` seconds, whichever comes first, and always within the
    /// SPEC §4.4 5 s bound. A revision for an id already in the batch
    /// replaces it in the buffer, so the upsert rule holds before the write
    /// as well as at it. `flushSegments()` forces the batch out; reads below
    /// flush first, so nothing can observe a stale transcript through this
    /// store.
    ///
    /// Throws either this call's own commit error or one from a batch that
    /// was committed by the timer with no caller to tell (never silent).
    public func upsertSegment(_ segment: SegmentRecord) throws {
        try segmentBatcher.enqueue(segment)
    }

    /// Commits any buffered segments now. Called before every segment read,
    /// at `deinit`, and available to callers that need disk state to be
    /// current (stop → fusion, export, a kill-test).
    public func flushSegments() throws {
        try segmentBatcher.flush()
    }

    /// True when no segment write is waiting to be committed.
    public var hasPendingSegmentWrites: Bool { !segmentBatcher.isEmpty }

    /// Read-side flush: best effort ON PURPOSE. A read must show the newest
    /// transcript, but it must not FAIL because a write failed — History
    /// showing an empty meeting is worse than History showing what actually
    /// reached disk. A failed batch is logged, stays queued, and is still
    /// re-thrown to the next `upsertSegment`/`flushSegments` caller, so the
    /// failure is surfaced to a writer rather than swallowed.
    private func flushSegmentsBeforeRead() {
        try? segmentBatcher.flush()
    }

    public func segments(sessionId: UUID) throws -> [SegmentRecord] {
        flushSegmentsBeforeRead()
        return try dbQueue.read { db in
            try SegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("startOffset").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    public func segmentCount(sessionId: UUID) throws -> Int {
        flushSegmentsBeforeRead()
        return try dbQueue.read { db in
            try SegmentRecord.filter(Column("sessionId") == sessionId).fetchCount(db)
        }
    }

    // MARK: Fragments

    /// Upsert — used by the pending-row pattern (SPEC §4.3): the same fragment
    /// id is re-saved on every ~1 s debounce until the burst boundary freezes it.
    public func upsertFragment(_ fragment: FragmentRecord) throws {
        try dbQueue.write { db in
            try fragment.save(db)
        }
    }

    public func fragments(sessionId: UUID) throws -> [FragmentRecord] {
        try dbQueue.read { db in
            try FragmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("anchorOffset").asc)
                .fetchAll(db)
        }
    }

    // MARK: Notes

    /// Insert a note and make it canonical in one transaction; previous
    /// attempts are kept, demoted (SPEC §4.6).
    public func insertCanonicalNote(_ note: NoteRecord) throws {
        try dbQueue.write { db in
            var existing = try NoteRecord.filter(Column("sessionId") == note.sessionId).fetchAll(db)
            for i in existing.indices where existing[i].isCanonical {
                existing[i].isCanonical = false
                try existing[i].update(db)
            }
            var canonical = note
            canonical.isCanonical = true
            try canonical.insert(db)
        }
    }

    public func canonicalNote(sessionId: UUID) throws -> NoteRecord? {
        try dbQueue.read { db in
            try NoteRecord
                .filter(Column("sessionId") == sessionId && Column("isCanonical") == true)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }

    public func notes(sessionId: UUID) throws -> [NoteRecord] {
        try dbQueue.read { db in
            try NoteRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("createdAt").desc)
                .fetchAll(db)
        }
    }

    // MARK: Device events

    public func appendDeviceEvent(sessionId: UUID, event: DeviceEvent) throws {
        try dbQueue.write { db in
            guard var session = try SessionRecord.filter(Column("id") == sessionId).fetchOne(db) else {
                return
            }
            var events = session.deviceEventList
            events.append(event)
            session.deviceEvents = String(data: try JSONEncoder().encode(events), encoding: .utf8) ?? session.deviceEvents
            try session.update(db)
        }
    }
}
