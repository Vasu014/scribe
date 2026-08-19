import Foundation
import GRDB
import XCTest
@testable import Persistence

/// Dates and time zones (SPEC §4.6).
///
/// # The defect these protect
///
/// The store persists UTC; the History window buckets sessions into
/// "Today"/"Yesterday" and renders local times. In IST (UTC+5:30) that gap is
/// wide enough to be visible: a meeting recorded at 08:30 local is written as
/// `03:00` UTC, and every row looked five and a half hours stale. The bug
/// class is not "the store shows the wrong text" — the store shows no text at
/// all. It is that an INSTANT can be corrupted on the way through SQLite (a
/// local-time string written into a column everything else reads as UTC), and
/// once the instant is wrong every downstream rendering, bucket, sort and
/// duration is wrong with it, consistently enough to look deliberate.
///
/// So these tests assert the thing the store actually owns: the instant
/// survives, byte-exactly and in UTC, and therefore any calendar in any zone
/// reconstructs the same local day, order and elapsed time from it.
///
/// Every date here is built from explicit components in an explicit zone —
/// see `FixedTime`. No test reads `Date()` or `Calendar.current`.
final class StoreDateFidelityTests: XCTestCase {

    // MARK: - What is actually written to the file

    /// The column contract: `DATETIME` columns hold UTC in SQLite's own
    /// `yyyy-MM-dd HH:mm:ss.SSS` text form.
    ///
    /// Asserted against the raw file rather than through `MeetingStore`,
    /// because a store that wrote local time and read local time back would
    /// round-trip perfectly and still be wrong: `sqlite3`, an export, a
    /// backup restored on a machine in another zone, and the next process to
    /// open the file would all disagree with it.
    func testDateColumnsAreWrittenAsUTCText() throws {
        let dir = TempStoreDirectory("date-utc")
        let store = try MeetingStore(path: dir.storePath)

        // 08:30:06.507 IST on 19 Aug 2026 — the real store's shape, and the
        // reading that looked "hours old" because UTC says 03:00.
        let started = FixedTime.date(2026, 8, 19, 8, 30, 6, nanosecond: 507_000_000, in: FixedTime.ist)
        let session = try store.createSession(startedAt: started)

        let raw = try XCTUnwrap(try RawStore.text(
            dir.storePath, "SELECT startedAt FROM sessions WHERE id = ?", [session.id]
        ))
        XCTAssertEqual(raw, "2026-08-19 03:00:06.507",
                       "DATETIME columns are UTC text; a local-time write would read as 08:30")
        XCTAssertEqual(FixedTime.wallClock(started, in: FixedTime.ist), "2026-08-19 8:30 AM",
                       "the same instant is 08:30 to the user — the gap the UI must close")
    }

