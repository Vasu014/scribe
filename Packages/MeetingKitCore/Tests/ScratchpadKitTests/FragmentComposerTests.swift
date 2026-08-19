import XCTest
@testable import ScratchpadKit

final class FragmentComposerTests: XCTestCase {

    func testBurstFreezesAfterThreeSecondPause() {
        var persisted: [(String, TimeInterval)] = []
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("pricing objection", at: 100.0)   // burst start → anchor 100
        composer.heartbeat(at: 100.2)
        composer.heartbeat(at: 101.1)                    // trailing persist (~1 s debounce)
        composer.heartbeat(at: 103.1)                    // ≥3 s since last edit → freeze

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "pricing objection")
        XCTAssertEqual(frozen[0].1, 100.0, "anchor is burst start")
        XCTAssertFalse(persisted.isEmpty, "pending row must have been persisted before freeze")
    }

    func testNewlineFreezesImmediately() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("ask legal about DPA", at: 200.0)
        composer.edit("ask legal about DPA now", at: 200.4)
        composer.newline(at: 200.5)

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "ask legal about DPA now")
        XCTAssertEqual(frozen[0].1, 200.0)
    }

    func testDebouncePersistsAtMostOncePerSecond() {
        var persisted: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }

        composer.edit("a", at: 300.0)
        composer.edit("ab", at: 300.2)
        composer.edit("abc", at: 300.4)
        composer.edit("abcd", at: 300.6)

        // First edit persists immediately (no prior persist); the rest are
        // within the debounce window and wait for the heartbeat.
        XCTAssertEqual(persisted.count, 1)
        composer.heartbeat(at: 301.7)   // ≥1 s after last edit (300.6)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.last?.0, "abcd", "pending row must reflect the latest text")
    }

    func testAnchorResetsBetweenBursts() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("first", at: 400.0)
        composer.newline(at: 400.2)
        composer.edit("second", at: 405.0)              // new burst → new anchor
        composer.newline(at: 405.1)

        XCTAssertEqual(frozen.map(\.1), [400.0, 405.0])
    }

    func testEmptyAndWhitespaceTextIgnored() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("   ", at: 500.0)
        composer.heartbeat(at: 504.0)

        XCTAssertTrue(frozen.isEmpty, "whitespace-only input must not create a fragment")
    }

    func testFlushFreezesPendingBurstAtSessionStop() {
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("last thought", at: 600.0)
        composer.flush(at: 600.5)

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "last thought")
    }

    // MARK: Deletion (SPEC §4.3 — deleted text is text the user decided not to
    // keep: it must never freeze into a fragment or survive in the store).

    /// Audit repro (audit-data-fusion #6): type, backspace, select-all +
    /// delete, then let the burst boundary pass. Before the fix this froze
    /// "wrong not" into a committed fragment.
    func testClearingPendingTextDiscardsTheBurst() {
        var persisted: [(String, TimeInterval)] = []
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("wrong note", at: 10.0)
        composer.edit("wrong not", at: 10.5)
        let writesBeforeDelete = persisted.count
        composer.edit("", at: 11.0)              // select-all + delete
        composer.heartbeat(at: 11.1)
        composer.heartbeat(at: 12.1)
        composer.heartbeat(at: 15.0)             // well past the 3 s boundary

        XCTAssertTrue(frozen.isEmpty, "deleted text must not become a fragment")
        XCTAssertEqual(discarded, [10.0], "the pending row for the burst must be removed")
        XCTAssertEqual(
            persisted.count, writesBeforeDelete,
            "no further persist may carry the deleted text after the discard"
        )
        XCTAssertFalse(
            persisted.contains { $0.0 == "wrong not" },
            "the never-persisted revision must never reach the store"
        )
    }

    /// With no delete hook wired (today's app), the composer still erases the
    /// row's text through the existing pending-row upsert.
    func testClearingBlanksThePendingRowWhenNoDiscardHookIsWired() {
        var persisted: [(String, TimeInterval)] = []
        var frozen: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }

        composer.edit("nda concerns", at: 20.0)
        composer.edit("", at: 20.6)
        composer.heartbeat(at: 24.0)

        XCTAssertTrue(frozen.isEmpty)
        XCTAssertEqual(persisted.last?.0, "", "the stored row must not keep the deleted text")
        XCTAssertEqual(persisted.last?.1, 20.0, "blanking targets the same burst row")
    }

    /// Whitespace left behind by a delete is still a delete.
    func testWhitespaceOnlyAfterTypingDiscardsTheBurst() {
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("check the SLA", at: 30.0)
        composer.edit("   \n  ", at: 30.4)
        composer.heartbeat(at: 34.0)

        XCTAssertTrue(frozen.isEmpty)
        XCTAssertEqual(discarded, [30.0])
    }

    /// Deleting only PART of the pending text keeps the burst alive and
    /// commits exactly what is left — never the deleted tail.
    func testPartialDeletionCommitsOnlyTheRemainingText() {
        var persisted: [(String, TimeInterval)] = []
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("pricing objection from legal", at: 40.0)
        composer.edit("pricing objection", at: 40.8)   // deleted the tail
        composer.heartbeat(at: 41.9)                   // trailing persist
        composer.heartbeat(at: 43.9)                   // ≥3 s pause → freeze

        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "pricing objection")
        XCTAssertEqual(frozen[0].1, 40.0, "anchor is still the burst start")
        XCTAssertTrue(discarded.isEmpty, "a partial delete is not a discard")
        XCTAssertEqual(persisted.last?.0, "pricing objection", "row reflects the surviving text")
    }

    /// Clear, then type again: a fresh burst with a fresh anchor, and the
    /// discarded text is nowhere in it.
    func testRetypingAfterAClearStartsANewBurst() {
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("scratch that", at: 50.0)
        composer.edit("", at: 50.5)
        composer.edit("real note", at: 52.0)
        composer.newline(at: 52.2)

        XCTAssertEqual(discarded, [50.0])
        XCTAssertEqual(frozen.count, 1)
        XCTAssertEqual(frozen[0].0, "real note")
        XCTAssertEqual(frozen[0].1, 52.0, "the new burst anchors at its own start")
    }

    /// A fragment already frozen by a boundary is committed and immutable
    /// (SPEC §4.3): a later empty body is a new empty burst, not a retraction.
    func testDeletingAfterAFreezeDoesNotTouchTheCommittedFragment() {
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        var persisted: [(String, TimeInterval)] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("keep this one", at: 60.0)
        composer.heartbeat(at: 61.1)
        composer.heartbeat(at: 63.1)              // freeze
        XCTAssertEqual(frozen.count, 1)

        let persistCount = persisted.count
        composer.edit("", at: 64.0)               // user clears the (already cleared) body
        composer.heartbeat(at: 68.0)

        XCTAssertEqual(frozen.map(\.0), ["keep this one"], "committed fragment is untouched")
        XCTAssertTrue(discarded.isEmpty, "no pending row exists to discard")
        XCTAssertEqual(persisted.count, persistCount, "no store traffic after the freeze")
    }

    /// Session stop while a deletion is still inside the debounce window:
    /// flush must commit nothing.
    func testFlushAfterDeletionCommitsNothing() {
        var frozen: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onFreeze = { frozen.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("half typed thought", at: 70.0)
        composer.edit("", at: 70.4)               // deleted mid-debounce
        composer.flush(at: 70.6)                  // Stop pressed

        XCTAssertEqual(discarded, [70.0])
        XCTAssertTrue(frozen.isEmpty, "a deleted burst must not be flushed into a fragment")
    }

    /// Typed and deleted entirely inside the debounce window: nothing ever
    /// reached the store, so there is nothing to remove.
    func testDeletionBeforeAnyPersistEmitsNoStoreTraffic() {
        var persisted: [(String, TimeInterval)] = []
        var discarded: [TimeInterval] = []
        let composer = FragmentComposer()
        composer.onPersistPending = { persisted.append(($0, $1)) }
        composer.onDiscardPending = { discarded.append($0) }

        composer.edit("first", at: 80.0)
        composer.newline(at: 80.1)                // burst 1 committed
        let after = persisted.count

        composer.edit("oops", at: 80.3)           // inside the 1 s debounce → no persist
        composer.edit("", at: 80.6)

        XCTAssertEqual(persisted.count, after, "nothing was written for the second burst")
        XCTAssertTrue(discarded.isEmpty, "no row was written, so no row is discarded")
    }
}
