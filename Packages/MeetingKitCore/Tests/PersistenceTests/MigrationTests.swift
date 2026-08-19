import Foundation
import GRDB
import XCTest
@testable import Persistence

/// Migrations against REAL, POPULATED stores (SPEC §4.6).
///
/// A migration that works on an empty database proves nothing: the empty case
/// is the one path a fresh install and every other test already takes. The
/// case that loses a user's meetings is the one where the file already has
/// rows in it, written by the previous build, and nobody can re-record them.
///
/// The v1 fixture below is modelled on the owner's actual store
/// (`~/Library/Application Support/Scribe/store.sqlite`, read read-only and
/// never copied): `grdb_migrations` holding only `v1`, `meta.schema_version`
/// = 1, UUID primary keys as 16-byte BLOBs, `DATETIME` columns as UTC text
/// with milliseconds (`2026-08-19 03:00:06.507`), offsets as full-precision
/// doubles, `deviceEvents` as a JSON string.
final class PopulatedMigrationTests: XCTestCase {

    // MARK: - Fixture

    /// Everything the fixture wrote, so the assertions can be exact.
    struct V1Fixture {
        let sessionIds: [UUID]
        let segmentIds: [UUID]
        let fragmentIds: [UUID]
        let noteIds: [UUID]
        let startedAt: [Date]
        let deviceEventsJSON: String
    }

