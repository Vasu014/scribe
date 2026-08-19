import Foundation
import Persistence

/// Deterministic transcript pre-processing, run once before the transcript is
/// rendered into the fusion prompt (SPEC §4.5 prompt assembly).
///
/// # Why this exists
///
/// WhisperKit output carries three kinds of dead weight that cost input
/// tokens on every fusion call and actively hurt fusion quality:
///
/// * **Repetition loops** — on marginal audio the decoder latches onto a
///   phrase and emits it many times in a row ("thank you. thank you. thank
///   you. …"), sometimes for hundreds of words.
/// * **Filler-only segments** — a whole segment whose text is nothing but
///   `um` / `mm-hmm` / `[BLANK_AUDIO]`. Each one costs its own
///   `[MM:SS] Them: ` prefix on top of its own text.
/// * **Sub-second fragments** — a two-word segment costs ~8 tokens of
///   timestamp+label scaffolding to carry ~2 tokens of speech.
///
/// # Two hard constraints
///
/// 1. **Deterministic.** No model call, no heuristics that depend on
///    wall-clock, locale, or dictionary lookups. Same input → same output,
///    always. This runs *before* the only LLM call in the pipeline; if it
///    needed judgment it would need the model, and then it would need its own
///    validator.
///
/// 2. **Quote-matchable.** `NotesValidator` matches the model's verbatim
///    quotes against the transcript. Cleanup only ever *deletes* tokens — it
///    never rewrites, reorders, corrects or paraphrases — so cleaned text
///    introduces no word the transcript did not contain. Deletion does create
///    new adjacencies ("we will ship ~~um~~ on Friday"), which is exactly why
///    `NotesValidator` matches against the raw **and** the cleaned haystack
///    (see `NotesValidator.haystacks`): a quote lifted from either rendering
///    resolves, and neither direction manufactures a false `quoteMismatch`.
///
/// # Idempotent
///
/// `clean(clean(x)) == clean(x)`. FusionService cleans once before chunking
/// and `PromptAssembler.userPrompt` cleans again on the way into the prompt;
/// both must land on the same bytes or prompt caching (and the eval corpus)
/// would see two different transcripts for one session.
public enum TranscriptCleanup {

    // MARK: Tunables (deliberately conservative)

    /// A phrase must repeat at least this many times *consecutively* before
    /// it is treated as a decoder loop rather than as speech. Two repeats is
    /// ordinary emphasis ("no, no"), three is where humans stop and Whisper
    /// keeps going.
    public static let repetitionThreshold = 3

    /// Longest phrase considered for loop collapsing, in words.
    public static let maxLoopPhraseWords = 8

    /// Segments shorter than this fold into the preceding same-channel
    /// segment instead of paying for their own timestamp+label prefix.
    public static let shortFragmentDuration: TimeInterval = 1.0

    /// …but only across a gap this small: a sub-second segment after a long
    /// silence is a new utterance, not a fragment of the previous one.
    public static let shortFragmentMaxGap: TimeInterval = 2.0

    /// Non-lexical filler and non-speech markers. A segment is dropped only
    /// when **every** token is in this set, so "you know, the pricing" and a
    /// bare "yeah" (agreement — load-bearing in a decisions list) both stay.
    static let fillerTokens: Set<String> = [
        "um", "umm", "ummm", "uh", "uhh", "uhhh", "uhm", "hm", "hmm", "hmmm",
        "mm", "mmm", "mhm", "mhmm", "mmhmm", "mmhm", "huh", "er", "err", "erm",
        "ah", "ahh", "eh", "oh", "ooh",
        // Whisper's non-speech markers, post-`normalize` (brackets and
        // underscores are punctuation and are stripped by then).
        "blankaudio", "blank", "inaudible", "silence", "music", "applause",
        "laughter", "noise", "nospeech", "crosstalk",
    ]

    // MARK: Entry point

    /// Cleaned, time-sorted segments. Never returns a segment with empty
    /// text, and never returns an EMPTY transcript for a non-empty one: a
    /// meeting that is nothing but "um" is a strange meeting, but a user who
    /// recorded it is owed the notes, not a disappearance into a cleanup
    /// rule. In that case the input is handed back time-sorted and otherwise
    /// untouched.
    public static func clean(_ segments: [SegmentRecord]) -> [SegmentRecord] {
        let sorted = segments.sorted {
            ($0.startOffset, $0.id.uuidString) < ($1.startOffset, $1.id.uuidString)
        }

        // 1 + 2: normalize whitespace/punctuation, collapse in-segment loops,
        // drop what is left over when a segment was only filler.
        var working: [SegmentRecord] = []
        for var segment in sorted {
            segment.text = collapseRepeatedPhrases(normalizeText(segment.text))
            guard !segment.text.isEmpty, !isFillerOnly(segment.text) else { continue }
            working.append(segment)
        }

        // 3: a loop that spans segment boundaries (the same phrase emitted as
        // N consecutive segments) survives step 1 — collapse it here.
        working = collapseRepeatedSegments(working)

        // 4: fold sub-second fragments into their neighbour.
        working = mergeShortFragments(working)

        // Merging can butt two copies of a looped phrase together; re-running
        // the phrase collapse is what makes `clean` idempotent.
        let result = working.map { segment -> SegmentRecord in
            var copy = segment
            copy.text = collapseRepeatedPhrases(copy.text)
            return copy
        }
        return result.isEmpty ? sorted : result
    }