    /// Millisecond fidelity through GRDB, on every date column the app
    /// persists. Sub-second precision is what keeps two segments finalized in
    /// the same second from collapsing into one ordering key.
    func testEveryDateColumnRoundTripsToTheSameInstant() throws {
        let dir = TempStoreDirectory("date-roundtrip")
        let started = FixedTime.date(2026, 8, 19, 8, 30, 6, nanosecond: 507_000_000, in: FixedTime.ist)
        let ended = FixedTime.date(2026, 8, 19, 9, 12, 43, nanosecond: 885_000_000, in: FixedTime.ist)
        let inferred = FixedTime.date(2026, 8, 19, 8, 30, 14, nanosecond: 538_000_000, in: FixedTime.ist)
        let sessionId = UUID()

        do {
            let store = try MeetingStore(path: dir.storePath)
            var session = try store.createSession(id: sessionId, startedAt: started)
            session.endedAt = ended
            session.state = .complete
            try store.updateSession(session)
            try store.upsertSegment(SegmentRecord(
                sessionId: sessionId, channel: .local, text: "hello",
                startOffset: 4.52366412499999, endOffset: 7.00366414407348,
                isFinal: true, inferredAt: inferred, createdAt: inferred
            ))
            try store.upsertFragment(FragmentRecord(
                sessionId: sessionId, text: "pricing objection", anchorOffset: 612, createdAt: inferred
            ))
            try store.insertCanonicalNote(NoteRecord(
                sessionId: sessionId, markdown: "# n", model: "m", promptVersion: "1", createdAt: ended
            ))
        }

        // A REOPENED store: the decode path a relaunch actually takes.
        let reopened = try MeetingStore(path: dir.storePath)
        let session = try XCTUnwrap(try reopened.session(id: sessionId))
        XCTAssertEqual(session.startedAt.timeIntervalSince1970, started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(session.endedAt).timeIntervalSince1970, ended.timeIntervalSince1970, accuracy: 0.001)

        let segment = try XCTUnwrap(try reopened.segments(sessionId: sessionId).first)
        XCTAssertEqual(segment.inferredAt.timeIntervalSince1970, inferred.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(segment.createdAt.timeIntervalSince1970, inferred.timeIntervalSince1970, accuracy: 0.001)
        // Offsets are session-clock doubles, not dates — full precision.
        XCTAssertEqual(segment.startOffset, 4.52366412499999, accuracy: 1e-9)

        let fragment = try XCTUnwrap(try reopened.fragments(sessionId: sessionId).first)
        XCTAssertEqual(fragment.createdAt.timeIntervalSince1970, inferred.timeIntervalSince1970, accuracy: 0.001)

        let note = try XCTUnwrap(try reopened.canonicalNote(sessionId: sessionId))
        XCTAssertEqual(note.createdAt.timeIntervalSince1970, ended.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - Local day vs UTC day

    /// A meeting at 02:30 IST is "today" to the user and YESTERDAY in UTC.
    /// The row must still bucket as the local day it happened on after the
    /// store has had its hands on it — that is precisely the bucket the
    /// History sidebar draws.
    func testAfterMidnightLocalSessionKeepsItsLocalDayThoughUTCSaysYesterday() throws {
        let dir = TempStoreDirectory("date-localday")
        // 20 Aug 2026, 02:30 IST == 19 Aug 2026, 21:00 UTC.
        let started = FixedTime.date(2026, 8, 20, 2, 30, in: FixedTime.ist)
        let sessionId = UUID()
        do {
            let store = try MeetingStore(path: dir.storePath)
            _ = try store.createSession(id: sessionId, startedAt: started)
        }

        // On disk it is the 19th…
        let raw = try XCTUnwrap(try RawStore.text(
            dir.storePath, "SELECT startedAt FROM sessions WHERE id = ?", [sessionId]
        ))
        XCTAssertTrue(raw.hasPrefix("2026-08-19"), "UTC day is the previous one: \(raw)")

        // …and to the user, after a reopen, it is still the 20th.
        let reopened = try MeetingStore(path: dir.storePath)
        let restored = try XCTUnwrap(try reopened.session(id: sessionId)).startedAt
        XCTAssertEqual(FixedTime.localDay(restored, in: FixedTime.ist).day, 20)
        XCTAssertEqual(FixedTime.localDay(restored, in: FixedTime.utc).day, 19)

        // The bucket the sidebar draws, computed against a FIXED "now" of
        // 09:00 IST the same local morning.
        let now = FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist)
        let istCalendar = FixedTime.calendar(FixedTime.ist)
        XCTAssertTrue(istCalendar.isDate(restored, inSameDayAs: now),
                      "a 02:30 local meeting must bucket as Today, not Yesterday")
        XCTAssertFalse(FixedTime.calendar(FixedTime.utc).isDate(restored, inSameDayAs: now),
                       "…and would bucket as Yesterday if the bucketing ran in UTC")
    }

    /// The mirror image: 23:45 local on the 19th is already the 20th in a
    /// zone east of the writer. The same instant must not gain a day for the
    /// user whose clock says it is still the 19th.
    func testLateEveningLocalSessionDoesNotGainADayThroughTheStore() throws {
        let dir = TempStoreDirectory("date-lateevening")
        // 19 Aug 2026, 23:45 IST == 19 Aug 2026, 18:15 UTC.
        let started = FixedTime.date(2026, 8, 19, 23, 45, in: FixedTime.ist)
        let sessionId = UUID()
        do {
            let store = try MeetingStore(path: dir.storePath)
            _ = try store.createSession(id: sessionId, startedAt: started)
        }
        let restored = try XCTUnwrap(try MeetingStore(path: dir.storePath).session(id: sessionId)).startedAt

        let now = FixedTime.date(2026, 8, 19, 23, 59, in: FixedTime.ist)
        XCTAssertTrue(FixedTime.calendar(FixedTime.ist).isDate(restored, inSameDayAs: now), "still Today")
        XCTAssertEqual(FixedTime.localDay(restored, in: FixedTime.ist).day, 19)
        // Tokyo (UTC+9) already calls this the 20th; the instant is what is
        // shared, the day label is a local reading of it.
        XCTAssertEqual(FixedTime.localDay(restored, in: TimeZone(identifier: "Asia/Tokyo")!).day, 20)
    }

    // MARK: - Ordering

    /// `allSessions()` is the History sidebar's order. Sessions straddling
    /// BOTH a local midnight and a UTC midnight must come back newest-first,
    /// whatever order they were inserted in.
    func testSessionOrderingSurvivesLocalAndUTCDayBoundaries() throws {
        let dir = TempStoreDirectory("date-order")
        let store = try MeetingStore(path: dir.storePath)

        // Local (IST) midnight falls between #2 and #3; UTC midnight falls
        // between #4 and #5. Neither may reorder anything.
        let instants: [(String, Date)] = [
            ("19th 23:50 IST", FixedTime.date(2026, 8, 19, 23, 50, in: FixedTime.ist)),  // 18:20 UTC 19th
            ("19th 23:59 IST", FixedTime.date(2026, 8, 19, 23, 59, in: FixedTime.ist)),  // 18:29 UTC 19th
            ("20th 00:10 IST", FixedTime.date(2026, 8, 20, 0, 10, in: FixedTime.ist)),   // 18:40 UTC 19th
            ("20th 05:20 IST", FixedTime.date(2026, 8, 20, 5, 20, in: FixedTime.ist)),   // 23:50 UTC 19th
            ("20th 05:40 IST", FixedTime.date(2026, 8, 20, 5, 40, in: FixedTime.ist)),   // 00:10 UTC 20th
        ]
        // Inserted deliberately shuffled — insertion order must not matter.
        var ids: [String: UUID] = [:]
        for index in [3, 0, 4, 2, 1] {
            let (label, date) = instants[index]
            ids[label] = try store.createSession(startedAt: date).id
        }

        let ordered = try store.allSessions().map(\.id)
        let expected = instants.reversed().map { ids[$0.0]! }
        XCTAssertEqual(ordered, expected, "newest first, across both midnights")

        // And after a reopen, from the persisted text rather than memory.
        let reopened = try MeetingStore(path: dir.storePath)
        XCTAssertEqual(try reopened.allSessions().map(\.id), expected)
    }

    /// Two sessions 1 ms apart must not collapse into an arbitrary order.
    /// The debounce/finalization paths write bursts of rows inside one second.
    func testMillisecondApartSessionsKeepTheirOrder() throws {
        let dir = TempStoreDirectory("date-millis")
        let store = try MeetingStore(path: dir.storePath)
        let base = FixedTime.date(2026, 8, 20, 9, 0, 0, in: FixedTime.ist)
        let earlier = try store.createSession(startedAt: base)
        let later = try store.createSession(startedAt: base.addingTimeInterval(0.001))

        XCTAssertEqual(try store.allSessions().map(\.id), [later.id, earlier.id])
        XCTAssertEqual(try MeetingStore(path: dir.storePath).allSessions().map(\.id), [later.id, earlier.id])
    }

    // MARK: - DST

    /// Duration is elapsed REAL time, not a difference of wall-clock
    /// readings. Across the US spring-forward the two disagree by an hour:
    /// a meeting from 01:30 to 03:15 local lasted 45 minutes.
    ///
    /// The store's job here is to hand back instants precise enough for that
    /// subtraction to be right; a store that persisted local wall-clock
    /// components would report 1 hr 45 min for a 45-minute meeting.
    func testDurationAcrossSpringForwardIsElapsedRealTimeNotWallClockDifference() throws {
        let dir = TempStoreDirectory("date-dst-spring")
        let zone = FixedTime.newYork
        // 8 Mar 2026: 02:00 EST → 03:00 EDT.
        let started = FixedTime.date(2026, 3, 8, 1, 30, in: zone)   // 06:30 UTC
        let ended = FixedTime.date(2026, 3, 8, 3, 15, in: zone)     // 07:15 UTC
        let sessionId = UUID()
        do {
            let store = try MeetingStore(path: dir.storePath)
            var session = try store.createSession(id: sessionId, startedAt: started)
            session.endedAt = ended
            session.state = .complete
            try store.updateSession(session)
        }

        let restored = try XCTUnwrap(try MeetingStore(path: dir.storePath).session(id: sessionId))
        let elapsed = try XCTUnwrap(restored.endedAt).timeIntervalSince(restored.startedAt)
        XCTAssertEqual(elapsed, 45 * 60, accuracy: 0.001, "45 minutes of real time, not 1 hr 45 min")

        // The wall-clock readings really are 1:45 apart — this is the trap,
        // pinned so nobody "fixes" duration by subtracting the labels.
        let calendar = FixedTime.calendar(zone)
        let naive = calendar.dateComponents([.hour, .minute], from: restored.startedAt, to: restored.endedAt!)
        XCTAssertEqual(naive.hour, 0, "Calendar difference of the same instants is still 45 min")
        XCTAssertEqual(naive.minute, 45)
        XCTAssertEqual(FixedTime.wallClock(restored.startedAt, in: zone), "2026-03-08 1:30 AM")
        XCTAssertEqual(FixedTime.wallClock(restored.endedAt!, in: zone), "2026-03-08 3:15 AM")
    }

    /// Autumn fall-back replays one local hour. Two sessions labelled
    /// "1:30 AM" are an hour apart in reality; the store must keep them
    /// distinct and correctly ordered, or the History list shows two
    /// identical-looking rows in the wrong order.
    func testAmbiguousLocalHourDuringFallBackStaysDistinctAndOrdered() throws {
        let dir = TempStoreDirectory("date-dst-fall")
        let zone = FixedTime.newYork
        // 1 Nov 2026: 02:00 EDT → 01:00 EST. Both instants read "1:30 AM".
        let duringEDT = FixedTime.date(2026, 11, 1, 5, 30, in: FixedTime.utc)
        let duringEST = FixedTime.date(2026, 11, 1, 6, 30, in: FixedTime.utc)
        XCTAssertEqual(FixedTime.wallClock(duringEDT, in: zone), "2026-11-01 1:30 AM")
        XCTAssertEqual(FixedTime.wallClock(duringEST, in: zone), "2026-11-01 1:30 AM",
                       "the same local reading, an hour later — this is the ambiguity")

        let store = try MeetingStore(path: dir.storePath)
        let first = try store.createSession(startedAt: duringEDT)
        let second = try store.createSession(startedAt: duringEST)

        let reopened = try MeetingStore(path: dir.storePath)
        XCTAssertEqual(try reopened.allSessions().map(\.id), [second.id, first.id])
        let restored = try reopened.allSessions()
        XCTAssertEqual(
            restored[0].startedAt.timeIntervalSince(restored[1].startedAt), 3600, accuracy: 0.001,
            "the repeated local hour must not collapse the two instants"
        )
    }

    // MARK: - Interrupted sessions (nil endedAt, SPEC §4.4)

    /// A session killed mid-recording keeps `endedAt == nil` — it is
    /// "unknown", never epoch zero. A 1970 sentinel would sort a crashed
    /// meeting to the bottom of History and render a 56-year duration.
    func testInterruptedSessionKeepsANullEndedAtAndStillSorts() throws {
        let dir = TempStoreDirectory("date-nullend")
        let store = try MeetingStore(path: dir.storePath)

        let older = try store.createSession(startedAt: FixedTime.date(2026, 8, 19, 10, 0, in: FixedTime.ist))
        // Crashed mid-meeting: recovered, still no end (SPEC §4.4).
        var interrupted = try store.createSession(startedAt: FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist))
        interrupted.recovered = true
        interrupted.state = .processing
        try store.updateSession(interrupted)
        let newer = try store.createSession(startedAt: FixedTime.date(2026, 8, 20, 11, 0, in: FixedTime.ist))

        let reopened = try MeetingStore(path: dir.storePath)
        let rows = try reopened.allSessions()
        XCTAssertEqual(rows.map(\.id), [newer.id, interrupted.id, older.id],
                       "a null endedAt must not affect ordering by startedAt")

        let restored = try XCTUnwrap(try reopened.session(id: interrupted.id))
        XCTAssertNil(restored.endedAt, "unknown end stays NULL — never 1970")
        XCTAssertTrue(restored.recovered)
        XCTAssertNil(try RawStore.text(
            dir.storePath, "SELECT endedAt FROM sessions WHERE id = ?", [interrupted.id]
        ), "and NULL in the column, not an empty string")

        // Duration is undefined, and the fallback must be the start instant
        // itself rather than a computed 0 or a negative interval.
        let duration = restored.endedAt.map { $0.timeIntervalSince(restored.startedAt) }
        XCTAssertNil(duration)
        XCTAssertEqual(FixedTime.wallClock(restored.startedAt, in: FixedTime.ist), "2026-08-20 9:00 AM")
    }

    /// A recovered session that is later closed out gets a real end; the
    /// interval must be positive and match the instants exactly.
    func testClosingOutARecoveredSessionProducesAPositiveDuration() throws {
        let dir = TempStoreDirectory("date-recovered-close")
        let store = try MeetingStore(path: dir.storePath)
        let started = FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist)
        var session = try store.createSession(startedAt: started)
        session.recovered = true
        session.endedAt = started.addingTimeInterval(42 * 60)
        session.state = .complete
        try store.updateSession(session)

        let restored = try XCTUnwrap(try MeetingStore(path: dir.storePath).session(id: session.id))
        let elapsed = try XCTUnwrap(restored.endedAt).timeIntervalSince(restored.startedAt)
        XCTAssertEqual(elapsed, 2520, accuracy: 0.001)
        XCTAssertGreaterThan(elapsed, 0)
    }

    /// Device events carry their own `at` timestamps inside JSON, which is a
    /// different encoder (JSONEncoder, seconds-since-2001 doubles) from the
    /// column path. It must agree with the columns about what an instant is.
    func testDeviceEventTimestampsAgreeWithTheColumnEncoding() throws {
        let dir = TempStoreDirectory("date-events")
        let store = try MeetingStore(path: dir.storePath)
        let started = FixedTime.date(2026, 8, 20, 9, 0, in: FixedTime.ist)
        let wakeAt = FixedTime.date(2026, 8, 20, 9, 10, 12, in: FixedTime.ist)
        let session = try store.createSession(startedAt: started)
        try store.appendDeviceEvent(
            sessionId: session.id, event: DeviceEvent(kind: "wake", offset: 612, at: wakeAt)
        )

        let restored = try XCTUnwrap(try MeetingStore(path: dir.storePath).session(id: session.id))
        let event = try XCTUnwrap(restored.deviceEventList.first)
        XCTAssertEqual(event.at.timeIntervalSince1970, wakeAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            event.at.timeIntervalSince(restored.startedAt), 612, accuracy: 0.001,
            "the JSON timestamp and the column must place the event at the same session offset"
        )
    }
}