    /// Builds a store containing ONLY the shipped v1 migration, populated the
    /// way a real install would be: several meetings, revised segments,
    /// scratchpad fragments, and two fusion attempts on one session.
    @discardableResult
    private func makeV1Store(at path: String) throws -> V1Fixture {
        let queue = try DatabaseQueue(path: path)
        try Migrations.migrator.migrate(queue, upTo: "v1")

        let sessionIds = (0..<3).map { _ in UUID() }
        let segmentIds = (0..<4).map { _ in UUID() }
        let fragmentIds = (0..<2).map { _ in UUID() }
        let noteIds = (0..<2).map { _ in UUID() }
        // Fixed instants (SPEC §4.6 UTC storage) — no `Date()` anywhere.
        let started = [
            FixedTime.date(2026, 8, 17, 9, 0, 0, nanosecond: 123_000_000, in: FixedTime.ist),
            FixedTime.date(2026, 8, 18, 14, 30, in: FixedTime.ist),
            FixedTime.date(2026, 8, 19, 8, 30, 6, nanosecond: 507_000_000, in: FixedTime.ist),
        ]
        let events = #"[{"kind":"deviceChanged","offset":612,"at":776908806.507}]"#

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO sessions (id, startedAt, endedAt, state, recovered, title, deviceEvents)
                VALUES (?, ?, ?, 'complete', 0, 'Acme renewal call', ?)
                """, arguments: [sessionIds[0], started[0], started[0].addingTimeInterval(2_520), events])
            // A session interrupted by a crash: recovered, no end (SPEC §4.4).
            try db.execute(sql: """
                INSERT INTO sessions (id, startedAt, endedAt, state, recovered, title, deviceEvents)
                VALUES (?, ?, NULL, 'processing', 1, NULL, '[]')
                """, arguments: [sessionIds[1], started[1]])
            try db.execute(sql: """
                INSERT INTO sessions (id, startedAt, endedAt, state, recovered, title, deviceEvents)
                VALUES (?, ?, ?, 'processing', 0, NULL, '[]')
                """, arguments: [sessionIds[2], started[2], started[2].addingTimeInterval(15.378)])

            for (index, id) in segmentIds.enumerated() {
                let sessionIndex = index < 2 ? 0 : (index == 2 ? 1 : 2)
                try db.execute(sql: """
                    INSERT INTO segments (id, sessionId, channel, text, startOffset, endOffset, isFinal, inferredAt, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        id, sessionIds[sessionIndex], index.isMultiple(of: 2) ? "local" : "remote",
                        "segment text \(index)",
                        4.52366412499999 + Double(index) * 10, 7.00366414407348 + Double(index) * 10,
                        index.isMultiple(of: 2), started[sessionIndex], started[sessionIndex],
                    ])
            }
            for (index, id) in fragmentIds.enumerated() {
                try db.execute(sql: """
                    INSERT INTO fragments (id, sessionId, text, anchorOffset, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [id, sessionIds[0], "fragment \(index)", Double(index) * 60 + 12.5, started[0]])
            }
            // Two attempts on one session: the older one demoted (SPEC §4.6).
            try db.execute(sql: """
                INSERT INTO notes (id, sessionId, markdown, model, promptVersion, isCanonical, createdAt)
                VALUES (?, ?, '# First attempt', 'claude-sonnet-5', '1', 0, ?)
                """, arguments: [noteIds[0], sessionIds[0], started[0]])
            try db.execute(sql: """
                INSERT INTO notes (id, sessionId, markdown, model, promptVersion, isCanonical, createdAt)
                VALUES (?, ?, '# Second attempt', 'claude-sonnet-5', '1', 1, ?)
                """, arguments: [noteIds[1], sessionIds[0], started[0].addingTimeInterval(60)])
        }

        return V1Fixture(
            sessionIds: sessionIds, segmentIds: segmentIds, fragmentIds: fragmentIds,
            noteIds: noteIds, startedAt: started, deviceEventsJSON: events
        )
    }

    // MARK: - The fixture is a faithful v1

    /// Guards the "never edit a shipped migration" rule from the other side:
    /// if someone adds the v2 columns to the v1 migration, this fixture stops
    /// being a v1 store and every migration test below silently degrades into
    /// testing nothing.
    func testTheV1MigrationAloneProducesTheOldSchemaWithoutTheFusionColumns() throws {
        let dir = TempStoreDirectory("mig-v1shape")
        try makeV1Store(at: dir.storePath)

        let columns = try RawStore.columns(dir.storePath, "sessions")
        XCTAssertEqual(
            columns,
            ["id", "startedAt", "endedAt", "state", "recovered", "title", "deviceEvents"],
            "v1 is frozen — the real store on disk has exactly these seven columns"
        )
        XCTAssertEqual(try RawStore.appliedMigrations(dir.storePath), ["v1"])
        let version = try DatabaseQueue(path: dir.storePath).read { db in
            try Int.fetchOne(db, sql: "SELECT schema_version FROM meta")
        }
        XCTAssertEqual(version, 1)
    }

    // MARK: - v1 → v2 over rows that already exist

    /// Nothing may be lost, reordered or rewritten. Every session, segment,
    /// fragment and note is compared field by field against what v1 held.
    func testMigratingAPopulatedV1StorePreservesEveryRow() throws {
        let dir = TempStoreDirectory("mig-populated")
        let fixture = try makeV1Store(at: dir.storePath)

        let before = try snapshot(dir.storePath)
        let migrated = try MeetingStore(path: dir.storePath)     // runs v2
        XCTAssertEqual(try migrated.schemaVersion, 2)

        // Counts first — the blunt "did we lose a table" check.
        XCTAssertEqual(try RawStore.count(dir.storePath, "sessions"), 3)
        XCTAssertEqual(try RawStore.count(dir.storePath, "segments"), 4)
        XCTAssertEqual(try RawStore.count(dir.storePath, "fragments"), 2)
        XCTAssertEqual(try RawStore.count(dir.storePath, "notes"), 2)

        // Then every v1 column value, byte for byte.
        XCTAssertEqual(try snapshot(dir.storePath), before,
                       "an additive migration must not rewrite a single pre-existing value")

        // And the same rows read back through the record types.
        let sessions = try migrated.allSessions()
        XCTAssertEqual(Set(sessions.map(\.id)), Set(fixture.sessionIds))
        XCTAssertEqual(sessions.map(\.id), [fixture.sessionIds[2], fixture.sessionIds[1], fixture.sessionIds[0]],
                       "newest first, unchanged by the migration")

        let acme = try XCTUnwrap(try migrated.session(id: fixture.sessionIds[0]))
        XCTAssertEqual(acme.title, "Acme renewal call")
        XCTAssertEqual(acme.state, .complete)
        XCTAssertEqual(acme.startedAt.timeIntervalSince1970, fixture.startedAt[0].timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(acme.endedAt).timeIntervalSince(acme.startedAt), 2_520, accuracy: 0.001)
        XCTAssertEqual(acme.deviceEventList.map(\.kind), ["deviceChanged"], "opaque JSON survives intact")

        let crashed = try XCTUnwrap(try migrated.session(id: fixture.sessionIds[1]))
        XCTAssertNil(crashed.endedAt, "an interrupted session keeps its NULL end")
        XCTAssertTrue(crashed.recovered)

        XCTAssertEqual(try migrated.segmentCount(sessionId: fixture.sessionIds[0]), 2)
        XCTAssertEqual(try migrated.segments(sessionId: fixture.sessionIds[0]).map(\.text),
                       ["segment text 0", "segment text 1"])
        XCTAssertEqual(try migrated.segments(sessionId: fixture.sessionIds[0])[0].startOffset,
                       4.52366412499999, accuracy: 1e-9, "double precision is not truncated")
        XCTAssertEqual(try migrated.fragments(sessionId: fixture.sessionIds[0]).map(\.text),
                       ["fragment 0", "fragment 1"])
        XCTAssertEqual(try migrated.notes(sessionId: fixture.sessionIds[0]).count, 2, "every attempt is kept")
        XCTAssertEqual(try migrated.canonicalNote(sessionId: fixture.sessionIds[0])?.markdown, "# Second attempt")
    }

    /// New columns exist and read as "no failure recorded" for rows written
    /// before they did — which is exactly what those rows mean.
    func testNewColumnsAreAbsentValuesForPreExistingRows() throws {
        let dir = TempStoreDirectory("mig-newcolumns")
        let fixture = try makeV1Store(at: dir.storePath)
        let migrated = try MeetingStore(path: dir.storePath)

        XCTAssertTrue(try RawStore.columns(dir.storePath, "sessions")
            .isSuperset(of: ["fusionErrorMessage", "fusionFailedAt"]))
        for id in fixture.sessionIds {
            let row = try XCTUnwrap(try migrated.session(id: id))
            XCTAssertNil(row.fusionErrorMessage, "pre-existing rows migrate as \"no failure\"")
            XCTAssertNil(row.fusionFailedAt)
        }
        // NULL in the file, not an empty string that would render as a blank
        // error banner in History.
        let nonNull = try RawStore.query(
            dir.storePath,
            "SELECT COUNT(*) AS c FROM sessions WHERE fusionErrorMessage IS NOT NULL OR fusionFailedAt IS NOT NULL"
        ).first?["c"] as Int?
        XCTAssertEqual(nonNull, 0)

        // …and writable afterwards, on a row that predates the column.
        let failedAt = FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist)
        try migrated.recordFusionFailure(sessionId: fixture.sessionIds[1], message: "Anthropic API error", at: failedAt)
        let updated = try XCTUnwrap(try migrated.session(id: fixture.sessionIds[1]))
        XCTAssertEqual(updated.fusionErrorMessage, "Anthropic API error")
        XCTAssertEqual(try XCTUnwrap(updated.fusionFailedAt).timeIntervalSince1970,
                       failedAt.timeIntervalSince1970, accuracy: 0.001)
        // The neighbours stay untouched — an UPDATE with a missing WHERE would
        // stamp the failure on every meeting in History.
        XCTAssertNil(try migrated.session(id: fixture.sessionIds[0])?.fusionErrorMessage)
        XCTAssertNil(try migrated.session(id: fixture.sessionIds[2])?.fusionErrorMessage)
    }

    // MARK: - Idempotence

    /// Every launch runs the migrator. Opening an already-migrated store must
    /// change nothing at all — not the rows, not the schema, not the version.
    func testReMigratingAnAlreadyMigratedStoreIsANoOp() throws {
        let dir = TempStoreDirectory("mig-idempotent")
        try makeV1Store(at: dir.storePath)
        _ = try MeetingStore(path: dir.storePath)                // first launch: v2 applies

        let afterFirst = try snapshot(dir.storePath)
        let columnsAfterFirst = try RawStore.columns(dir.storePath, "sessions")

        for _ in 0..<3 {                                          // three more launches
            let store = try MeetingStore(path: dir.storePath)
            XCTAssertEqual(try store.schemaVersion, 2)
        }

        XCTAssertEqual(try snapshot(dir.storePath), afterFirst, "re-running migrations must not touch rows")
        XCTAssertEqual(try RawStore.columns(dir.storePath, "sessions"), columnsAfterFirst,
                       "a second `ALTER TABLE … ADD COLUMN` would have thrown, not duplicated")
        XCTAssertEqual(try RawStore.appliedMigrations(dir.storePath), ["v1", "v2"],
                       "each migration is recorded exactly once")
    }

    /// `schema_version` is a single row that is UPDATEd. An INSERT here would
    /// leave two rows, and `SELECT … LIMIT 1` would then report whichever one
    /// SQLite felt like — the version check becoming a coin toss.
    func testSchemaVersionIsUpdatedInPlaceAndStaysASingleRow() throws {
        let dir = TempStoreDirectory("mig-meta")
        try makeV1Store(at: dir.storePath)
        _ = try MeetingStore(path: dir.storePath)
        _ = try MeetingStore(path: dir.storePath)

        XCTAssertEqual(try RawStore.count(dir.storePath, "meta"), 1)
        let versions = try DatabaseQueue(path: dir.storePath).read { db in
            try Int.fetchAll(db, sql: "SELECT schema_version FROM meta")
        }
        XCTAssertEqual(versions, [2])
    }

    /// A store created from scratch and a store migrated up from v1 must end
    /// up with the SAME schema — otherwise long-time users and new installs
    /// diverge and only one of them is tested.
    func testMigratedAndFreshStoresConvergeOnTheSameSchema() throws {
        let migratedDir = TempStoreDirectory("mig-converge-old")
        try makeV1Store(at: migratedDir.storePath)
        _ = try MeetingStore(path: migratedDir.storePath)

        let freshDir = TempStoreDirectory("mig-converge-new")
        _ = try MeetingStore(path: freshDir.storePath)

        for table in ["meta", "sessions", "segments", "fragments", "notes"] {
            XCTAssertEqual(
                try RawStore.columns(migratedDir.storePath, table),
                try RawStore.columns(freshDir.storePath, table),
                "\(table) differs between an upgraded store and a fresh one"
            )
        }
        XCTAssertEqual(try RawStore.appliedMigrations(migratedDir.storePath),
                       try RawStore.appliedMigrations(freshDir.storePath))
    }

    // MARK: - Helpers

    /// Every v1 column of every row, ordered deterministically — the
    /// comparison basis for "the migration changed nothing it should not".
    private func snapshot(_ path: String) throws -> [String] {
        let queue = try DatabaseQueue(path: path)
        return try queue.read { db in
            var lines: [String] = []
            for row in try Row.fetchAll(db, sql: """
                SELECT hex(id) AS h, startedAt, endedAt, state, recovered, title, deviceEvents
                FROM sessions ORDER BY h
                """) {
                lines.append("session|\(row)")
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT hex(id) AS h, hex(sessionId) AS hs, channel, text, startOffset, endOffset, isFinal, inferredAt, createdAt
                FROM segments ORDER BY h
                """) {
                lines.append("segment|\(row)")
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT hex(id) AS h, hex(sessionId) AS hs, text, anchorOffset, createdAt
                FROM fragments ORDER BY h
                """) {
                lines.append("fragment|\(row)")
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT hex(id) AS h, hex(sessionId) AS hs, markdown, model, promptVersion, isCanonical, createdAt
                FROM notes ORDER BY h
                """) {
                lines.append("note|\(row)")
            }
            return lines
        }
    }
}
