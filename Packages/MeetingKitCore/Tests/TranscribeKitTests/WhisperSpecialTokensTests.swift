import XCTest
import Persistence
@testable import TranscribeKit

// MARK: - Token grammar (unit)

/// Regression cover for the transcript-corruption bug: WhisperKit decodes
/// its control vocabulary into segment text unless `skipSpecialTokens` is
/// set, and the raw tokens were being persisted, exported, and fed to fusion
/// as the grounding transcript (SPEC §4.2).
final class WhisperSpecialTokensTests: XCTestCase {

    /// The exact string observed in the store after the first real meeting.
    func testOwnerObservedSegmentIsCleaned() {
        let raw = "<|startoftranscript|><|0.00|> This is just a small test waiting.<|2.48|><|endoftext|>"
        XCTAssertEqual(WhisperSpecialTokens.strip(raw), "This is just a small test waiting.")
    }

    func testControlTokensAreStripped() {
        let cases = [
            "<|startoftranscript|>",
            "<|endoftext|>",
            "<|startofprev|>",
            "<|startoflm|>",
            "<|nospeech|>",
            "<|nocaptions|>",
            "<|notimestamps|>",
            "<|transcribe|>",
            "<|translate|>",
        ]
        for token in cases {
            XCTAssertEqual(
                WhisperSpecialTokens.strip("\(token)hello\(token)"),
                "hello",
                "\(token) must not survive"
            )
        }
    }

    func testLanguageTagsAreStripped() {
        for tag in ["<|en|>", "<|fr|>", "<|zh|>", "<|yue|>", "<|haw|>"] {
            XCTAssertEqual(WhisperSpecialTokens.strip("\(tag) bonjour"), "bonjour", "\(tag) must not survive")
        }
    }

    /// Timestamp tokens run at 0.02 s granularity across the 30 s window.
    func testTimestampTokensAreStripped() {
        for stamp in ["<|0.00|>", "<|2.48|>", "<|0.02|>", "<|29.98|>", "<|1234.56|>"] {
            XCTAssertEqual(WhisperSpecialTokens.strip("\(stamp)word\(stamp)"), "word", "\(stamp) must not survive")
        }
    }

    /// A full prefill sequence, the shape WhisperKit emits with
    /// `skipSpecialTokens: false`.
    func testFullPrefillSequenceIsCleaned() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|notimestamps|><|0.00|> Ship it Friday."
            + "<|3.02|><|endoftext|>"
        XCTAssertEqual(WhisperSpecialTokens.strip(raw), "Ship it Friday.")
    }

    /// Nothing but tokens must collapse to empty so the caller can drop the
    /// segment rather than persist a blank row.
    func testTokenOnlyTextBecomesEmpty() {
        XCTAssertEqual(WhisperSpecialTokens.strip("<|startoftranscript|><|0.00|><|endoftext|>"), "")
        XCTAssertEqual(WhisperSpecialTokens.strip("<|nospeech|>"), "")
        XCTAssertEqual(WhisperSpecialTokens.strip("  <|en|>   <|1.00|>  "), "")
        XCTAssertEqual(WhisperSpecialTokens.strip(""), "")
    }

    /// Normal text is untouched (no accidental rewriting of real speech).
    func testNormalTextIsUnchanged() {
        let text = "So the plan is: Dana owns the migration, and we ship Friday."
        XCTAssertEqual(WhisperSpecialTokens.strip(text), text)
    }

    /// A speaker (or dictated code) can produce `<|` — only the real token
    /// grammar may be removed.
    func testAngleBracketPipeTextSurvives() {
        let survivors = [
            "use <| as the pipe operator",
            "if a < b then a <|> b",
            "the token <|foo|> is not a whisper token",
            "compare x <| y and y |> x",
            "<|not-a-token|> stays",
            "<|s|> is too short to be a language tag",
            "<|12|> has no decimals",
        ]
        for text in survivors {
            XCTAssertEqual(WhisperSpecialTokens.strip(text), text, "must not corrupt: \(text)")
        }
    }

    /// Whitespace left behind is normalised: no leading space, no double
    /// space where a token used to sit.
    func testWhitespaceAroundStrippedTokensIsNormalised() {
        XCTAssertEqual(WhisperSpecialTokens.strip("<|0.00|> leading space removed"), "leading space removed")
        XCTAssertEqual(WhisperSpecialTokens.strip("one <|1.00|> two"), "one two")
        XCTAssertEqual(WhisperSpecialTokens.strip("trailing <|endoftext|>   "), "trailing")
        XCTAssertEqual(WhisperSpecialTokens.strip("line\n<|2.00|>\nbreak"), "line break")
    }

    /// Idempotent: stripping already-clean text is a no-op, so applying the
    /// defensive strip at both the engine seam and the emission chokepoint
    /// cannot compound.
    func testStripIsIdempotent() {
        let raw = "<|startoftranscript|><|0.00|> Twice is fine.<|1.20|><|endoftext|>"
        let once = WhisperSpecialTokens.strip(raw)
        XCTAssertEqual(WhisperSpecialTokens.strip(once), once)
    }
}

