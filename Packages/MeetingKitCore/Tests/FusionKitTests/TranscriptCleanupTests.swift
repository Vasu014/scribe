import XCTest
@testable import FusionKit
import Persistence

// MARK: - Shared fixtures

private let fixtureSession = UUID()

private func seg(
    _ channel: Channel,
    _ text: String,
    _ start: Double,
    _ end: Double
) -> SegmentRecord {
    SegmentRecord(sessionId: fixtureSession, channel: channel, text: text, startOffset: start, endOffset: end)
}

/// The pre-change prompt rendering: one line per raw segment. Kept here (not
/// in the shipping code) so every "before" number and every "this used to
/// happen" assertion is measured against the real old behaviour rather than
/// against a claim about it.
private func legacyRendering(_ segments: [SegmentRecord]) -> String {
    segments
        .sorted { $0.startOffset < $1.startOffset }
        .map { CanonicalRendering.transcriptLine(channel: $0.channel, text: $0.text, offset: $0.startOffset) }
        .joined(separator: "\n")
}

/// Anthropic's published rule of thumb for English prose. Exact enough for a
/// before/after ratio, which is what the item asks for; it *understates* the
/// merging win, because `[14:32] Them: ` is ~14 characters but 7–8 tokens.
private func approximateTokens(_ text: String) -> Int {
    Int((Double(text.count) / 4.0).rounded())
}

// MARK: - ITEM 18: deterministic cleanup

final class TranscriptCleanupTests: XCTestCase {

    // MARK: Repetition loops

    func testCollapsesInSegmentRepetitionLoop() {
        // Marginal audio: the decoder latches and repeats the phrase.
        let looped = "Thank you. Thank you. Thank you. Thank you. Thank you. Okay so where were we."
        let cleaned = TranscriptCleanup.collapseRepeatedPhrases(looped)
        XCTAssertEqual(cleaned, "Thank you. Okay so where were we.")
    }

    func testCollapsesSingleWordLoop() {
        XCTAssertEqual(
            TranscriptCleanup.collapseRepeatedPhrases("yes yes yes yes yes we can do that"),
            "yes we can do that"
        )
    }

    /// Two repeats is emphasis, not a decoder loop. The threshold exists so
    /// cleanup never rewrites ordinary speech.
    func testKeepsOrdinaryDoubledWords() {
        XCTAssertEqual(
            TranscriptCleanup.collapseRepeatedPhrases("no no that is not what I meant"),
            "no no that is not what I meant"
        )
        XCTAssertEqual(
            TranscriptCleanup.collapseRepeatedPhrases("it is very very expensive"),
            "it is very very expensive"
        )
    }

    /// Whisper also emits a loop as N identical *segments*.
    func testCollapsesLoopSpanningSegments() {
        let segments = [
            seg(.remote, "So the pricing is the issue.", 10, 13),
            seg(.remote, "I don't know.", 13, 14.5),
            seg(.remote, "I don't know.", 14.5, 16),
            seg(.remote, "I don't know.", 16, 17.5),
            seg(.remote, "I don't know.", 17.5, 19),
            seg(.remote, "Anyway, we need a number by Thursday.", 19, 23),
        ]
        let cleaned = TranscriptCleanup.clean(segments)
        XCTAssertEqual(cleaned.map(\.text), [
            "So the pricing is the issue.",
            "I don't know.",
            "Anyway, we need a number by Thursday.",
        ])
        // The timeline never gains a hole: the survivor spans the whole loop.
        XCTAssertEqual(cleaned[1].startOffset, 13)
        XCTAssertEqual(cleaned[1].endOffset, 19)
    }

    /// Two identical consecutive segments are speech, not a loop.
    func testKeepsTwoIdenticalSegments() {
        let segments = [
            seg(.local, "Right.", 10, 11.5),
            seg(.local, "Right.", 12, 13.5),
        ]
        XCTAssertEqual(TranscriptCleanup.clean(segments).count, 2)
    }

    // MARK: Filler

    func testStripsFillerOnlySegments() {
        let segments = [
            seg(.local, "We should ship the beta.", 10, 13),
            seg(.remote, "Mm-hmm.", 13.2, 14.4),
            seg(.remote, "Um...", 14.5, 15.6),
            seg(.remote, "[BLANK_AUDIO]", 15.7, 17),
            seg(.remote, "Only if the migration is done.", 17, 20),
        ]
        XCTAssertEqual(
            TranscriptCleanup.clean(segments).map(\.text),
            ["We should ship the beta.", "Only if the migration is done."]
        )
    }

