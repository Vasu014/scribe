import GRDB
import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {

    private func makeStore() throws -> MeetingStore {
        try MeetingStore.inMemory()
    }

    // MARK: Schema

    func testSchemaVersionIsTwo() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.schemaVersion, 2)
    }

    /// The v2 migration must run on a store created at v1 and leave every
    /// existing row intact, with the new columns reading as "no failure".
    /// This is the shape of the owner's real store on disk.
    func testV2MigrationIsAdditiveOnAnExistingV1Store() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path

        // A v1 store, built with ONLY the v1 migration — no new columns.
        let sessionId = UUID()
        do {
            let queue = try DatabaseQueue(path: path)
            try Migrations.migrator.migrate(queue, upTo: "v1")
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO sessions (id, startedAt, endedAt, state, recovered, title, deviceEvents)
                        VALUES (?, ?, ?, 'processing', 0, NULL, '[]')
                        """,
                    arguments: [sessionId, Date(timeIntervalSince1970: 1_000), Date(timeIntervalSince1970: 1_060)]
                )
            }
        }

        // Reopening through MeetingStore runs v2 against the populated file.
        let migrated = try MeetingStore(path: path)
        XCTAssertEqual(try migrated.schemaVersion, 2)
        let row = try XCTUnwrap(try migrated.session(id: sessionId))
        XCTAssertEqual(row.state, .processing, "pre-existing row survives the migration")
        XCTAssertNil(row.fusionErrorMessage, "existing rows migrate as \"no failure recorded\"")
        XCTAssertNil(row.fusionFailedAt)

        // And the new columns are writable on that pre-existing row.
        try migrated.recordFusionFailure(sessionId: sessionId, message: "No Anthropic API key is saved.")
        XCTAssertEqual(
            try migrated.session(id: sessionId)?.fusionErrorMessage,
            "No Anthropic API key is saved."
        )
    }

    // MARK: Fusion failure persistence (SPEC §4.5)

    /// The bug this exists for: the reason a session failed used to live only
    /// in the History window's memory, so a relaunch showed a permanently
    /// failed session as an eternal "fusing" spinner. It must round-trip
    /// through a CLOSED-and-reopened store.
    func testFusionFailureRoundTripsAcrossStoreReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path

        let message = "No Anthropic API key is saved. Add one in Settings, then retry."
        let failedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let sessionId: UUID
        do {
            let store = try MeetingStore(path: path)
            var session = try store.createSession()
            session.state = .processing
            session.endedAt = Date()
            try store.updateSession(session)
            try store.recordFusionFailure(sessionId: session.id, message: message, at: failedAt)
            sessionId = session.id
        }

        let reopened = try MeetingStore(path: path)
        let row = try XCTUnwrap(try reopened.session(id: sessionId))
        XCTAssertEqual(row.state, .processing, "SPEC §4.5: a failure leaves the session in processing")
        XCTAssertEqual(row.fusionErrorMessage, message)
        XCTAssertEqual(row.fusionFailedAt?.timeIntervalSince1970 ?? 0, failedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testClearFusionFailureRemovesBothColumns() throws {
        let store = try makeStore()
        let session = try store.createSession()
        try store.recordFusionFailure(sessionId: session.id, message: "network down")
        XCTAssertNotNil(try store.session(id: session.id)?.fusionErrorMessage)

        try store.clearFusionFailure(sessionId: session.id)
        let row = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertNil(row.fusionErrorMessage)
        XCTAssertNil(row.fusionFailedAt)
    }

    /// Targeted UPDATE, not read-modify-write: recording a failure must not
    /// roll back a title or state someone else wrote while fusion ran.
    func testRecordFusionFailureTouchesOnlyTheFailureColumns() throws {
        let store = try makeStore()
        var session = try store.createSession()
        session.title = "Acme renewal call"
        session.state = .processing
        try store.updateSession(session)

        try store.recordFusionFailure(sessionId: session.id, message: "the provider timed out")

        let row = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(row.title, "Acme renewal call")
        XCTAssertEqual(row.state, .processing)
        XCTAssertEqual(row.fusionErrorMessage, "the provider timed out")
    }

    // MARK: Segment upsert (Spike 3 core proof, SPEC §4.2)

    func testSegmentUpsertReplacesNotAppends() throws {
        let store = try makeStore()
        let session = try store.createSession()
        let id = UUID()

        try store.upsertSegment(SegmentRecord(
            id: id, sessionId: session.id, channel: .remote,
            text: "so we should deferring the migration", startOffset: 10, endOffset: 14
        ))
        try store.upsertSegment(SegmentRecord(
            id: id, sessionId: session.id, channel: .remote,
            text: "so we should defer the migration", startOffset: 10, endOffset: 14, isFinal: true
        ))

        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 1, "revised hypothesis must replace, not append")
        let segments = try store.segments(sessionId: session.id)
        XCTAssertEqual(segments[0].text, "so we should defer the migration")
        XCTAssertTrue(segments[0].isFinal)
    }

    func testDistinctSegmentsCoexist() throws {
        let store = try makeStore()
        let session = try store.createSession()
        try store.upsertSegment(SegmentRecord(id: UUID(), sessionId: session.id, channel: .local, text: "a", startOffset: 0, endOffset: 1))
        try store.upsertSegment(SegmentRecord(id: UUID(), sessionId: session.id, channel: .remote, text: "b", startOffset: 1, endOffset: 2))
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 2)
    }

    // MARK: Crash-recovery durability (kill -9 simulation)

    /// The kill-test: a second connection on the same file must see every
    /// committed row without the first connection closing (WAL durability).
    func testCommittedRowsSurviveWithoutClose() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path

        let crashed = try MeetingStore(path: path)   // never closed — simulates kill -9
        let session = try crashed.createSession()
        let segmentId = UUID()                        // stable id across hypothesis revisions
        try crashed.upsertSegment(SegmentRecord(id: segmentId, sessionId: session.id, channel: .remote, text: "hello", startOffset: 0, endOffset: 2))
        try crashed.upsertSegment(SegmentRecord(id: segmentId, sessionId: session.id, channel: .remote, text: "hello", startOffset: 0, endOffset: 2, isFinal: true))

        let reopened = try MeetingStore(path: path)  // recovery path
        XCTAssertEqual(try reopened.schemaVersion, 2)
        XCTAssertEqual(try reopened.segmentCount(sessionId: session.id), 1)
        XCTAssertEqual(try reopened.segments(sessionId: session.id)[0].text, "hello")
    }

    // MARK: Crash-recovery scan (SPEC §4.4)

    func testRecordingScanFindsStuckSessions() throws {
        let store = try makeStore()
        let stuck = try store.createSession()
        var processing = try store.createSession()   // processing is NOT stuck
        processing.state = .processing
        try store.updateSession(processing)
        var complete = try store.createSession()
        complete.state = .complete
        complete.endedAt = Date()
        try store.updateSession(complete)

        let stuckSessions = try store.sessionsInState(.recording)
        XCTAssertEqual(stuckSessions.map(\.id), [stuck.id])
    }

    // MARK: Fragments (pending-row, SPEC §4.3)

    func testFragmentPendingRowUpsert() throws {
        let store = try makeStore()
        let session = try store.createSession()
        let id = UUID()

        try store.upsertFragment(FragmentRecord(id: id, sessionId: session.id, text: "pricing obj", anchorOffset: 100))
        try store.upsertFragment(FragmentRecord(id: id, sessionId: session.id, text: "pricing objection — follow up", anchorOffset: 100))

        let fragments = try store.fragments(sessionId: session.id)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].text, "pricing objection — follow up")
        XCTAssertEqual(fragments[0].anchorOffset, 100, "anchor is burst start; lookback is fusion-time only")
    }

    // MARK: Notes

    func testCanonicalNoteRotationKeepsHistory() throws {
        let store = try makeStore()
        let session = try store.createSession()

        try store.insertCanonicalNote(NoteRecord(sessionId: session.id, markdown: "# Bad notes", model: "m", promptVersion: "p1"))
        try store.insertCanonicalNote(NoteRecord(sessionId: session.id, markdown: "# Good notes", model: "m", promptVersion: "p2"))

        let all = try store.notes(sessionId: session.id)
        XCTAssertEqual(all.count, 2, "all fusion attempts are kept")
        XCTAssertEqual(try store.canonicalNote(sessionId: session.id)?.markdown, "# Good notes")
        XCTAssertEqual(all.filter(\.isCanonical).count, 1)
    }

    // MARK: Device events

    func testDeviceEventsAppend() throws {
        let store = try makeStore()
        let session = try store.createSession()
        try store.appendDeviceEvent(sessionId: session.id, event: DeviceEvent(kind: "deviceChanged", offset: 612))
        try store.appendDeviceEvent(sessionId: session.id, event: DeviceEvent(kind: "wake", offset: 900))

        let updated = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(updated.deviceEventList.map(\.kind), ["deviceChanged", "wake"])
        XCTAssertEqual(updated.deviceEventList[0].offset, 612)
    }

    // MARK: Delete

    func testDeleteSessionCascadesManually() throws {
        let store = try makeStore()
        let session = try store.createSession()
        try store.upsertSegment(SegmentRecord(id: UUID(), sessionId: session.id, channel: .local, text: "a", startOffset: 0, endOffset: 1))
        try store.upsertFragment(FragmentRecord(id: UUID(), sessionId: session.id, text: "n", anchorOffset: 5))
        try store.insertCanonicalNote(NoteRecord(sessionId: session.id, markdown: "m", model: "m", promptVersion: "p"))

        try store.deleteSession(id: session.id)

        XCTAssertNil(try store.session(id: session.id))
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 0)
        XCTAssertTrue(try store.fragments(sessionId: session.id).isEmpty)
        XCTAssertTrue(try store.notes(sessionId: session.id).isEmpty)
    }
}