// MARK: - Through the emission path (integration)

/// The strip lives at the single point where `TranscriptSegment.text` is
/// produced from engine output, so it holds for ANY `WhisperEngine` — not
/// just the WhisperKit one whose decode options were fixed.
final class SegmentTokenStrippingTests: XCTestCase {

    func testEmittedSegmentTextCarriesNoTokens() async throws {
        let engine = FakeEngine()
        engine.respond = { _ in
            [WhisperHypothesis(
                text: "<|startoftranscript|><|0.00|> This is just a small test waiting.<|2.48|><|endoftext|>",
                startSeconds: 0,
                endSeconds: 2.48
            )]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        let segment = try XCTUnwrap(collector.snapshot.first)
        XCTAssertEqual(segment.text, "This is just a small test waiting.")
        XCTAssertFalse(segment.text.contains("<|"), "no token may reach the store")
        // Offsets still come from the hypothesis, not from the stripped text.
        XCTAssertEqual(segment.startOffset, 0.0, accuracy: 0.05)
        XCTAssertEqual(segment.endOffset, 2.48, accuracy: 0.05)
    }

    /// A window the model answered with tokens only emits NOTHING — not a
    /// blank segment row.
    func testTokenOnlyHypothesisEmitsNoSegment() async {
        let engine = FakeEngine()
        engine.respond = { _ in
            [WhisperHypothesis(text: "<|startoftranscript|><|0.00|><|endoftext|>", startSeconds: 0, endSeconds: 2.0)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .local, into: continuation)
        continuation.finish()
        await task.value

        XCTAssertTrue(collector.segments.isEmpty, "a token-only decode must not persist a blank segment")
    }

    /// Multiple hypothesis lines: each is cleaned before joining, and the
    /// join does not reintroduce stray spacing.
    func testMultipleHypothesesAreJoinedCleanly() async throws {
        let engine = FakeEngine()
        engine.respond = { _ in
            [
                WhisperHypothesis(text: "<|startoftranscript|><|en|><|0.00|> First line.", startSeconds: 0, endSeconds: 1.0),
                WhisperHypothesis(text: "<|1.00|><|nospeech|>", startSeconds: 1.0, endSeconds: 1.2),
                WhisperHypothesis(text: "<|1.20|> Second line.<|2.00|><|endoftext|>", startSeconds: 1.2, endSeconds: 2.0),
            ]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        let segment = try XCTUnwrap(collector.snapshot.first)
        XCTAssertEqual(segment.text, "First line. Second line.")
    }

    /// Legitimate speech is emitted byte-for-byte.
    func testNormalHypothesisIsEmittedUnchanged() async throws {
        let engine = FakeEngine()
        engine.respond = { _ in
            [WhisperHypothesis(text: "We agreed to ship on Friday.", startSeconds: 0, endSeconds: 2.0)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        XCTAssertEqual(try XCTUnwrap(collector.snapshot.first).text, "We agreed to ship on Friday.")
    }
}