    /// A filler *word* inside a real sentence is speech — only whole filler
    /// segments go. Stripping words in place would rewrite the transcript.
    func testKeepsFillerInsideRealSpeech() {
        let segments = [seg(.local, "Um, so the renewal is up in March.", 10, 14)]
        XCTAssertEqual(
            TranscriptCleanup.clean(segments).map(\.text),
            ["Um, so the renewal is up in March."]
        )
    }

    /// "yeah" alone carries agreement and can be the evidence under a
    /// decision — it is deliberately not in the filler set.
    func testKeepsMeaningfulShortSegments() {
        let segments = [seg(.remote, "Yeah.", 10, 11.5), seg(.local, "No.", 12, 13.5)]
        XCTAssertEqual(TranscriptCleanup.clean(segments).count, 2)
    }

    // MARK: Sub-second fragments

    func testFoldsSubSecondFragmentsIntoTheirNeighbour() {
        let segments = [
            seg(.local, "So the plan is", 10, 12),
            seg(.local, "we ship", 12.1, 12.7),      // 0.6 s
            seg(.local, "on Friday.", 12.8, 13.5),   // 0.7 s
            seg(.remote, "Okay.", 14, 15.2),
        ]
        let cleaned = TranscriptCleanup.clean(segments)
        XCTAssertEqual(cleaned.map(\.text), ["So the plan is we ship on Friday.", "Okay."])
        XCTAssertEqual(cleaned[0].startOffset, 10)
        XCTAssertEqual(cleaned[0].endOffset, 13.5)
    }

    /// A sub-second segment after a long silence is a new utterance, and a
    /// fragment on the other channel is a different speaker — neither folds.
    func testDoesNotFoldAcrossSilenceOrSpeakers() {
        let segments = [
            seg(.local, "So the plan is", 10, 12),
            seg(.remote, "Sure.", 12.1, 12.6),
            seg(.local, "Wait.", 40, 40.5),
        ]
        XCTAssertEqual(TranscriptCleanup.clean(segments).count, 3)
    }

    // MARK: Whitespace / punctuation

    func testNormalizesWhitespaceAndPunctuation() {
        XCTAssertEqual(
            TranscriptCleanup.normalizeText("So   we\nshould  ship , right ?!!!"),
            "So we should ship, right?!"
        )
        XCTAssertEqual(
            TranscriptCleanup.normalizeText("Well......... maybe"),
            "Well... maybe"
        )
    }

    /// Whitespace and punctuation changes are matching-neutral by
    /// construction: the validator's `normalize` strips both before it
    /// compares.
    func testPunctuationNormalizationCannotChangeMatching() {
        let raw = "So   we should ship , right ?!!!"
        XCTAssertEqual(
            CanonicalRendering.normalize(raw),
            CanonicalRendering.normalize(TranscriptCleanup.normalizeText(raw))
        )
    }

    // MARK: Determinism + idempotence

    func testCleanupIsDeterministic() {
        let segments = RealisticTranscript.segments
        XCTAssertEqual(TranscriptCleanup.clean(segments), TranscriptCleanup.clean(segments))
    }

    /// `FusionService` cleans before chunking and `PromptAssembler` cleans
    /// again on the way into the prompt. If those disagreed by one byte, the
    /// cached prefix would break and the eval corpus would hold two
    /// transcripts for one session.
    func testCleanupIsIdempotent() {
        let once = TranscriptCleanup.clean(RealisticTranscript.segments)
        XCTAssertEqual(TranscriptCleanup.clean(once), once)
    }

    /// Cleanup only ever deletes: it must never introduce a word the
    /// transcript did not contain. That property is what makes the
    /// validator's raw ∪ cleaned haystack safe.
    func testCleanupOnlyDeletesWords() {
        for segment in TranscriptCleanup.clean(RealisticTranscript.segments) {
            let rawVocabulary = Set(
                RealisticTranscript.segments
                    .filter { $0.channel == segment.channel }
                    .flatMap { CanonicalRendering.normalize($0.text).split(separator: " ") }
            )
            for word in CanonicalRendering.normalize(segment.text).split(separator: " ") {
                XCTAssertTrue(rawVocabulary.contains(word), "cleanup invented “\(word)”")
            }
        }
    }
}

// MARK: - ITEM 19: same-speaker block merging

