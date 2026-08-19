import XCTest
@testable import ScratchpadKit

/// Fragment lifecycle edges (SPEC §4.3).
///
/// `FragmentComposerTests` covers the ordinary paths and the deletion repro.
/// These are the boundary races — the moments where a deletion and a burst
/// boundary land in the same instant, and where a session ends while text is
/// still in flight.
///
/// The stake is privacy, not just correctness. The scratchpad is the user's
/// ephemeral space: text they delete is text they decided not to keep, and a
/// committed fragment is sent to a frontier model. A single deleted phrase
/// that survives one of these races leaves the machine. So the assertions
/// below are not only "the right thing was committed" but "the deleted words
/// appear in NO callback payload at all".
final class FragmentLifecycleEdgeTests: XCTestCase {

    /// Records every payload the composer ever emits, so a test can ask the
    /// one question that matters: did these words leave the composer?
    private final class Recorder {
        var persisted: [(text: String, anchor: TimeInterval)] = []
        var frozen: [(text: String, anchor: TimeInterval)] = []
        var discarded: [TimeInterval] = []

        /// Everything the composer has ever emitted as text.
        var allEmittedText: [String] { persisted.map(\.text) + frozen.map(\.text) }

        func sawAnyText(containing needle: String) -> Bool {
            allEmittedText.contains { $0.localizedCaseInsensitiveContains(needle) }
        }

        private var checkpoint = (persisted: 0, frozen: 0)

        /// Marks "now" — the moment of the deletion. Writes BEFORE this are
        /// legitimate (the pending row genuinely held the text while the user
        /// was typing it); the discard is what removes them from the store.
        /// What must never happen is a write AFTER it.
        func mark() {
            checkpoint = (persisted.count, frozen.count)
        }

        var textEmittedSinceMark: [String] {
            persisted.dropFirst(checkpoint.persisted).map(\.text)
                + frozen.dropFirst(checkpoint.frozen).map(\.text)
        }

