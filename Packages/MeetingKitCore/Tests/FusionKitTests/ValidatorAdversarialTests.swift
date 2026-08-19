import XCTest
@testable import FusionKit
import Persistence

/// Adversarial cases for the hallucination-audit surface (SPEC §4.5).
///
/// `ValidatorRegressionTests` pins the two reproductions that were fixed.
/// This suite attacks the surface from both sides at once, because a wrong
/// verdict is worse than no verdict in EITHER direction:
///
/// * under-warning gives false assurance — the user forwards a fabricated
///   quote believing it was checked;
/// * over-warning trains the user to dismiss the warning pane, which retires
///   the feature just as completely.
///
/// So every case below is stated as a pair where a pair exists: the benign
/// variant that must stay silent, and the smallest mutation of it that must
/// speak up.
final class ValidatorAdversarialTests: XCTestCase {

    private func segments(_ items: (Channel, String, Double, Double)...) -> [SegmentRecord] {
        items.map { SegmentRecord(sessionId: UUID(), channel: $0.0, text: $0.1, startOffset: $0.2, endOffset: $0.3) }
    }

    private func kinds(_ markdown: String, _ segs: [SegmentRecord]) -> [NotesValidator.FindingKind] {
        NotesValidator.validate(markdown: markdown, segments: segs).map(\.kind)
    }

    /// A Decisions block wrapping one item.
    private func decision(_ item: String) -> String { "## Decisions\n- \(item)" }

    // MARK: - Surface-level differences that must NOT warn

    /// Punctuation, case and whitespace are rendering noise, not evidence of
    /// fabrication. A model that re-punctuates a quote it copied correctly is
    /// still telling the truth, and warning about it is how the pane becomes
    /// noise.
    func testQuotesDifferingOnlyInPunctuationCaseOrWhitespaceDoNotWarn() {
        let segs = segments((.remote, "We should ship on Friday, after the review.", 100, 110))
        let benign = [
            "punctuation dropped":  #"[01:40] "We should ship on Friday after the review" — Ship."#,
            "punctuation added":    #"[01:40] "We should ship on Friday; after the review!" — Ship."#,
            "case flattened":       #"[01:40] "WE SHOULD SHIP ON FRIDAY" — Ship."#,
            "case raised":          #"[01:40] "we should ship on friday" — Ship."#,
            "whitespace collapsed": "[01:40] \"We  should   ship\non Friday\" — Ship.",
        ]
        for (label, item) in benign {
            XCTAssertEqual(kinds(decision(item), segs), [], "false positive on \(label)")
        }
    }