final class SameSpeakerMergingTests: XCTestCase {

    func testMergesConsecutiveSameSpeakerSegmentsIntoOneBlock() {
        let segments = [
            seg(.remote, "We looked at the proposal.", 100, 104),
            seg(.remote, "Pricing is the sticking point.", 104, 108),
            seg(.local, "Understood.", 108, 110),
            seg(.local, "What number works?", 110, 113),
        ]
        let rendered = CanonicalRendering.renderTranscriptWithFragments(segments, fragments: [], lookback: 20)
        XCTAssertEqual(rendered, """
            [01:40] Them: We looked at the proposal. Pricing is the sticking point.
            [01:48] Me: Understood. What number works?
            """)
    }

    /// Blocks never span speakers — the per-channel validator haystack
    /// depends on it (a recent fix; do not "simplify" it away).
    func testBlocksNeverSpanChannels() {
        let segments = [
            seg(.remote, "one", 10, 11),
            seg(.local, "two", 11, 12),
            seg(.remote, "three", 12, 13),
        ]
        let merged = CanonicalRendering.mergeConsecutiveSameSpeaker(segments)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map(\.channel), [.remote, .local, .remote])
    }

    /// The verbatim transcript surface (History window) is untouched: it
    /// still shows one line per segment.
    func testRenderTranscriptStaysUnmerged() {
        let segments = [
            seg(.remote, "one", 10, 11),
            seg(.remote, "two", 11, 12),
        ]
        XCTAssertEqual(CanonicalRendering.renderTranscript(segments).split(separator: "\n").count, 2)
    }

    // MARK: The span cap is pinned to the validator's window

    func testMergeSpanCapStaysInsideTheValidatorWindow() {
        XCTAssertLessThan(
            CanonicalRendering.maxMergedBlockSpan, NotesValidator.matchWindow,
            "a block wider than the match window cites a timestamp whose ±30 s window no longer holds its own tail"
        )
    }

    func testBlockStopsGrowingAtTheSpanCap() {
        let segments = [
            seg(.remote, "alpha", 100, 110),
            seg(.remote, "bravo", 111, 120),
            seg(.remote, "charlie", 121, 130),   // 130 − 100 = 30 s > 25 s cap
        ]
        let merged = CanonicalRendering.mergeConsecutiveSameSpeaker(segments)
        XCTAssertEqual(merged.map(\.text), ["alpha bravo", "charlie"])
        XCTAssertEqual(merged.map(\.startOffset), [100, 121])
    }

    /// A quote from the END of a merged block, cited at the BLOCK's
    /// timestamp, must still validate — this is the citation that merging
    /// puts at risk.
    func testQuoteFromEndOfMergedBlockValidatesAgainstBlockTimestamp() {
        let segments = [
            seg(.remote, "So on the renewal", 100, 108),
            seg(.remote, "we are holding at the current rate", 108, 116),
            seg(.remote, "and we will revisit in Q3", 116, 124),   // span 24 s ≤ cap
        ]
        let rendered = CanonicalRendering.renderTranscriptWithFragments(segments, fragments: [], lookback: 20)
        XCTAssertEqual(
            rendered,
            "[01:40] Them: So on the renewal we are holding at the current rate and we will revisit in Q3",
            "one block, one timestamp — the model has only [01:40] to cite"
        )
        let markdown = """
        ## Decisions
        - [01:40] "we will revisit in Q3" — Revisit the rate in Q3.
        """
        XCTAssertTrue(
            NotesValidator.validate(markdown: markdown, segments: segments).isEmpty,
            "the tail of the block is 24 s from the block timestamp — inside ±30 s"
        )
    }

    /// …and the same citation DOES break once the block outgrows the window,
    /// which is why the cap is not a matter of taste. If this test ever goes
    /// green with a raised cap, citations are silently failing in production.
    func testUncappedMergingWouldBreakThatCitation() {
        let segments = [
            seg(.remote, "So on the renewal", 100, 130),
            seg(.remote, "we are holding at the current rate", 130, 160),
            seg(.remote, "and we will revisit in Q3", 160, 190),
        ]
        let blocks = CanonicalRendering.mergeConsecutiveSameSpeaker(segments, maxSpan: 600)
        XCTAssertEqual(blocks.count, 1, "pretend the cap does not exist")
        let markdown = """
        ## Decisions
        - [\(CanonicalRendering.timestampText(blocks[0].startOffset))] "we will revisit in Q3" — Revisit in Q3.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segments).map(\.kind),
            [.quoteMismatch],
            "90 s block, ±30 s window: the tail is unreachable from the block timestamp"
        )
        // With the shipping cap the same transcript never forms that block.
        XCTAssertEqual(CanonicalRendering.mergeConsecutiveSameSpeaker(segments).count, 3)
    }

    // MARK: User notes are not displaced

    /// A note's effective anchor is a merge barrier: merging must not sweep
    /// speech from after the note into a block that starts before it.
    func testUserNoteAnchorActsAsMergeBarrier() {
        let segments = [
            seg(.remote, "first thing", 100, 104),
            seg(.remote, "second thing", 112, 116),
        ]
        // anchor 128 − 20 lookback = effective 108, between the two segments.
        let fragments = [FragmentRecord(sessionId: fixtureSession, text: "watch this", anchorOffset: 128)]
        let rendered = CanonicalRendering.renderTranscriptWithFragments(segments, fragments: fragments, lookback: 20)
        XCTAssertEqual(rendered, """
            [01:40] Them: first thing
            [USER NOTE @ 02:08] watch this
            [01:52] Them: second thing
            """)
    }
}

// MARK: - The constraint both items live under: quotes stay matchable

final class CleanupQuoteMatchingTests: XCTestCase {

    /// Direction 1 — a quote that matched BEFORE the change still matches
    /// after. Spans two raw segments, survives cleanup and merging untouched.
    func testQuoteThatMatchedBeforeStillMatchesAfter() {
        let segments = [
            seg(.remote, "so we should defer", 860, 870),
            seg(.remote, "the migration doc review", 870, 880),
        ]
        let markdown = """
        ## Decisions
        - [14:20] "defer the migration doc review" — Defer doc review.
        """
        // Matched against the raw transcript before this change…
        XCTAssertTrue(
            CanonicalRendering.normalizedTextWindows(segments, around: 860, window: 30)
                .contains { $0.contains(CanonicalRendering.normalize("defer the migration doc review")) }
        )
        // …and against the cleaned + merged one after it.
        let prepared = CanonicalRendering.mergeConsecutiveSameSpeaker(TranscriptCleanup.clean(segments))
        XCTAssertTrue(
            CanonicalRendering.normalizedTextWindows(prepared, around: 860, window: 30)
                .contains { $0.contains(CanonicalRendering.normalize("defer the migration doc review")) }
        )
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segments).isEmpty)
    }

    /// Direction 2 — a quote the model can only have read off the CLEANED
    /// transcript (it reads across a filler-only segment cleanup removed)
    /// must not be reported as a hallucination.
    ///
    /// This is the regression the item warns about: before the validator
    /// searched the cleaned haystack too, this exact note produced a
    /// `quoteMismatch` on a perfectly genuine quote — the audit crying wolf.
    func testQuoteReadingAcrossRemovedFillerIsNotFlagged() {
        let segments = [
            seg(.local, "we should ship the beta", 100, 103),
            seg(.local, "um", 103.5, 104.2),
            seg(.local, "on Friday at the latest", 104.5, 107),
        ]
        let quote = "ship the beta on Friday"
        let markdown = """
        ## Action items
        - [01:40] "\(quote)" — Ship the beta on Friday.
        """

        // Pre-change behaviour, reconstructed: raw haystack only.
        XCTAssertFalse(
            CanonicalRendering.normalizedTextWindows(segments, around: 100, window: 30)
                .contains { $0.contains(CanonicalRendering.normalize(quote)) },
            "the raw haystack still has the filler wedged into the middle of the quote"
        )
        // The prompt the model actually saw contains the quote verbatim.
        XCTAssertTrue(
            CanonicalRendering
                .renderTranscriptWithFragments(TranscriptCleanup.clean(segments), fragments: [], lookback: 20)
                .contains(quote)
        )
        // …so the validator must pass it.
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segments).isEmpty)
    }

    /// The union must not blunt the audit: an invented quote still fails,
    /// because cleanup only deletes and never introduces vocabulary.
    func testFabricatedQuoteStillFails() {
        let segments = [
            seg(.local, "we should ship the beta", 100, 103),
            seg(.local, "um", 103.5, 104.2),
            seg(.local, "on Friday at the latest", 104.5, 107),
        ]
        let markdown = """
        ## Action items
        - [01:40] "buy everyone pizza immediately" — Order lunch.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segments).map(\.kind),
            [.quoteMismatch]
        )
    }

    /// …and a quote that only exists by splicing two speakers together still
    /// fails, cleaned haystack or not (per-channel matching is preserved).
    func testCrossSpeakerSpliceStillFails() {
        let segments = [
            seg(.local, "we should ship the beta", 100, 103),
            seg(.remote, "mm hmm", 103, 104),
            seg(.local, "on Friday", 104, 106),
        ]
        let markdown = """
        ## Decisions
        - [01:40] "the beta mm hmm on Friday" — Ship Friday.
        """
        XCTAssertEqual(
            NotesValidator.validate(markdown: markdown, segments: segments).map(\.kind),
            [.quoteMismatch]
        )
    }
}

