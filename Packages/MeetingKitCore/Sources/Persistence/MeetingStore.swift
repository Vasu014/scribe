import Foundation
import GRDB

/// The store. All components write to / read from it — nothing calls anything
/// else across module boundaries (SPEC §3.1 architectural rule).
///
/// WAL mode (GRDB default for on-disk queues) is what makes the crash-recovery
/// guarantee cheap: committed rows survive kill -9 without a clean close.
public final class MeetingStore: Sendable {
    private let dbQueue: DatabaseQueue

    // MARK: Lifecycle

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Migrations.migrator.migrate(dbQueue)
    }

    public static func inMemory() throws -> MeetingStore {
        let store = try MeetingStore(path: ":memory:")
        return store
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
    public func upsertSegment(_ segment: SegmentRecord) throws {
        try dbQueue.write { db in
            try segment.save(db)
        }
    }

    public func segments(sessionId: UUID) throws -> [SegmentRecord] {
        try dbQueue.read { db in
            try SegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("startOffset").asc, Column("id").asc)
                .fetchAll(db)
        }
    }

    public func segmentCount(sessionId: UUID) throws -> Int {
        try dbQueue.read { db in
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
