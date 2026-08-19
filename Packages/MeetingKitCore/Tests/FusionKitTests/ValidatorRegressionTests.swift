import XCTest
@testable import FusionKit
import Persistence

/// Regression tests for the two ways the hallucination-audit surface (SPEC
/// §4.5) failed: it slept through fabricated quotes, and it cried wolf on
/// genuine ones. Both were reproduced against the shipped code before these
/// tests existed; each `XCTAssert` below is pinned to one of those repros.
final class ValidatorHallucinationTests: XCTestCase {

    private func segments(_ items: (Channel, String, Double, Double)...) -> [SegmentRecord] {
        items.map { SegmentRecord(sessionId: UUID(), channel: $0.0, text: $0.1, startOffset: $0.2, endOffset: $0.3) }
    }

    // MARK: - False negatives: a fabricated quote MUST warn

    /// Audit #2 repro, verbatim. A bolded timestamp is ordinary model output;
    /// the old citation regex required the quote to follow `]` immediately,
    /// so this yielded 0 citations, 0 findings, and a session that completed
    /// clean with a fabricated quote in it.
    func testFabricatedQuoteWithBoldedTimestampIsFlagged() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let markdown = """
        ## Decisions
        - **[01:40]** "totally fabricated quote" — X
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.count, 1, "a fabricated quote must never pass silently")
        XCTAssertEqual(findings[0].kind, .quoteMismatch)
    }

    /// The same defect with the other common decorations: `[ts]:`, `[ts] —`,
    /// and a quote the model put before its timestamp.
    func testFabricatedQuoteWithOtherSeparatorsIsFlagged() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        for line in [
            #"- [01:40]: "totally fabricated quote" — X"#,
            #"- [01:40] — "totally fabricated quote" (Priya)"#,
            #"- *[01:40]* Priya said "totally fabricated quote""#,
            #"- "totally fabricated quote" [01:40] — X"#,
        ] {
            let findings = NotesValidator.validate(markdown: "## Action items\n\(line)", segments: segs)
            XCTAssertEqual(findings.map(\.kind), [.quoteMismatch], "not flagged: \(line)")
        }
    }

    /// Audit #2, second half: an item with no citation at all. SPEC §4.5 makes
    /// `timestamp + verbatim quote + item text` the shape of a Decision /
    /// Action item, so an uncited item is an unchecked claim — it must be a
    /// finding in its own right, not a silent pass.
    func testActionItemWithNoCitationIsFlagged() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let markdown = """
        ## Action items
        - Ship on Friday — Priya
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.map(\.kind), [.missingCitation])
        XCTAssertTrue(findings[0].detail.contains("neither a timestamp nor a verbatim quote"))
    }

    func testDecisionWithTimestampButNoQuoteIsFlagged() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let markdown = """
        ## Decisions
        - [01:40] Ship on Friday
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.map(\.kind), [.missingCitation])
        XCTAssertTrue(findings[0].detail.contains("no verbatim quote"))
    }

    func testQuoteWithoutTimestampIsFlagged() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let markdown = """
        ## Decisions
        - "we should ship on friday" — Ship Friday.
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.map(\.kind), [.missingCitation],
                       "a quote with no timestamp cannot be located in the transcript")
    }

    /// A genuine hallucination in the plain, well-formed shape must still
    /// warn — the pre-existing guarantee, re-pinned so the leniency added for
    /// the cases above cannot quietly swallow it.
    func testGenuineHallucinationInWellFormedShapeStillWarns() {
        let segs = segments((.remote, "We agreed to defer the database migration until Q3", 860, 890))
        let markdown = """
        ## Action items
        - [14:30] "buy everyone pizza immediately" — Order lunch.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segs).map(\.kind),
            [.quoteMismatch]
        )
    }

    /// A quote lifted from the *other* speaker's turn is not a verbatim quote
    /// of the cited speaker, and the per-channel haystack must not let it pass.
    func testQuoteStitchedAcrossSpeakersIsFlagged() {
        let segs = segments(
            (.remote, "we should ship on", 100, 103.5),
            (.local, "mm hmm", 103, 104),
            (.remote, "friday after the review", 104, 107)
        )
        let markdown = """
        ## Decisions
        - [01:40] "ship on mm hmm friday" — Ship Friday.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segs).map(\.kind),
            [.quoteMismatch],
            "the interleaved haystack used to invent this span"
        )
    }

    // MARK: - False positives: a genuine quote must NOT warn

    /// Audit #3 repro, verbatim. A backchannel from the other channel landing
    /// between two of the quoted speaker's segments used to splice itself
    /// into the middle of a perfectly verbatim quote and raise a
    /// `quoteMismatch`. Two-channel capture makes this routine.
    func testBackchannelDoesNotSplitAVerbatimQuote() {
        let segs = segments(
            (.remote, "we should ship on", 100, 103.5),
            (.local, "mm hmm", 103, 104),
            (.remote, "friday after the review", 104, 107)
        )
        let markdown = """
        ## Decisions
        - [01:40] "we should ship on friday" — Ship on Friday.
        """
        XCTAssertTrue(
            NotesValidator.validate(markdown: markdown, segments: segs).isEmpty,
            "a verbatim quote split by the other channel's backchannel must not warn"
        )
    }

    /// The leniency that fixes the false negatives must not itself warn on a
    /// genuine quote wearing the same decoration.
    func testBoldedTimestampWithGenuineQuoteDoesNotWarn() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        for line in [
            #"- **[01:40]** "we should ship on friday" — Ship Friday."#,
            #"- [01:40]: "we should ship on friday" — Ship Friday."#,
            #"- [01:40] — "we should ship on friday" (Priya)"#,
            "- [01:40] ‘we should ship on friday’ — Ship Friday.",
            "- [01:40] 'we should ship on friday' — Ship Friday.",
        ] {
            XCTAssertTrue(
                NotesValidator.validate(markdown: "## Decisions\n\(line)", segments: segs).isEmpty,
                "false positive on: \(line)"
            )
        }
    }

    /// Apostrophes are not quote marks. Without the word-boundary rule,
    /// `we'll … Priya's` reads as a quoted span and manufactures a warning.
    func testApostrophesAreNotReadAsQuotes() {
        let segs = segments((.local, "okay we'll send the redlines to Priya's team", 100, 110))
        let markdown = """
        ## Action items
        - [01:40] "we'll send the redlines" — it's Priya's call when.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    /// `None recorded.` is an honest empty section, not an uncited claim.
    func testNoneRecordedSectionsAreExempt() {
        let segs = segments((.remote, "small talk only", 0, 20))
        for body in ["None recorded.", "- None recorded.", "- No decisions were made.", "N/A"] {
            XCTAssertTrue(
                NotesValidator.validate(markdown: "## Decisions\n\(body)", segments: segs).isEmpty,
                "false positive on: \(body)"
            )
        }
    }

    /// Only Decisions / Action items are *required* to cite. Key points and
    /// the summary are prose; requiring citations there would bury the pane
    /// in warnings. Any citation they do carry is still checked.
    func testOnlyDecisionAndActionSectionsRequireCitations() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let clean = """
        Title: Ship planning

        ## Summary
        The team agreed on a ship date.

        ## Key points
        - **Timeline**: shipping lands after the review.
        - No decision on staffing yet.

        ## Decisions
        - [01:40] "we should ship on friday" — Ship on Friday.

        ## Action items
        None recorded.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: clean, segments: segs).isEmpty)

        // …but a fabricated citation inside Key points is still checked.
        let dirty = clean.replacingOccurrences(
            of: "- **Timeline**: shipping lands after the review.",
            with: #"- **Timeline**: [01:40] "we ship whenever we feel like it" — per the call."#
        )
        XCTAssertEqual(
            NotesValidator.validate(markdown: dirty, segments: segs).map(\.kind),
            [.quoteMismatch]
        )
    }

    /// A wrapped item and its indented sub-bullets are ONE claim: the
    /// citation may sit on any of those lines, and the sub-bullets must not
    /// each demand their own.
    func testWrappedItemsAndSubBulletsFoldIntoOneClaim() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 107))
        let markdown = """
        ## Action items
        - Ship the release once the review lands
          [01:40] "we should ship on friday" — Priya
          - confirm with QA first
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    /// Headings the model writes in the other common styles must still be
    /// recognized, or check (c) silently stops applying.
    func testAlternateHeadingStylesAreRecognized() {
        let segs = segments((.remote, "small talk only", 0, 20))
        for heading in ["## Decisions", "### Action items", "**Decisions**", "Action items:", "#### DECISIONS"] {
            let findings = NotesValidator.validate(markdown: "\(heading)\n- Ship on Friday", segments: segs)
            XCTAssertEqual(findings.map(\.kind), [.missingCitation], "heading not recognized: \(heading)")
        }
    }

    /// Bare times in prose ("meet at 3:30") are not citations — treating them
    /// as such manufactures warnings about claims nobody made.
    func testBareTimesAreNotCitations() {
        let segs = segments((.remote, "lets meet at 3 30 tomorrow", 100, 110))
        let markdown = """
        ## Decisions
        - [01:40] "lets meet at 3 30 tomorrow" — Standing 3:30 sync.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
        XCTAssertEqual(NotesValidator.citations(in: markdown).count, 1,
                       "the trailing 3:30 must not pair with anything")
    }

    func testMissingTimestampStillWins() {
        let segs = segments((.remote, "short", 0, 10))
        let markdown = """
        ## Decisions
        - **[45:00]** "short" — Something at a timestamp the session never reached.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segs).map(\.kind),
            [.missingTimestamp]
        )
    }
}

/// The per-channel matching window (SPEC §4.5 check (b)).
final class NormalizedTextWindowTests: XCTestCase {

    func testWindowsAreSplitByChannel() {
        let sessionId = UUID()
        let segs = [
            SegmentRecord(sessionId: sessionId, channel: .remote, text: "we should ship on", startOffset: 100, endOffset: 103.5),
            SegmentRecord(sessionId: sessionId, channel: .local, text: "mm hmm", startOffset: 103, endOffset: 104),
            SegmentRecord(sessionId: sessionId, channel: .remote, text: "friday after the review", startOffset: 104, endOffset: 107),
        ]
        let windows = CanonicalRendering.normalizedTextWindows(segs, around: 100, window: 30)
        XCTAssertEqual(windows, ["mm hmm", "we should ship on friday after the review"],
                       "local first, remote second — deterministic order")
    }

    func testWindowExcludesSegmentsOutsideTheWindow() {
        let sessionId = UUID()
        let segs = [
            SegmentRecord(sessionId: sessionId, channel: .remote, text: "in window", startOffset: 100, endOffset: 110),
            SegmentRecord(sessionId: sessionId, channel: .remote, text: "far away", startOffset: 400, endOffset: 410),
        ]
        XCTAssertEqual(CanonicalRendering.normalizedTextWindows(segs, around: 100, window: 30), ["in window"])
    }
}