// MARK: - Measured token reduction (items 18 + 19)

/// A realistic two-channel meeting excerpt (~5 minutes): normal utterances
/// broken into the 2–8 s segments WhisperKit actually emits, plus the three
/// artifacts cleanup targets — a decoder repetition loop, filler-only
/// segments, and sub-second fragments.
enum RealisticTranscript {
    static let segments: [SegmentRecord] = [
        seg(.local, "Alright, thanks for making the time today.", 0, 2.6),
        seg(.local, "I wanted to walk through the renewal and then the migration timeline.", 2.8, 7.2),
        seg(.remote, "Sounds good.", 7.4, 8.3),
        seg(.remote, "Um.", 8.5, 9.0),
        seg(.remote, "We went through the proposal on Friday with the whole team.", 9.2, 13.8),
        seg(.remote, "Pricing is really the only sticking point at this stage.", 13.9, 18.4),
        seg(.local, "Mm-hmm.", 18.5, 19.2),
        seg(.local, "That's fair, and it's the part I have the most room on.", 19.4, 23.6),
        seg(.local, "What number were you expecting to land on?", 23.7, 26.9),
        seg(.remote, "We were looking at something closer to eighteen a seat.", 27.1, 31.4),
        seg(.remote, "Anything above twenty and I have to take it to finance.", 31.5, 36.2),
        seg(.local, "Okay.", 36.4, 37.1),
        seg(.local, "I can do nineteen if we sign a two year term.", 37.2, 41.0),
        seg(.local, "Below that I'd need to strip out the premium support tier.", 41.1, 45.8),
        seg(.remote, "Yeah, exactly.", 46.0, 47.4),
        seg(.remote, "Yeah, exactly.", 47.4, 48.8),
        seg(.remote, "Yeah, exactly.", 48.8, 50.2),
        seg(.remote, "That's the trade we talked about internally as well.", 50.4, 54.6),
        seg(.remote, "[BLANK_AUDIO]", 54.8, 56.0),
        seg(.local, "So let's say nineteen, two year term, support included.", 56.2, 61.0),
        seg(.local, "I'll send", 61.1, 61.6),
        seg(.local, "the revised quote", 61.7, 62.5),
        seg(.local, "by Thursday.", 62.6, 63.4),
        seg(.remote, "That works.", 63.6, 64.6),
        seg(.remote, "Uh.", 64.8, 65.3),
        seg(.remote, "The other thing is the migration off the legacy workspace.", 65.5, 70.2),
        seg(.remote, "Thank you. Thank you. Thank you. Thank you. Thank you. Thank you.", 70.4, 76.0),
        seg(.remote, "Sorry, my audio dropped for a second there.", 76.2, 79.4),
        seg(.local, "No problem.", 79.6, 80.6),
        seg(.local, "On the migration, we agreed to defer the database migration until Q3.", 80.8, 86.4),
        seg(.local, "Trying to do it alongside the rollout would put both at risk.", 86.5, 91.2),
        seg(.remote, "Mm.", 91.4, 92.0),
        seg(.remote, "I'd want that written into the renewal so it doesn't slip again.", 92.2, 97.4),
        seg(.local, "Understood, I'll add it as an appendix to the contract.", 97.6, 102.0),
        seg(.local, "Anything else before we wrap?", 102.1, 104.3),
        seg(.remote, "One last thing.", 104.5, 105.6),
        seg(.remote, "Can you loop in Priya for the security review next week?", 105.8, 110.4),
        seg(.local, "Will do, I'll send her an invite this afternoon.", 110.6, 114.2),
    ]

