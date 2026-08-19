import Foundation
import Persistence

/// Deterministic post-fusion validator (SPEC §4.5). Day one, no model calls,
/// no API cost.
///
/// # What this surface is for
///
/// This is the hallucination audit. A user trusts it to catch a fabricated
/// quote before they send the notes on, so it has exactly two ways to fail,
/// and both are fatal to the feature:
///
/// * **False negative** — a fabricated quote passes silently. The user gets
///   *false assurance*, which is worse than no validator at all.
/// * **False positive** — a genuine quote is flagged. The user learns the
///   warnings are noise and stops reading them, which destroys the feature
///   just as thoroughly.
///
/// Every matching rule below is a deliberate position on that trade-off. Read
/// this comment before loosening or tightening any of them.
///
/// # The three checks
///
/// * **(a) timestamp exists** — every cited timestamp lies within the
///   transcript timeline.
/// * **(b) quote matches** — the normalized quote appears in the normalized
///   text-only rendering of *one channel* within ±30 s of the citation.
/// * **(c) citation present** — every list item under `Decisions` /
///   `Action items` carries a resolvable citation at all. SPEC §4.5 makes
///   `timestamp + verbatim quote + item text` the *shape* of those items, so
///   an item with no citation is an unsupported claim, not an exemption from
///   checking. Without (c) the validator only ever inspected the citations a
///   model chose to emit — a fabricated quote in a slightly different wrapper
///   (bolded timestamp, no timestamp, no quote) sailed through as "clean".
///
/// # Matching rules (and why each one is where it is)
///
/// **Citation shape is scanned, not regexed.** A citation is a timestamp
/// token and a quoted span found *in the same block*, paired in reading
/// order. The old implementation required `[ts]` to be immediately followed
/// by a quote, so the single most common thing a model actually emits —
/// `- **[01:40]** "…"` — produced zero citations and therefore zero findings.
/// Anything may now sit between the timestamp and the quote (bold markers,
/// a dash, a colon, an owner name); a quote *before* its timestamp also
/// pairs. Cost: a stray `[12:30]` and an unrelated quoted phrase on one line
/// get paired and checked. That direction is safe — it can only ask the
/// transcript a question, and the transcript answers it.
///
/// **Timestamps are bracketed or parenthesized only** — `[14:32]`,
/// `(1:02:14)`. Bare `14:32` is deliberately NOT a timestamp token: meeting
/// text is full of times ("let's meet at 3:30"), and treating those as
/// citations manufactures warnings about claims nobody made.
///
/// **Quote delimiters:** straight or curly double quotes (mixed pairs
/// accepted — models do that), curly single quotes, and straight single
/// quotes *only* when the opener is preceded by whitespace/line start and the
/// closer is followed by whitespace/line end/punctuation. That boundary rule
/// is what keeps `we'll`, `Bob's` and `teams'` from being read as quote
/// marks. Single-quoted quotes are off-format but common enough that
/// rejecting them would fire check (c) on a correctly grounded item.
///
/// **Quotes are matched per channel** — see
/// `CanonicalRendering.normalizedTextWindows`. A backchannel from the other
/// speaker used to split a verbatim quote and fire a false `quoteMismatch`.
///
/// **Quotes are matched against the raw transcript ∪ the cleaned one** — see
/// `HaystackSource`. The prompt renders `TranscriptCleanup.clean(...)`, so a
/// quote may legitimately read across a filler or a collapsed loop copy that
/// the raw segments still contain.
///
/// **`None recorded.` and friends are exempt** from check (c), as are
/// continuation lines and indented sub-bullets (they fold into their parent
/// item rather than each demanding their own citation). Sections other than
/// Decisions / Action items are never *required* to cite — but any citation
/// they do contain is still checked by (a) and (b).
public enum NotesValidator {

    public static let matchWindow: TimeInterval = 30

    public struct Citation: Equatable, Sendable {
        public let offset: TimeInterval
        public let quote: String
        public let rawLine: String
    }