    // MARK: 1 — whitespace / punctuation

    /// Collapses whitespace runs (including newlines) to one space, removes
    /// space *before* closing punctuation, and caps runs of the same
    /// punctuation mark (`....` → `...`, `!!!` → `!`).
    ///
    /// Matching-neutral by construction: `CanonicalRendering.normalize`
    /// strips punctuation and collapses whitespace before comparing, so
    /// nothing here can change whether a quote matches.
    static func normalizeText(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var out: [Character] = []
        var runCharacter: Character?
        var runLength = 0

        for (index, word) in words.enumerated() {
            var pendingSpace = index > 0
            for character in word {
                if character.isPunctuation || character.isSymbol {
                    if pendingSpace, !Self.punctuationTakingLeadingSpace.contains(character) {
                        pendingSpace = false   // "word ," → "word,"
                    }
                    if character == runCharacter {
                        runLength += 1
                        let limit = character == "." ? 3 : 1
                        if runLength > limit { continue }
                    } else {
                        runCharacter = character
                        runLength = 1
                    }
                } else {
                    runCharacter = nil
                    runLength = 0
                }
                if pendingSpace {
                    out.append(" ")
                    pendingSpace = false
                }
                out.append(character)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Openers and quote marks legitimately follow a space; closers do not.
    private static let punctuationTakingLeadingSpace: Set<Character> =
        ["(", "[", "{", "\u{201C}", "\u{2018}", "\"", "'", "—", "–", "-", "$", "#", "@"]

    // MARK: 2 — in-segment repetition loops

    /// Collapses any phrase of 1…`maxLoopPhraseWords` words repeated
    /// `repetitionThreshold`+ times in a row down to a single copy, keeping
    /// the FIRST copy's original spelling and punctuation.
    ///
    /// Longest phrase wins, so "thank you thank you thank you" collapses as
    /// one 2-word phrase rather than as two separate 1-word runs.
    static func collapseRepeatedPhrases(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= repetitionThreshold else { return text }
        let keys = words.map(comparisonKey)

        var out: [String] = []
        var index = 0
        while index < words.count {
            var collapsed = false
            let longest = min(maxLoopPhraseWords, (words.count - index) / repetitionThreshold)
            var length = longest
            while length >= 1 {
                var repeats = 1
                var cursor = index + length
                while cursor + length <= words.count,
                      Array(keys[cursor..<(cursor + length)]) == Array(keys[index..<(index + length)]) {
                    repeats += 1
                    cursor += length
                }
                if repeats >= repetitionThreshold {
                    out.append(contentsOf: words[index..<(index + length)])
                    index = cursor
                    collapsed = true
                    break
                }
                length -= 1
            }
            if !collapsed {
                out.append(words[index])
                index += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Case- and punctuation-insensitive word identity — "Thank" and "thank."
    /// are the same word to a loop detector.
    static func comparisonKey(_ word: String) -> String {
        CanonicalRendering.normalize(word)
    }

    // MARK: 3 — filler-only segments

    /// True when every token is a filler / non-speech marker (and there is at
    /// least one token). `"Um, so we should ship"` is NOT filler-only.
    static func isFillerOnly(_ text: String) -> Bool {
        let normalized = CanonicalRendering.normalize(text)
        guard !normalized.isEmpty else { return true }
        return normalized.split(separator: " ").allSatisfy { fillerTokens.contains(String($0)) }
    }

    /// Drops the 2nd…Nth of `repetitionThreshold`+ consecutive same-channel
    /// segments carrying identical (normalized) text — a loop the decoder
    /// emitted as separate segments. The surviving segment keeps the first
    /// one's start and the last one's end, so the timeline never gains a hole.
    static func collapseRepeatedSegments(_ segments: [SegmentRecord]) -> [SegmentRecord] {
        var result: [SegmentRecord] = []
        var index = 0
        while index < segments.count {
            let head = segments[index]
            let key = CanonicalRendering.normalize(head.text)
            var end = index + 1
            while end < segments.count,
                  segments[end].channel == head.channel,
                  CanonicalRendering.normalize(segments[end].text) == key,
                  !key.isEmpty {
                end += 1
            }
            if end - index >= repetitionThreshold {
                var merged = head
                merged.endOffset = max(head.endOffset, segments[end - 1].endOffset)
                result.append(merged)
            } else {
                result.append(contentsOf: segments[index..<end])
            }
            index = end
        }
        return result
    }

    // MARK: 4 — sub-second fragments

    /// Folds a segment shorter than `shortFragmentDuration` into the
    /// immediately preceding segment when that segment is on the same channel
    /// and no more than `shortFragmentMaxGap` behind it. Text is joined with a
    /// single space — the same joiner
    /// `CanonicalRendering.normalizedTextWindows` uses to build the validator
    /// haystack, so a quote spanning the seam still matches.
    static func mergeShortFragments(_ segments: [SegmentRecord]) -> [SegmentRecord] {
        var result: [SegmentRecord] = []
        for segment in segments {
            let duration = segment.endOffset - segment.startOffset
            if duration < shortFragmentDuration,
               var previous = result.last,
               previous.channel == segment.channel,
               segment.startOffset - previous.endOffset <= shortFragmentMaxGap {
                previous.text += " " + segment.text
                previous.endOffset = max(previous.endOffset, segment.endOffset)
                result[result.count - 1] = previous
            } else {
                result.append(segment)
            }
        }
        return result
    }
}
