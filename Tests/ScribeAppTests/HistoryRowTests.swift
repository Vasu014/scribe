import AppKit
import Persistence
import XCTest

/// History's sidebar rows and meta text (design 1d; SPEC §5). Storage states
/// stay `recording | processing | complete`; everything the user reads is
/// derived at display time, which is where it has gone wrong.
@MainActor
final class HistoryRowTests: XCTestCase {

    private func session(
        state: SessionState = .complete,
        recovered: Bool = false,
        title: String? = nil,
        minutes: Double? = 10
    ) -> SessionRecord {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        return SessionRecord(
            id: UUID(),
            startedAt: started,
            endedAt: minutes.map { started.addingTimeInterval($0 * 60) },
            state: state,
            recovered: recovered,
            title: title
        )
    }

    // MARK: Row state derivation

    func testRecordingAndCompleteMapDirectly() {
        XCTAssertEqual(HistoryRow.state(storage: .recording, failureMessage: nil, hasStoredNote: false), .recording)
        XCTAssertEqual(HistoryRow.state(storage: .complete, failureMessage: nil, hasStoredNote: true), .fused)
    }

    /// `processing` is the ambiguous one: still fusing, fused-with-findings,
    /// or failed permanently. It carries all three, and telling them apart is
    /// the whole job.
    func testProcessingSplitsThreeWays() {
        XCTAssertEqual(
            HistoryRow.state(storage: .processing, failureMessage: nil, hasStoredNote: false), .fusing
        )
        // Fusion succeeded but the validator raised findings — a note IS
        // stored, so this row is fused (Retry stays available separately).
        XCTAssertEqual(
            HistoryRow.state(storage: .processing, failureMessage: nil, hasStoredNote: true), .fused
        )
        XCTAssertEqual(
            HistoryRow.state(storage: .processing, failureMessage: "No Anthropic API key is saved.", hasStoredNote: false),
            .failed
        )
    }

    /// The regression that shipped: the failure reason lived only in memory,
    /// so after a relaunch a permanently-failed meeting came back as "fusing"
    /// with a live spinner and a 1 Hz poll, forever. A row with a failure
    /// message is FAILED — never fusing — whichever source it came from.
    func testAFailureMessageAlwaysBeatsTheFusingSpinner() {
        let failed = HistoryRow.state(
            storage: .processing, failureMessage: "The request timed out.", hasStoredNote: false
        )
        XCTAssertEqual(failed, .failed)
        XCTAssertNotEqual(failed, .fusing, "a failed session must never render a spinner that will never stop")
        XCTAssertEqual(HistoryRow.meta(for: failed, duration: "10 min"), "failed")
    }

    /// Only the failure state gets the red meta colour; a spinner row must
    /// not read as an error.
    func testOnlyFailedRowsAreRed() {
        XCTAssertNotEqual(HistoryMeta.failureColor, NSColor.secondaryLabelColor)
    }

    // MARK: Meta column

    /// The meta slot is a duration for a fused row and a status word for
    /// every other — a fused row is the only one whose length is settled.
    func testMetaTextPerRowState() {
        XCTAssertEqual(HistoryRow.meta(for: .fused, duration: "42 min"), "42 min")
        XCTAssertEqual(HistoryRow.meta(for: .recording, duration: "42 min"), "recording")
        XCTAssertEqual(HistoryRow.meta(for: .fusing, duration: "42 min"), "fusing")
        XCTAssertEqual(HistoryRow.meta(for: .failed, duration: "42 min"), "failed")
    }

    /// A recovered session keeps a nil `endedAt` on purpose (SPEC §4.4) — an
    /// invented end would lie. The column is empty, not "0 min".
    func testAFusedRowWithNoEndShowsNoDuration() {
        XCTAssertEqual(HistoryRow.meta(for: .fused, duration: nil), "")
    }

    // MARK: Titles — the duplicated-date regression

    /// The sidebar row already prints the date on its second line and the
    /// duration in its own column, so the SPEC §4.5 date/duration fallback
    /// rendered as "Nov 14, 2023, 3:33 PM · 10 min" stacked directly on top
    /// of "Nov 14, 2023, 3:33 PM".
    func testUntitledRowTitleDoesNotRepeatTheRowsOwnDate() {
        let record = session(title: nil)
        let title = HistoryRow.title(record)
        let dateLine = HistoryMeta.dateAndTime(record.startedAt)

        XCTAssertEqual(title, "Untitled meeting")
        XCTAssertFalse(title.contains(dateLine), "the row title repeats the date line below it")
        XCTAssertFalse(title.contains("·"), "the row title repeats the duration column beside it")
        XCTAssertNotEqual(title, HistoryMeta.fallbackTitle(record))
    }

    /// An empty string is as untitled as nil — fusion can return "".
    func testEmptyTitleIsTreatedAsUntitled() {
        XCTAssertEqual(HistoryRow.title(session(title: "")), "Untitled meeting")
        XCTAssertEqual(HistoryRow.title(session(title: "  Q3 planning  ")), "  Q3 planning  ")
    }

    func testATitledRowShowsItsTitle() {
        XCTAssertEqual(HistoryRow.title(session(title: "Q3 planning")), "Q3 planning")
    }