    public enum FindingKind: String, Codable, Sendable {
        case missingTimestamp
        case quoteMismatch
        /// A `Decisions` / `Action items` item that carries no resolvable
        /// citation — nothing about it could be checked (SPEC §4.5).
        case missingCitation
    }

    public struct Finding: Codable, Equatable, Sendable {
        public let kind: FindingKind
        public let detail: String

        public init(kind: FindingKind, detail: String) {
            self.kind = kind
            self.detail = detail
        }
    }

    /// Section headings whose list items MUST cite (SPEC §4.5 output format
    /// §3/§4: "each item = timestamp + verbatim transcript quote + item text").
    static let citedSections: Set<String> = [
        "decisions", "decision", "action items", "action item", "actions",
    ]

    // MARK: - Public API

    /// Every resolvable `timestamp + quote` pair in the notes, in document
    /// order. Pairing is block-local and reading-order based — see the type
    /// comment for the exact shape rules.
    public static func citations(in markdown: String) -> [Citation] {
        blocks(in: markdown).flatMap { citations(inBlock: $0.text) }
    }

    /// Validate the notes against the transcript. Returns findings; empty
    /// array = green (exit-gate §2.5).
    public static func validate(markdown: String, segments: [SegmentRecord]) -> [Finding] {
        // No transcript = nothing to validate against. (A session with no
        // segments never reaches fusion; see FusionService.emptyTranscript.)
        guard !segments.isEmpty else { return [] }
        let maxEnd = segments.map(\.endOffset).max() ?? 0
        let haystacks = HaystackSource(segments: segments)
        var findings: [Finding] = []

        for block in blocks(in: markdown) {
            let blockCitations = citations(inBlock: block.text)

            // (c) a Decisions / Action-items item must actually cite something.
            if block.isListItem,
               let section = block.section,
               citedSections.contains(section),
               !isNoneMarker(block.text),
               blockCitations.isEmpty {
                findings.append(Finding(
                    kind: .missingCitation,
                    detail: missingCitationDetail(for: block.text)
                ))
            }

            for citation in blockCitations {
                // (a) timestamp exists within the session timeline
                if citation.offset < 0 || citation.offset > maxEnd + 1 {
                    findings.append(Finding(
                        kind: .missingTimestamp,
                        detail: "Cited \(CanonicalRendering.timestamp(citation.offset)) is outside the transcript timeline (0 – \(CanonicalRendering.timestampText(maxEnd)))."
                    ))
                    continue
                }
                // (b) normalized quote appears in the ±30 s text-only window
                // of a SINGLE channel (never across speakers).
                let needle = CanonicalRendering.normalize(citation.quote)
                guard !needle.isEmpty else { continue }
                if !haystacks.matches(needle, around: citation.offset) {
                    findings.append(Finding(
                        kind: .quoteMismatch,
                        detail: "Quote near \(CanonicalRendering.timestamp(citation.offset)) — “\(citation.quote)” — has no matching span in the transcript within ±\(Int(matchWindow)) s. Verify before sending."
                    ))
                }
            }
        }
        return findings
    }

    // MARK: - Haystacks (raw ∪ cleaned)

    /// The text a quote is allowed to have come from.
    ///
    /// The fusion prompt renders the **cleaned** transcript
    /// (`TranscriptCleanup`), while this validator is also called straight
    /// from the History window against the **raw** segments in the store. A
    /// quote lifted from either one is a genuine quote, so both are searched
    /// and a match in either passes.
    ///
    /// Why this is not a hole in the audit: cleanup only ever *deletes*
    /// tokens (loop copies, filler-only segments) — it never invents a word,
    /// reorders speech, or crosses channels. So the cleaned haystack contains
    /// no vocabulary the raw haystack lacked; the only quotes it newly admits
    /// are ones that read across a deleted filler or a deleted loop copy,
    /// which is exactly the text the model was shown. A fabricated quote
    /// matches neither.
    ///
    /// Same-speaker merging (`CanonicalRendering.mergeConsecutiveSameSpeaker`)
    /// needs no entry here: a merged block's text is the same segments, in
    /// the same order, joined by the same single space that
    /// `normalizedTextWindows` uses — it is already a substring of the
    /// per-channel haystack. What merging *does* move is the cited
    /// timestamp, which is why blocks are capped at
    /// `CanonicalRendering.maxMergedBlockSpan` < `matchWindow`.
    struct HaystackSource {
        let raw: [SegmentRecord]
        /// `nil` when cleanup was a no-op — no point searching twice.
        let cleaned: [SegmentRecord]?