    /// The same meeting off a bad line: WhisperKit emits far more filler-only
    /// segments and drops into decoder loops. Same speech, same durations —
    /// only the artifact density changes, which is the variable the 15–25%
    /// claim is actually sensitive to.
    static let marginalAudioSegments: [SegmentRecord] = {
        let fillers = ["Um.", "Mm-hmm.", "[BLANK_AUDIO]", "Uh.", "Mm."]
        var out: [SegmentRecord] = []
        var clock: TimeInterval = 0
        func add(_ channel: Channel, _ text: String, _ duration: TimeInterval) {
            out.append(seg(channel, text, clock, clock + duration))
            clock += duration + 0.2
        }
        for (index, source) in segments.enumerated() {
            add(source.channel, source.text, source.endOffset - source.startOffset)
            if index % 3 == 0 {
                add(source.channel, fillers[(index / 3) % fillers.count], 0.7)
            }
            if index % 7 == 3 {
                add(source.channel, String(repeating: "Thank you. ", count: 12).trimmingCharacters(in: .whitespaces), 9)
            }
        }
        return out
    }()

    static let fragments: [FragmentRecord] = [
        FragmentRecord(sessionId: fixtureSession, text: "pricing objection — 18/seat", anchorOffset: 40),
        FragmentRecord(sessionId: fixtureSession, text: "migration must be in the contract", anchorOffset: 110),
    ]
}