    /// Smart quotes are what a model emits and what macOS types; straight
    /// quotes are what a transcript contains. Neither the delimiters nor the
    /// apostrophes inside may decide whether a genuine quote is trusted.
    func testSmartAndStraightQuotesAreInterchangeableInBothDirections() {
        let curlyTranscript = segments((.remote, "okay we\u{2019}ll send the redlines to Priya\u{2019}s team", 100, 110))
        let straightTranscript = segments((.remote, "okay we'll send the redlines to Priya's team", 100, 110))

        // Straight-quoted citation against a curly transcript…
        XCTAssertEqual(kinds(decision(#"[01:40] "we'll send the redlines" — go"#), curlyTranscript), [])
        // …curly-quoted citation against a straight transcript…
        XCTAssertEqual(kinds(decision("[01:40] \u{201C}we\u{2019}ll send the redlines\u{201D} — go"), straightTranscript), [])
        // …and the mixed pair models routinely produce.
        XCTAssertEqual(kinds(decision("[01:40] \u{201C}we'll send the redlines\" — go"), straightTranscript), [])

        // The mutation still has to warn: a fabricated quote wearing curly
        // delimiters is still fabricated.
        XCTAssertEqual(
            kinds(decision("[01:40] \u{201C}we\u{2019}ll send the signed contract\u{201D} — go"), straightTranscript),
            [.quoteMismatch]
        )
    }

    /// Hyphenation that matches the transcript is a verbatim quote. (When it
    /// does NOT match, the quote is not verbatim and the warning is correct —
    /// normalization strips punctuation, it does not paper over word
    /// boundaries.)
    func testHyphenationMatchingTheTranscriptDoesNotWarn() {
        let segs = segments((.remote, "lets do a follow-up next week", 100, 110))
        XCTAssertEqual(kinds(decision(#"[01:40] "a follow-up next week" — schedule it"#), segs), [])
    }

    // MARK: - Near misses that MUST warn

    /// A paraphrase is not a quote. Each mutation below is one word away from
    /// the transcript and every one changes what the speaker is on record as
    /// having said — the inserted word, the dropped word, the reordering,
    /// and the negation that reverses the meaning outright.
    func testNearMissParaphrasesWarnEvenOneWordFromVerbatim() {
        let segs = segments((.remote, "We should ship on Friday, after the review.", 100, 110))
        let paraphrases = [
            "word inserted": #""We should ship it on Friday""#,
            "word dropped":  #""We should on Friday""#,
            "word swapped":  #""We should launch on Friday""#,
            "reordered":     #""On Friday we should ship""#,
            "negated":       #""We should not ship on Friday""#,
            "tense changed": #""We shipped on Friday""#,
        ]
        for (label, quote) in paraphrases {
            XCTAssertEqual(kinds(decision("[01:40] \(quote) — Ship."), segs), [.quoteMismatch],
                           "under-warned on \(label)")
        }
        // The exact quote, same shape, stays silent — the control for all of
        // the above.
        XCTAssertEqual(kinds(decision(#"[01:40] "We should ship on Friday, after the review." — Ship."#), segs), [])
    }

    /// Nobody utters a sentence that spans a speaker change. A "quote"
    /// stitched from both sides of a turn is a fabrication of the model's own
    /// making, and per-channel matching must not let it through — while the
    /// half that one speaker really did say still passes.
    func testAQuoteSpanningASpeakerChangeWarnsWhileEachSpeakersOwnWordsDoNot() {
        let segs = segments(
            (.local, "so what did we decide", 100, 103),
            (.remote, "we ship on friday", 103, 107)
        )
        XCTAssertEqual(
            kinds(decision(#"[01:40] "what did we decide we ship on friday" — Ship."#), segs),
            [.quoteMismatch],
            "a sentence assembled across a turn boundary was never said by anyone"
        )
        XCTAssertEqual(kinds(decision(#"[01:43] "we ship on friday" — Ship."#), segs), [])
        XCTAssertEqual(kinds(decision(#"[01:40] "what did we decide" — Recap."#), segs), [])
    }

    // MARK: - Timestamps that point at the wrong place

    /// A real quote cited at the wrong moment is still a broken citation: the
    /// reader clicks through to a timestamp where nothing of the sort was
    /// said. It is inside the transcript timeline, so `missingTimestamp`
    /// cannot catch it — check (b)'s ±30 s window is the only thing that does.
    func testAQuoteCitedFarFromWhereItWasSaidWarns() {
        let segs = segments(
            (.remote, "we should defer the migration", 100, 110),
            (.remote, "unrelated chatter about lunch", 300, 310)
        )
        // Cited where it happened: silent.
        XCTAssertEqual(kinds(decision(#"[01:40] "we should defer the migration" — Defer."#), segs), [])
        // Cited three minutes later, still inside the transcript: warns, and
        // as a mismatch rather than a bogus timestamp.
        XCTAssertEqual(kinds(decision(#"[05:00] "we should defer the migration" — Defer."#), segs), [.quoteMismatch])
    }

    /// The ±30 s window is the tolerance for a model that rounds or points at
    /// the start of the turn rather than the sentence. Pinned on both sides so
    /// neither a widening nor a narrowing passes unnoticed.
    func testTheMatchWindowToleratesDriftUpToThirtySecondsAndNoFurther() {
        // The meeting runs well past both cited points, so the timestamps are
        // inside the timeline and check (a) never fires — this isolates (b).
        let segs = segments(
            (.remote, "we should defer the migration", 100, 110),
            (.remote, "unrelated chatter about lunch", 300, 310)
        )
        XCTAssertEqual(NotesValidator.matchWindow, 30, "the tolerance the cases below are stated against")
        // 02:09 → 129 s: the segment ends at 110, within 30 s. Silent.
        XCTAssertEqual(kinds(decision(#"[02:09] "we should defer the migration" — Defer."#), segs), [])
        // 02:21 → 141 s: 31 s past the segment's end. Warns.
        XCTAssertEqual(kinds(decision(#"[02:21] "we should defer the migration" — Defer."#), segs), [.quoteMismatch])
    }

    // MARK: - Citations that cannot be checked at all

    /// A placeholder is not evidence.
    ///
    /// `"..."` used to pass the audit CLEAN: it cleared the three-character
    /// floor, so the item counted as cited and check (c) stayed quiet, and its
    /// normalized form was empty, so check (b) skipped it as unmatchable. An
    /// item with no quote in it at all therefore reported green — the exact
    /// false assurance this validator exists to prevent.
    func testAPunctuationOnlyPlaceholderIsNotAQuote() {
        let segs = segments((.remote, "We should ship on Friday, after the review.", 100, 110))
        for placeholder in [#""...""#, #""---""#, "\u{201C}\u{2026}\u{2026}\u{2026}\u{201D}", #""-- ""#] {
            XCTAssertEqual(
                kinds(decision("[01:40] \(placeholder) — Ship on Friday."), segs), [.missingCitation],
                "a placeholder must not count as a verbatim quote: \(placeholder)"
            )
        }
        XCTAssertTrue(
            NotesValidator.citations(in: decision(#"[01:40] "..." — Ship on Friday."#)).isEmpty,
            "and it must not surface as a citation at all"
        )
    }

    /// `None recorded.` and its variants are an honest empty section. An item
    /// that merely BEGINS with one of those words and then goes on to assert
    /// something is a Decision like any other, and used to be waved through
    /// unchecked by the prefix match.
    func testAnItemThatOnlyStartsWithNoneIsStillAnUncitedClaim() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 110))

        let realClaims = [
            "None of the proposed vendors met the security bar, so we are staying with Acme.",
            "No action on staffing until Priya returns from leave in September.",
            "Nothing blocks the launch except the pending legal review of the DPA.",
        ]
        for claim in realClaims {
            XCTAssertEqual(kinds(decision(claim), segs), [.missingCitation],
                           "an uncited claim slipped through on its first word: \(claim)")
        }

        // The genuine empty-section markers stay exempt — the fix must not
        // start demanding citations for "there was nothing".
        let markers = [
            "None recorded.", "None.", "N/A", "No decisions.", "No decisions were made.",
            "No action items were recorded.", "Nothing to report.", "None identified.",
        ]
        for marker in markers {
            XCTAssertEqual(kinds(decision(marker), segs), [], "false positive on an empty section: \(marker)")
        }
    }

    /// A cited claim that starts with a none-word is fine — the citation is
    /// what matters, not the first word.
    func testANoneStyleClaimThatDoesCiteIsCheckedNormally() {
        let segs = segments((.remote, "we should ship on friday after the review", 100, 110))
        XCTAssertEqual(kinds(decision(#"[01:40] "we should ship on friday" — None of the blockers remain."#), segs), [])
        XCTAssertEqual(kinds(decision(#"[01:40] "we will ship on tuesday" — None of the blockers remain."#), segs),
                       [.quoteMismatch])
    }

    // MARK: - Both directions on one page

    /// The realistic end state: one set of notes carrying a clean item, a
    /// fabricated one, an uncited one and an honest empty section. Exactly
    /// three findings, each on the right item — a validator that reports four
    /// is as broken as one that reports two.
    func testAMixedNoteFlagsOnlyTheItemsThatDeserveIt() {
        let segs = segments(
            (.remote, "We should ship on Friday, after the review.", 100, 110),
            (.local, "mm hmm", 108, 109),
            (.remote, "And Priya owns the migration plan.", 112, 118)
        )
        let markdown = """
        Title: Ship planning

        ## Summary
        The team settled the ship date and owner.

        ## Key points
        - Timeline: shipping lands after the review.

        ## Decisions
        - [01:40] "We should ship on Friday after the review" — Ship Friday.
        - [01:40] "we will ship whenever legal says so" — Wait for legal.
        - Priya owns the migration plan.

        ## Action items
        - [01:52] "Priya owns the migration plan" — Priya drafts the plan.
        - [01:52] "..." — Book the review slot.
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.map(\.kind), [.quoteMismatch, .missingCitation, .missingCitation])
        guard findings.count == 3 else { return }
        XCTAssertTrue(findings[0].detail.contains("whenever legal says so"),
                      "the finding must name the offending quote: \(findings[0].detail)")
        XCTAssertTrue(findings[1].detail.contains("Priya owns the migration plan"))
        XCTAssertTrue(findings[2].detail.contains("no verbatim quote"),
                      "a placeholder reads as a missing quote, not a missing timestamp: \(findings[2].detail)")
    }
}
