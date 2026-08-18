import XCTest
@testable import Persistence

final class PersistenceTests: XCTestCase {

    private func makeStore() throws -> MeetingStore {
        try MeetingStore.inMemory()
    }

    // MARK: Schema

    func testSchemaVersionIsOne() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.schemaVersion, 1)
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
        XCTAssertEqual(try reopened.schemaVersion, 1)
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