        func emittedSinceMark(containing needle: String) -> Bool {
            textEmittedSinceMark.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    private func makeComposer(
        wireDiscardHook: Bool = true,
        config: FragmentComposer.Config = FragmentComposer.Config()
    ) -> (FragmentComposer, Recorder) {
        let recorder = Recorder()
        let composer = FragmentComposer(config: config)
        composer.onPersistPending = { text, anchor in recorder.persisted.append((text, anchor)) }
        composer.onFreeze = { text, anchor in recorder.frozen.append((text, anchor)) }
        if wireDiscardHook {
            composer.onDiscardPending = { anchor in recorder.discarded.append(anchor) }
        }
        return (composer, recorder)
    }

    // MARK: - Deletion racing the burst boundary

    /// The tightest race there is: the burst has gone quiet, the ≥3 s
    /// boundary is one heartbeat away, and the user deletes. The deletion
    /// must win — a boundary cannot freeze text that no longer exists.
    func testADeletionInTheLastMomentBeforeTheBoundaryBeatsTheFreeze() {
        let (composer, recorder) = makeComposer()

        composer.edit("wrong meeting notes", at: 10.0)
        composer.heartbeat(at: 11.1)                 // pending row written
        XCTAssertFalse(recorder.persisted.isEmpty)

        recorder.mark()
        composer.edit("", at: 12.99)                 // 10 ms before the boundary
        composer.heartbeat(at: 13.0)                 // the boundary heartbeat
        composer.heartbeat(at: 20.0)                 // and long after

        XCTAssertTrue(recorder.frozen.isEmpty, "the boundary must not resurrect deleted text")
        XCTAssertEqual(recorder.discarded, [10.0])
        XCTAssertFalse(recorder.emittedSinceMark(containing: "wrong meeting"),
                       "…and after the discard nothing may re-emit it")
    }

    /// The other side of the same race: the boundary lands FIRST. The
    /// fragment is committed and immutable from then on (SPEC §4.3), and the
    /// panel's own clearing of the body must not read as a retraction.
    func testAFreezeThatWinsTheRaceIsNotUndoneByTheClearThatFollows() {
        let (composer, recorder) = makeComposer()

        composer.edit("keep this decision", at: 10.0)
        composer.heartbeat(at: 11.1)
        composer.heartbeat(at: 13.0)                 // boundary: freeze
        XCTAssertEqual(recorder.frozen.map(\.text), ["keep this decision"])

        let writesAtFreeze = recorder.persisted.count
        composer.edit("", at: 13.001)                // the panel clears the body
        composer.heartbeat(at: 14.0)

        XCTAssertEqual(recorder.frozen.map(\.text), ["keep this decision"], "committed stays committed")
        XCTAssertTrue(recorder.discarded.isEmpty, "there is no pending row left to discard")
        XCTAssertEqual(recorder.persisted.count, writesAtFreeze, "and no store traffic follows a freeze")
    }

    /// A newline is an explicit freeze. Pressed after the text is already
    /// gone, it must freeze nothing rather than commit an empty fragment or
    /// the words that were there a moment ago.
    func testANewlinePressedAfterTheTextWasDeletedFreezesNothing() {
        let (composer, recorder) = makeComposer()

        composer.edit("scratch this thought", at: 20.0)
        composer.heartbeat(at: 21.1)
        recorder.mark()
        composer.edit("", at: 21.5)
        composer.newline(at: 21.6)                   // Return, on an empty body

        XCTAssertTrue(recorder.frozen.isEmpty)
        XCTAssertEqual(recorder.discarded, [20.0])
        XCTAssertFalse(recorder.emittedSinceMark(containing: "scratch this"),
                       "an explicit freeze must not commit what was just deleted")
    }

    /// Retyping in the very instant of the boundary starts a NEW burst: the
    /// new text must not be folded into the fragment that just froze, and
    /// must carry its own anchor (SPEC §4.3 — the anchor is the burst start).
    func testTypingAtTheInstantOfAFreezeOpensAFreshBurst() {
        let (composer, recorder) = makeComposer()

        composer.edit("first thought", at: 30.0)
        composer.heartbeat(at: 33.0)                 // freeze at the boundary
        composer.edit("second thought", at: 33.0)    // same instant, new burst
        composer.newline(at: 33.4)

        XCTAssertEqual(recorder.frozen.map(\.text), ["first thought", "second thought"])
        XCTAssertEqual(recorder.frozen.map(\.anchor), [30.0, 33.0], "each burst anchors at its own start")
    }

    /// Clear, then retype the SAME words. The committed fragment must be the
    /// retyped burst at its own anchor, and the abandoned row must have been
    /// discarded — otherwise the store holds two fragments where the user
    /// wrote one, and fusion sees the note twice.
    func testRetypingIdenticalTextAfterAClearProducesExactlyOneFragment() {
        let (composer, recorder) = makeComposer()

        composer.edit("send the DPA to legal", at: 40.0)
        composer.heartbeat(at: 41.1)                 // reached the store
        composer.edit("", at: 41.5)                  // cleared
        composer.edit("send the DPA to legal", at: 43.0)   // typed again, verbatim
        composer.heartbeat(at: 44.1)
        composer.heartbeat(at: 46.2)                 // boundary

        XCTAssertEqual(recorder.discarded, [40.0], "the abandoned row is removed exactly once")
        XCTAssertEqual(recorder.frozen.count, 1, "one fragment, not two")
        XCTAssertEqual(recorder.frozen[0].text, "send the DPA to legal")
        XCTAssertEqual(recorder.frozen[0].anchor, 43.0, "anchored where the surviving burst began")
    }

    // MARK: - Partial deletion

    /// A partial deletion keeps the burst alive. What is committed is what
    /// survived — and the deleted tail must never appear in any payload after
    /// the edit that removed it, including the trailing debounce write.
    func testTheDeletedTailNeverAppearsAfterAPartialDeletion() {
        let (composer, recorder) = makeComposer()

        composer.edit("pricing objection — Priya says the CFO will veto", at: 50.0)
        composer.heartbeat(at: 51.1)                 // the long version reaches the store
        XCTAssertTrue(recorder.sawAnyText(containing: "CFO will veto"))

        composer.edit("pricing objection", at: 51.5) // the rest is deleted
        composer.heartbeat(at: 52.6)                 // trailing persist
        composer.heartbeat(at: 54.6)                 // boundary

        XCTAssertEqual(recorder.frozen.map(\.text), ["pricing objection"])
        XCTAssertEqual(recorder.persisted.last?.text, "pricing objection",
                       "the pending row must end holding only the surviving text")
        XCTAssertTrue(recorder.discarded.isEmpty, "shortening is not discarding")
        // Everything written AFTER the deletion is free of the deleted tail.
        let afterDeletion = recorder.persisted.dropFirst(1).map(\.text) + recorder.frozen.map(\.text)
        XCTAssertFalse(afterDeletion.contains { $0.localizedCaseInsensitiveContains("CFO") })
    }

    /// Deleting back to a prefix and then typing something different: the
    /// abandoned middle must not reappear in the committed fragment.
    func testRewritingTheTailCommitsOnlyTheFinalWording() {
        let (composer, recorder) = makeComposer()

        composer.edit("ask legal about the indemnity cap", at: 60.0)
        composer.heartbeat(at: 61.1)
        composer.edit("ask legal about the", at: 61.4)
        composer.edit("ask legal about the renewal date", at: 61.8)
        composer.heartbeat(at: 62.9)
        composer.heartbeat(at: 64.9)                 // boundary

        XCTAssertEqual(recorder.frozen.map(\.text), ["ask legal about the renewal date"])
        XCTAssertEqual(recorder.frozen[0].anchor, 60.0, "one continuous burst keeps its original anchor")
        XCTAssertFalse(
            recorder.frozen.contains { $0.text.localizedCaseInsensitiveContains("indemnity") },
            "the abandoned wording must not be committed"
        )
    }

    // MARK: - The session ending mid-debounce

    /// Stop pressed while the last keystrokes are still inside the ~1 s
    /// debounce. `flush` must FORCE the write and freeze it: the debounce is
    /// the persistence (SPEC §4.3), so anything it is still holding is lost
    /// unless the flush overrides it.
    func testStoppingMidDebounceForcesTheUnpersistedTextThroughAndFreezesIt() {
        let (composer, recorder) = makeComposer()

        composer.edit("action", at: 70.0)            // first edit persists immediately
        composer.edit("action: renew before Q3", at: 70.3)   // inside the debounce
        XCTAssertEqual(recorder.persisted.count, 1, "the revision is still only in the composer")
        XCTAssertEqual(recorder.persisted[0].text, "action")

        composer.flush(at: 70.4)                     // Stop

        XCTAssertEqual(recorder.persisted.count, 2, "flush must override the debounce, not wait it out")
        XCTAssertEqual(recorder.persisted.last?.text, "action: renew before Q3")
        XCTAssertEqual(recorder.frozen.map(\.text), ["action: renew before Q3"])
        XCTAssertEqual(recorder.frozen[0].anchor, 70.0)
    }

    /// The same stop, with no delete hook wired (the app's current wiring):
    /// the flush still has to commit the in-flight text.
    func testStoppingMidDebounceWorksWithoutADiscardHook() {
        let (composer, recorder) = makeComposer(wireDiscardHook: false)

        composer.edit("follow", at: 80.0)
        composer.edit("follow up with procurement", at: 80.2)
        composer.flush(at: 80.3)

        XCTAssertEqual(recorder.frozen.map(\.text), ["follow up with procurement"])
        XCTAssertEqual(recorder.persisted.last?.text, "follow up with procurement")
    }

    /// Stop pressed after the user deleted the burst but before any boundary:
    /// nothing may be committed, and the deleted words must not be written on
    /// the way out.
    func testStoppingAfterADeleteCommitsNothingAndWritesNothing() {
        let (composer, recorder) = makeComposer()

        composer.edit("half formed idea about pricing", at: 90.0)
        composer.heartbeat(at: 91.1)
        composer.edit("", at: 91.4)                  // deleted
        let writesBeforeStop = recorder.persisted.count
        composer.flush(at: 91.5)                     // Stop
        composer.heartbeat(at: 95.0)                 // and the last heartbeats drain

        XCTAssertTrue(recorder.frozen.isEmpty)
        XCTAssertEqual(recorder.discarded, [90.0])
        XCTAssertEqual(recorder.persisted.count, writesBeforeStop, "flush must not re-write a discarded burst")
    }

    /// Stop while a burst is already frozen and the body is empty: a no-op,
    /// not an empty fragment.
    func testStoppingWithNothingPendingCommitsNothing() {
        let (composer, recorder) = makeComposer()

        composer.edit("committed already", at: 100.0)
        composer.newline(at: 100.2)                  // frozen
        composer.flush(at: 105.0)                    // Stop, empty body

        XCTAssertEqual(recorder.frozen.map(\.text), ["committed already"], "no empty second fragment")
    }

    // MARK: - The whole sequence

    /// One realistic scratchpad session: type, commit, type, regret, delete,
    /// retype, and stop mid-word. Exactly the fragments the user meant to
    /// keep are committed, in order, at their own anchors — and none of the
    /// abandoned text appears in a single payload the store (and therefore
    /// the fusion prompt, and therefore the model) would ever see.
    func testAFullScratchpadSessionCommitsOnlyWhatTheUserKept() {
        let (composer, recorder) = makeComposer()

        composer.edit("acme wants the enterprise tier", at: 200.0)
        composer.heartbeat(at: 201.1)
        composer.newline(at: 201.5)                             // committed #1

        composer.edit("their CFO is called Dave, I think?", at: 205.0)
        composer.heartbeat(at: 206.1)                           // reached the store
        composer.edit("", at: 207.0)                            // regretted, deleted

        composer.edit("send security questionnaire", at: 210.0)
        composer.heartbeat(at: 211.1)
        composer.heartbeat(at: 213.2)                           // boundary: committed #2

        composer.edit("book the follow", at: 220.0)             // still typing…
        composer.flush(at: 220.4)                               // …Stop: committed #3

        XCTAssertEqual(recorder.frozen.map(\.text), [
            "acme wants the enterprise tier",
            "send security questionnaire",
            "book the follow",
        ])
        XCTAssertEqual(recorder.frozen.map(\.anchor), [200.0, 210.0, 220.0])
        XCTAssertEqual(recorder.discarded, [205.0], "the regretted burst's row is removed")

        for deleted in ["CFO", "Dave"] {
            XCTAssertFalse(
                recorder.frozen.contains { $0.text.localizedCaseInsensitiveContains(deleted) },
                "deleted text reached a committed fragment: \(deleted)"
            )
            XCTAssertFalse(
                recorder.persisted.suffix(from: 2).contains { $0.text.localizedCaseInsensitiveContains(deleted) },
                "deleted text was re-written after the discard: \(deleted)"
            )
        }
    }

    /// Heartbeats keep arriving at 100 ms for the rest of the meeting. A
    /// discarded burst must stay discarded through every one of them — one
    /// stray freeze in a 40-minute meeting is 24,000 chances to leak.
    func testADiscardedBurstStaysDiscardedThroughAThousandHeartbeats() {
        let (composer, recorder) = makeComposer()

        composer.edit("delete me", at: 300.0)
        composer.heartbeat(at: 301.1)
        recorder.mark()
        composer.edit("", at: 301.5)

        var now = 301.6
        for _ in 0..<1_000 {
            composer.heartbeat(at: now)
            now += 0.1
        }

        XCTAssertTrue(recorder.frozen.isEmpty)
        XCTAssertEqual(recorder.discarded, [300.0], "exactly one discard, not one per heartbeat")
        XCTAssertFalse(recorder.emittedSinceMark(containing: "delete me"))
    }

    /// Two clears in a row (select-all + delete, then backspace on an already
    /// empty body) must produce ONE discard: the second has no burst to drop,
    /// and a duplicate would delete a row belonging to the next burst.
    func testARepeatedClearDiscardsOnlyOnce() {
        let (composer, recorder) = makeComposer()

        composer.edit("typo", at: 400.0)
        composer.heartbeat(at: 401.1)
        composer.edit("", at: 401.4)
        composer.edit("", at: 401.6)
        composer.edit("   ", at: 401.8)

        XCTAssertEqual(recorder.discarded, [400.0])
    }

    /// A non-default configuration must not change WHICH text is kept — only
    /// when the boundaries fall. Guards against a boundary constant being
    /// hard-coded into the deletion path.
    func testDeletionSemanticsHoldUnderANonDefaultBurstConfiguration() {
        let config = FragmentComposer.Config(persistDebounce: 0.25, burstPause: 0.75)
        let (composer, recorder) = makeComposer(config: config)

        composer.edit("quick note that gets deleted", at: 500.0)
        composer.heartbeat(at: 500.3)                // persist at the shorter debounce
        XCTAssertFalse(recorder.persisted.isEmpty)
        composer.edit("", at: 500.5)
        composer.heartbeat(at: 501.5)                // well past the shorter boundary

        XCTAssertTrue(recorder.frozen.isEmpty)
        XCTAssertEqual(recorder.discarded, [500.0])

        composer.edit("kept note", at: 502.0)
        composer.heartbeat(at: 502.3)
        composer.heartbeat(at: 502.8)                // ≥0.75 s pause → freeze
        XCTAssertEqual(recorder.frozen.map(\.text), ["kept note"])
    }
}