final class TranscriptTokenReductionTests: XCTestCase {

    private struct Measurement {
        let label: String
        let before: Int, afterCleanup: Int, afterBoth: Int
        let lines: (Int, Int, Int)
        func drop(_ from: Int, _ to: Int) -> Double { (Double(from - to) / Double(from)) * 100 }
        var cleanupDrop: Double { drop(before, afterCleanup) }
        var mergeDrop: Double { drop(afterCleanup, afterBoth) }
        var totalDrop: Double { drop(before, afterBoth) }
    }

    private func measure(_ label: String, _ raw: [SegmentRecord]) -> Measurement {
        let cleaned = TranscriptCleanup.clean(raw)
        let before = legacyRendering(raw)
        let afterCleanup = legacyRendering(cleaned)
        let afterBoth = CanonicalRendering.renderTranscriptWithFragments(cleaned, fragments: [], lookback: 20)
        return Measurement(
            label: label,
            before: approximateTokens(before),
            afterCleanup: approximateTokens(afterCleanup),
            afterBoth: approximateTokens(afterBoth),
            lines: (
                before.split(separator: "\n").count,
                afterCleanup.split(separator: "\n").count,
                afterBoth.split(separator: "\n").count
            )
        )
    }

    /// Prints and asserts the before/after numbers, on two inputs: a clean
    /// recording with the artifacts you always get a few of, and the same
    /// meeting recorded off marginal audio (long decoder loops, more
    /// filler). The reduction is a property of the *input*, not of the code,
    /// so one number would be a claim rather than a measurement.
    ///
    /// Floors are set just under what is measured today so a regression
    /// fails the test; they are not the items' headline figures.
    func testMeasuredTokenReduction() {
        let good = measure("clean audio", RealisticTranscript.segments)
        let marginal = measure("marginal audio", RealisticTranscript.marginalAudioSegments)

        for m in [good, marginal] {
            print("""

            ── \(m.label) ──
            before (raw, one line per segment) : ~\(m.before) tokens, \(m.lines.0) lines
            after cleanup (item 18)            : ~\(m.afterCleanup) tokens, \(m.lines.1) lines  → −\(String(format: "%.1f", m.cleanupDrop))%
            after cleanup + merging (item 19)  : ~\(m.afterBoth) tokens, \(m.lines.2) lines  → −\(String(format: "%.1f", m.mergeDrop))% on top
            total                              : −\(String(format: "%.1f", m.totalDrop))%

            """)
        }

        // Item 18 — measured 12.7% on clean audio, 38.5% on marginal audio (the
        // items’ 15–25% sits between the two — it is an input property).
        XCTAssertGreaterThanOrEqual(good.cleanupDrop, 12.0)
        XCTAssertGreaterThanOrEqual(marginal.cleanupDrop, 30.0)
        // Item 19 — measured ~12% on top, both inputs.
        XCTAssertGreaterThanOrEqual(good.mergeDrop, 10.0)
        XCTAssertGreaterThanOrEqual(marginal.mergeDrop, 10.0)
    }

