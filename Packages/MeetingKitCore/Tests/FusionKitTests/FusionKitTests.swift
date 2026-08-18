import XCTest
@testable import FusionKit
import Persistence

final class CanonicalRenderingTests: XCTestCase {

    // MARK: Round-trip (spec-mandated: format → parse → identical offsets)

    func testTimestampRoundTrip() {
        // Both forms, including the hour boundary (per-timestamp rule, SPEC §4.5).
        let offsets: [TimeInterval] = [0, 1, 59, 59.4, 60, 599, 3599, 3600, 3734, 3661.9]
        for offset in offsets {
            let text = CanonicalRendering.timestampText(offset)
            let parsed = CanonicalRendering.parseTimestamp(text)
            let expected = TimeInterval(Int(offset.rounded()))
            XCTAssertNotNil(parsed, "unparseable: \(text)")
            XCTAssertEqual(parsed!, expected, "round-trip failed for \(text)")
            // Bracketed form must also parse.
            XCTAssertEqual(CanonicalRendering.parseTimestamp(CanonicalRendering.timestamp(offset)), expected)
        }
    }

    func testPerTimestampHoursRule() {
        // A long meeting contains BOTH forms (SPEC §4.5).
        XCTAssertEqual(CanonicalRendering.timestampText(3599), "59:59")
        XCTAssertEqual(CanonicalRendering.timestampText(3600), "1:00:00")
        XCTAssertEqual(CanonicalRendering.timestamp(3734), "[1:02:14]")
    }

    func testParserRejectsGarbage() {
        for bad in ["", "14", "14:", ":32", "1:2:3:4", "ab:cd"] {
            XCTAssertNil(CanonicalRendering.parseTimestamp(bad), "should reject: \(bad)")
        }
    }

    // MARK: Rendering

    func testTranscriptLineTemplate() {
        XCTAssertEqual(CanonicalRendering.transcriptLine(channel: .local, text: "hello", offset: 872), "[14:32] Me: hello")
        XCTAssertEqual(CanonicalRendering.transcriptLine(channel: .remote, text: "hi", offset: 0), "[00:00] Them: hi")
    }

    func testFragmentInjectionAtEffectiveAnchor() {
        let segments = [
            SegmentRecord(sessionId: UUID(), channel: .remote, text: "early talk", startOffset: 80, endOffset: 90),
            SegmentRecord(sessionId: UUID(), channel: .remote, text: "pricing talk", startOffset: 110, endOffset: 130),
        ]
        // anchorOffset 140 with 20 s lookback → effective anchor 120: after the
        // 110 segment, before the note's own rendered (true) anchor 140.
        let fragments = [FragmentRecord(sessionId: UUID(), text: "pricing objection", anchorOffset: 140)]
        let rendered = CanonicalRendering.renderTranscriptWithFragments(segments, fragments: fragments, lookback: 20)
        let lines = rendered.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "[01:20] Them: early talk")
        XCTAssertEqual(lines[1], "[01:50] Them: pricing talk")
        XCTAssertEqual(lines[2], "[USER NOTE @ 02:20] pricing objection", "user note sorts at effective anchor (140−20=120 → after the 110 segment)")
    }

    func testLookbackClampsToZero() {
        let fragments = [FragmentRecord(sessionId: UUID(), text: "note", anchorOffset: 5)]
        let rendered = CanonicalRendering.renderTranscriptWithFragments([], fragments: fragments, lookback: 20)
        XCTAssertEqual(rendered, "[USER NOTE @ 00:05] note", "effective anchor clamps to ≥0 but the note shows the true anchor")
    }

    // MARK: Normalization

    func testNormalize() {
        XCTAssertEqual(
            CanonicalRendering.normalize("So — we should, DEFER the migration!"),
            "so we should defer the migration"
        )
    }
}

final class NotesValidatorTests: XCTestCase {

    private func segments(_ items: (Channel, String, Double, Double)...) -> [SegmentRecord] {
        items.map { SegmentRecord(sessionId: UUID(), channel: $0.0, text: $0.1, startOffset: $0.2, endOffset: $0.3) }
    }

    func testValidCitationPasses() {
        let segs = segments((.remote, "We agreed to defer the database migration until Q3", 860, 890))
        let markdown = """
        ### Decisions
        - [14:30] "defer the database migration until Q3" — Migration moves to Q3.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    func testQuoteMismatchIsFlagged() {
        let segs = segments((.remote, "We agreed to defer the database migration until Q3", 860, 890))
        let markdown = """
        ### Action items
        - [14:30] "buy everyone pizza immediately" — Order lunch.
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].kind, .quoteMismatch)
    }

    func testMissingTimestampIsFlagged() {
        let segs = segments((.remote, "short", 0, 10))
        let markdown = """
        ### Decisions
        - [45:00] "short" — Something at a timestamp the session never reached.
        """
        let findings = NotesValidator.validate(markdown: markdown, segments: segs)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].kind, .missingTimestamp)
    }

    func testQuoteMaySpanSegmentBoundaries() {
        // The quote spans two segments — matching must run against the
        // text-only rendering, not raw lines with [ts] Them: between them.
        let segs = segments(
            (.remote, "so we should defer", 860, 870),
            (.remote, "the migration doc review", 870, 880)
        )
        let markdown = """
        ### Decisions
        - [14:30] "defer the migration doc review" — Defer doc review.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    func testNormalizationTolerance() {
        // Model "cleans up" casing and punctuation; validator must not cry wolf.
        let segs = segments((.local, "okay, I'll send the quote by Thursday", 1200, 1230))
        let markdown = """
        ### Action items
        - [20:00] "I'll send the quote by Thursday" — Send quote.
        """
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    func testCurlyQuotesAccepted() {
        let segs = segments((.remote, "renewal at current rate", 100, 120))
        let markdown = "- [01:40] “renewal at current rate” — Renew at current rate."
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: segs).isEmpty)
    }

    func testEmptyTranscriptSkipsValidation() {
        let markdown = "- [14:30] \"anything\" — x"
        XCTAssertTrue(NotesValidator.validate(markdown: markdown, segments: []).isEmpty)
    }
}

final class PromptAssemblerTests: XCTestCase {

    func testExtractTitleSanitizes() {
        let md = """
        Title: **"Acme renewal — call!"**
        Summary
        Renewal likely.
        """
        XCTAssertEqual(PromptAssembler.extractTitle(from: md), "Acme renewal call")
    }

    func testExtractTitleCapsAtEightWords() {
        let md = "Title: one two three four five six seven eight nine ten\nSummary\nx"
        XCTAssertEqual(PromptAssembler.extractTitle(from: md)?.split(separator: " ").count, 8)
    }

    func testExtractTitleFallsBackToNil() {
        XCTAssertNil(PromptAssembler.extractTitle(from: "Summary\nNo title line here."))
        XCTAssertNil(PromptAssembler.extractTitle(from: "Title: **\"\"**\nSummary"))
    }

    func testUserPromptUsesCanonicalRendering() {
        let session = SessionRecord()
        let input = FusionInput(
            session: session,
            segments: [SegmentRecord(sessionId: session.id, channel: .local, text: "hi", startOffset: 10, endOffset: 12)],
            fragments: [FragmentRecord(sessionId: session.id, text: "note", anchorOffset: 35)]
        )
        let prompt = PromptAssembler.userPrompt(for: input)
        XCTAssertTrue(prompt.contains("[00:10] Me: hi"))
        XCTAssertTrue(prompt.contains("[USER NOTE @ 00:35] note"))
    }
}