        init(segments: [SegmentRecord]) {
            self.raw = segments
            let cleaned = TranscriptCleanup.clean(segments)
            self.cleaned = cleaned == segments ? nil : cleaned
        }

        func matches(_ needle: String, around offset: TimeInterval) -> Bool {
            let windows = CanonicalRendering.normalizedTextWindows(
                raw, around: offset, window: matchWindow
            )
            if windows.contains(where: { $0.contains(needle) }) { return true }
            guard let cleaned else { return false }
            return CanonicalRendering
                .normalizedTextWindows(cleaned, around: offset, window: matchWindow)
                .contains { $0.contains(needle) }
        }
    }

    // MARK: - Block model

    /// One logical unit of the notes: a list item (with its wrapped
    /// continuation lines and sub-bullets folded in), or a paragraph.
    /// Citations pair *within* a block, so a wrapped item whose timestamp and
    /// quote straddle a line break still resolves.
    struct Block: Equatable {
        /// Normalized heading this block sits under (`nil` before any heading).
        let section: String?
        let isListItem: Bool
        /// Joined text, bullet markers stripped.
        let text: String
    }

    static func blocks(in markdown: String) -> [Block] {
        var result: [Block] = []
        var section: String?
        var pending: (isListItem: Bool, text: String)?

        func flush() {
            if let pending {
                result.append(Block(section: section, isListItem: pending.isListItem, text: pending.text))
            }
            pending = nil
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                continue
            }
            let bullet = bulletBody(trimmed)
            if bullet == nil, let name = headingName(trimmed) {
                flush()
                section = name
                continue
            }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            if let bullet, indent < 2 || pending == nil {
                // Top-level list item: a new block.
                flush()
                pending = (true, bullet)
            } else if pending != nil {
                // Wrapped continuation or indented sub-bullet: fold into the
                // parent item rather than demanding its own citation.
                pending?.text += " " + (bullet ?? trimmed)
            } else {
                pending = (false, trimmed)
            }
        }
        flush()
        return result
    }

    /// `- x`, `* x`, `+ x`, `1. x`, `2) x` → `x`; otherwise `nil`.
    static func bulletBody(_ trimmed: String) -> String? {
        var chars = Array(trimmed)
        guard !chars.isEmpty else { return nil }
        if "-*+•".contains(chars[0]) {
            guard chars.count > 1, chars[1] == " " || chars[1] == "\t" else { return nil }
            return String(chars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        var index = 0
        while index < chars.count, chars[index].isNumber { index += 1 }
        guard index > 0, index < chars.count, chars[index] == "." || chars[index] == ")" else { return nil }
        index += 1
        guard index < chars.count, chars[index] == " " else { return nil }
        chars.removeFirst(index)
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// Recognizes `## Decisions`, `**Decisions**`, `Decisions:` and friends;
    /// returns the normalized heading text. Never called on bullet lines.
    static func headingName(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("#") {
            let text = trimmed.drop { $0 == "#" }
            return normalizedHeading(String(text))
        }
        let stripped = trimmed.hasSuffix(":") ? String(trimmed.dropLast()) : trimmed
        // Fully emphasized line, e.g. `**Decisions**` / `__Action items__`.
        for marker in ["**", "__", "*", "_"] where stripped.hasPrefix(marker) && stripped.hasSuffix(marker)
            && stripped.count > 2 * marker.count {
            let inner = stripped.dropFirst(marker.count).dropLast(marker.count)
            guard !inner.contains(marker) else { continue }
            return normalizedHeading(String(inner))
        }
        // Bare `Decisions:` — short, unemphasized, colon-terminated.
        guard trimmed.hasSuffix(":") else { return nil }
        let name = normalizedHeading(stripped)
        guard !name.isEmpty, name.split(separator: " ").count <= 5 else { return nil }
        return name
    }

    private static func normalizedHeading(_ text: String) -> String {
        CanonicalRendering.normalize(text)
    }

    /// `None recorded.` / `No decisions.` / `N/A` — an honest empty section,
    /// not an uncited claim. Exempt from check (c).
    ///
    /// The marker must be SHORT as well as start with a none-word. Matching
    /// on the prefix alone exempted any item that happened to begin with one,
    /// so a real, uncited Decision — "None of the proposed vendors met the
    /// security bar, so we are staying with Acme." — read as an empty section
    /// and the whole item went unchecked. That is the audit surface reporting
    /// green on a claim nobody verified, which is the one failure mode this
    /// validator exists to prevent. Every phrasing a model actually uses for
    /// an empty section ("None recorded.", "No decisions were made.",
    /// "No action items were recorded.", "Nothing to report.") fits inside
    /// the cap; a sentence that goes on to assert something does not.
    static let noneMarkerWordLimit = 6

    static func isNoneMarker(_ text: String) -> Bool {
        let n = CanonicalRendering.normalize(text)
        if n.isEmpty || n == "na" || n == "n a" { return true }
        guard n.split(separator: " ").count <= noneMarkerWordLimit else { return false }
        for prefix in ["none", "nothing", "no decisions", "no action", "no actions", "no items"]
        where n.hasPrefix(prefix) {
            return true
        }
        return false
    }

    private static func missingCitationDetail(for item: String) -> String {
        let chars = Array(item)
        let hasTimestamp = !timestampTokens(in: chars).isEmpty
        let hasQuote = !quoteSpans(in: chars).isEmpty
        let excerpt = shorten(item)
        let reason: String
        switch (hasTimestamp, hasQuote) {
        case (true, false):
            reason = "cites a timestamp but carries no verbatim quote"
        case (false, true):
            reason = "carries a quote but cites no timestamp"
        default:
            reason = "carries neither a timestamp nor a verbatim quote"
        }
        return "“\(excerpt)” \(reason), so nothing about it was checked against the transcript. SPEC §4.5 requires timestamp + verbatim quote on every Decision and Action item."
    }

    private static func shorten(_ text: String, limit: Int = 72) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    // MARK: - Citation scanning

    /// Pairs each timestamp token in a block with a quoted span: the first
    /// unconsumed quote after it, else the nearest unconsumed quote before it.
    static func citations(inBlock text: String) -> [Citation] {
        let chars = Array(text)
        let stamps = timestampTokens(in: chars)
        guard !stamps.isEmpty else { return [] }
        var quotes = quoteSpans(in: chars)
        guard !quotes.isEmpty else { return [] }

        var result: [Citation] = []
        for stamp in stamps {
            var pick: Int?
            if let after = quotes.firstIndex(where: { $0.range.lowerBound >= stamp.range.upperBound }) {
                pick = after
            } else if let before = quotes.lastIndex(where: { $0.range.upperBound <= stamp.range.lowerBound }) {
                pick = before
            }
            guard let pick else { continue }
            let quote = quotes.remove(at: pick)
            let lower = min(stamp.range.lowerBound, quote.range.lowerBound)
            let upper = max(stamp.range.upperBound, quote.range.upperBound)
            result.append(Citation(
                offset: stamp.offset,
                quote: quote.text,
                rawLine: String(chars[lower..<upper])
            ))
        }
        return result
    }

    /// `[MM:SS]`, `[H:MM:SS]`, `(MM:SS)`, `(H:MM:SS)`. Bare (unbracketed)
    /// times are deliberately not tokens — see the type comment.
    static func timestampTokens(in chars: [Character]) -> [(range: Range<Int>, offset: TimeInterval)] {
        var result: [(range: Range<Int>, offset: TimeInterval)] = []
        var index = 0
        while index < chars.count {
            let opener = chars[index]
            guard opener == "[" || opener == "(" else {
                index += 1
                continue
            }
            let closer: Character = opener == "[" ? "]" : ")"
            // A timestamp is at most `12:34:56` — 8 characters.
            let limit = min(chars.count, index + 10)
            var end = index + 1
            while end < limit, chars[end] != closer { end += 1 }
            guard end < limit, chars[end] == closer else {
                index += 1
                continue
            }
            let inner = String(chars[(index + 1)..<end])
            if isTimestampText(inner), let offset = CanonicalRendering.parseTimestamp(inner) {
                result.append((index..<(end + 1), offset))
                index = end + 1
            } else {
                index += 1
            }
        }
        return result
    }

    /// `\d{1,2}:\d{2}` or `\d{1,2}:\d{2}:\d{2}` — exact, no surrounding text.
    private static func isTimestampText(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        for (index, part) in parts.enumerated() {
            guard part.allSatisfy(\.isNumber) else { return false }
            let expected = index == 0 ? 1...2 : 2...2
            guard expected.contains(part.count) else { return false }
        }
        return true
    }

    /// Quoted spans, left to right, non-overlapping. Content is trimmed and
    /// must be ≥3 characters (matching the old regex's `{3,}` floor — one- or
    /// two-character "quotes" are punctuation accidents, not citations) AND
    /// must survive normalization with something left in it.
    ///
    /// That second rule is what stops a placeholder from counting as
    /// evidence. `- [01:40] "..." — Ship on Friday.` used to produce a
    /// citation whose normalized needle was empty; check (b) skipped it as
    /// unmatchable and check (c) considered the item cited, so an item with
    /// no quote at all passed the hallucination audit CLEAN. A quote made
    /// only of punctuation is not a verbatim transcript quote — it is the
    /// absence of one, and must be reported as `missingCitation`.
    static func quoteSpans(in chars: [Character]) -> [(range: Range<Int>, text: String)] {
        let doubleOpeners: Set<Character> = ["\"", "\u{201C}"]
        let doubleClosers: Set<Character> = ["\"", "\u{201D}"]

        var result: [(range: Range<Int>, text: String)] = []
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            var closerTest: ((Int) -> Bool)?
            if doubleOpeners.contains(ch) {
                closerTest = { doubleClosers.contains(chars[$0]) }
            } else if ch == "\u{2018}" {
                closerTest = { chars[$0] == "\u{2019}" }
            } else if ch == "'" , isStraightSingleOpener(chars, index) {
                closerTest = { chars[$0] == "'" && isStraightSingleCloser(chars, $0) }
            }
            guard let closerTest else {
                index += 1
                continue
            }
            var end = index + 1
            while end < chars.count, !closerTest(end) { end += 1 }
            guard end < chars.count else {
                index += 1
                continue
            }
            let inner = String(chars[(index + 1)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if inner.count >= 3, !CanonicalRendering.normalize(inner).isEmpty {
                result.append((index..<(end + 1), inner))
            }
            index = end + 1
        }
        return result
    }

    /// A straight `'` opens a quote only at a word boundary — never inside
    /// `we'll` or `Bob's`.
    private static func isStraightSingleOpener(_ chars: [Character], _ index: Int) -> Bool {
        let previousOK = index == 0 || chars[index - 1].isWhitespace || "([—–-:".contains(chars[index - 1])
        let nextOK = index + 1 < chars.count && !chars[index + 1].isWhitespace
        return previousOK && nextOK
    }

    private static func isStraightSingleCloser(_ chars: [Character], _ index: Int) -> Bool {
        let previousOK = index > 0 && !chars[index - 1].isWhitespace
        let nextOK = index + 1 >= chars.count
            || chars[index + 1].isWhitespace
            || ")]—–-,.;:!?".contains(chars[index + 1])
        return previousOK && nextOK
    }
}