    /// The DETAIL pane has no date line and no duration column, so it keeps
    /// the spec'd date/duration fallback. The two must stay different — if
    /// they converge, one of the two surfaces is wrong again.
    func testDetailPaneFallbackStillCarriesDateAndDuration() {
        let record = session(title: nil, minutes: 42)
        let fallback = HistoryMeta.fallbackTitle(record)
        XCTAssertTrue(fallback.hasPrefix(HistoryMeta.dateAndTime(record.startedAt)), fallback)
        XCTAssertTrue(fallback.hasSuffix("42 min"), fallback)
        XCTAssertNotEqual(fallback, HistoryRow.title(record))
    }

    /// A recovered session has no end, so the detail fallback is date only —
    /// not "date · 0 min".
    func testDetailFallbackForARecoveredSessionIsDateOnly() {
        let record = session(state: .processing, recovered: true, minutes: nil)
        XCTAssertEqual(HistoryMeta.fallbackTitle(record), HistoryMeta.dateAndTime(record.startedAt))
        XCTAssertFalse(HistoryMeta.fallbackTitle(record).contains("min"))
    }

    // MARK: Durations

    func testDurationRoundsToWholeMinutesWithAFloorOfOne() {
        // "recorded for 12 seconds" is still a meeting; 0 min reads as a bug.
        XCTAssertEqual(HistoryMeta.duration(0), "1 min")
        XCTAssertEqual(HistoryMeta.duration(12), "1 min")
        XCTAssertEqual(HistoryMeta.duration(89), "1 min")
        XCTAssertEqual(HistoryMeta.duration(91), "2 min")
        XCTAssertEqual(HistoryMeta.duration(2_520), "42 min")
    }

    func testDurationRollsOverToHours() {
        XCTAssertEqual(HistoryMeta.duration(3_540), "59 min")
        XCTAssertEqual(HistoryMeta.duration(3_600), "1 hr")
        XCTAssertEqual(HistoryMeta.duration(3_900), "1 hr 5 min")
        XCTAssertEqual(HistoryMeta.duration(7_200), "2 hr")
        XCTAssertEqual(HistoryMeta.duration(9_000), "2 hr 30 min")
    }

    // MARK: Time ranges

    /// Wall-clock times in the RUNNING calendar — "start + 20 h" is not
    /// reliably the next day, and these formats are local-time formats.
    private func localTime(hour: Int, minute: Int, dayOffset: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let shifted = calendar.date(byAdding: .day, value: dayOffset, to: day)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: shifted)!
    }

    /// Same-day meetings collapse to one meridiem — "9:00–9:42 AM".
    func testSameDayRangeCollapsesTheMeridiem() {
        let range = HistoryMeta.timeRange(
            start: localTime(hour: 9, minute: 0), end: localTime(hour: 9, minute: 42)
        )
        XCTAssertTrue(range.contains("9:00–9:42"), range)
        XCTAssertEqual(range.components(separatedBy: "M").count - 1, 1, "the meridiem is printed twice: \(range)")
    }

    /// A recovered session has no end and a session can cross midnight; both
    /// fall back to the start stamp rather than inventing or mis-joining one.
    /// A joined range across midnight reads as a meeting that ran backwards.
    func testUnknownOrCrossMidnightEndFallsBackToTheStart() {
        let start = localTime(hour: 23, minute: 30)
        XCTAssertEqual(HistoryMeta.timeRange(start: start, end: nil), HistoryMeta.dateAndTime(start))

        let afterMidnight = localTime(hour: 0, minute: 15, dayOffset: 1)
        XCTAssertEqual(
            HistoryMeta.timeRange(start: start, end: afterMidnight), HistoryMeta.dateAndTime(start)
        )
    }

    func testTodayAndYesterdayAreNamedNotDated() {
        XCTAssertTrue(HistoryMeta.dateAndTime(Date()).hasPrefix("Today, "))
        XCTAssertTrue(HistoryMeta.dateAndTime(Date().addingTimeInterval(-86_400)).hasPrefix("Yesterday, "))
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(HistoryMeta.dateAndTime(old).hasPrefix("Today"))
        XCTAssertFalse(HistoryMeta.dateAndTime(old).hasPrefix("Yesterday"))
    }

    // MARK: Export filenames

    /// Fused titles are model output and go straight into a save panel's
    /// filename field. A "/" in one is a new directory component.
    func testExportFilenamesAreFilesystemSafe() {
        let name = HistoryWindowController.fileName(for: "Q3 / Q4: planning?", extension: "md")
        XCTAssertFalse(name.dropLast(3).contains("/"), name)
        XCTAssertFalse(name.contains(":"), name)
        XCTAssertFalse(name.contains("?"), name)
        XCTAssertTrue(name.hasSuffix(".md"), name)
    }

    func testExportFilenamesAreBoundedAndNeverEmpty() {
        let long = HistoryWindowController.fileName(for: String(repeating: "a", count: 400), extension: "json")
        XCTAssertEqual(long.count, 60 + ".json".count)
        XCTAssertEqual(HistoryWindowController.fileName(for: "", extension: "md"), "Session.md")
        XCTAssertEqual(HistoryWindowController.fileName(for: "///", extension: "md"), "Session.md")
        XCTAssertEqual(HistoryWindowController.fileName(for: "  \n ", extension: "md"), "Session.md")
    }
}