    /// Every citation a model could make off the *raw* transcript still
    /// validates after the prompt switched to the cleaned + merged one — run
    /// over the whole realistic transcript, not one hand-picked line.
    func testEveryRawUtteranceRemainsCitableAfterBothItems() {
        let raw = RealisticTranscript.segments
        for segment in raw {
            let words = segment.text.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 5 else { continue }
            let quote = words.prefix(6).joined(separator: " ")
            let markdown = """
            ## Decisions
            - [\(CanonicalRendering.timestampText(segment.startOffset))] "\(quote)" — item.
            """
            XCTAssertTrue(
                NotesValidator.validate(markdown: markdown, segments: raw).isEmpty,
                "quote “\(quote)” at \(segment.startOffset)s stopped matching"
            )
        }
    }

    /// …and the mirror: every block the model is actually shown is citable at
    /// the timestamp it is shown with.
    func testEveryRenderedBlockIsCitableAtItsOwnTimestamp() {
        let raw = RealisticTranscript.segments
        let blocks = CanonicalRendering.mergeConsecutiveSameSpeaker(TranscriptCleanup.clean(raw))
        for block in blocks {
            let words = block.text.split(whereSeparator: { $0.isWhitespace })
            guard words.count >= 5 else { continue }
            // Quote the TAIL of the block — the part furthest from its timestamp.
            let quote = words.suffix(6).joined(separator: " ")
            let markdown = """
            ## Action items
            - [\(CanonicalRendering.timestampText(block.startOffset))] "\(quote)" — item.
            """
            XCTAssertTrue(
                NotesValidator.validate(markdown: markdown, segments: raw).isEmpty,
                "tail quote “\(quote)” of the block at \(block.startOffset)s is not citable at its own timestamp"
            )
        }
    }
}

// MARK: - Service wiring

final class FusionServiceCleanupWiringTests: XCTestCase {

    private func makeProcessingSession(_ store: MeetingStore) throws -> SessionRecord {
        var session = try store.createSession()
        session.state = .processing
        try store.updateSession(session)
        return session
    }

    /// The prompt the provider receives is the cleaned, merged rendering —
    /// end to end through the store.
    func testFusePromptCarriesCleanedMergedTranscript() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        for text in ["We should ship the beta", "Um", "on Friday at the latest"] {
            let index = Double(["We should ship the beta", "Um", "on Friday at the latest"].firstIndex(of: text)!)
            try store.upsertSegment(SegmentRecord(
                sessionId: session.id, channel: .local, text: text,
                startOffset: 100 + index * 4, endOffset: 103 + index * 4, isFinal: true
            ))
        }
        let provider = MockFusionProvider(responses: ["Title: x\n\n## Summary\nx."])
        _ = await FusionService(store: store).fuse(session: session, provider: provider)

        let prompt = try XCTUnwrap(provider.calls.first?.userPrompt)
        XCTAssertEqual(prompt, "[01:40] Me: We should ship the beta on Friday at the latest",
                       "one block, filler gone")
    }

    /// A truncated provider response is a failure, not a note: nothing is
    /// stored and the session stays in `processing` for Retry.
    func testTruncatedResponseIsNeverStored() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote, text: "some real talk here",
            startOffset: 10, endOffset: 20, isFinal: true
        ))
        let provider = MockFusionProvider(failure: AnthropicFusionProviderError.responseTruncated(1536))

        let outcome = await FusionService(store: store).fuse(session: session, provider: provider)

        guard case .failure(.provider(let message)) = outcome else {
            return XCTFail("expected .failure(.provider), got \(outcome)")
        }
        XCTAssertTrue(message.contains("cut off"), "the Retry UI must say the notes were truncated: \(message)")
        XCTAssertTrue(try store.notes(sessionId: session.id).isEmpty, "a half-written note must never be stored")
        XCTAssertEqual(try store.session(id: session.id)?.state, .processing)
    }

    /// A transcript that cleans away to nothing is fused raw rather than
    /// vanishing into a cleanup bug.
    func testAllFillerTranscriptStillFuses() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote, text: "Um.",
            startOffset: 10, endOffset: 11, isFinal: true
        ))
        let provider = MockFusionProvider(responses: ["Title: x\n\n## Summary\nx."])
        let outcome = await FusionService(store: store).fuse(session: session, provider: provider)

        guard case .success = outcome else { return XCTFail("expected .success, got \(outcome)") }
        XCTAssertEqual(provider.calls.first?.userPrompt, "[00:10] Them: Um.")
    }
}
