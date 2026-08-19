import Foundation
import Persistence

/// Canonical rendering — a three-way contract between the prompt assembler
/// (writes it), the fusion model (reads it and cites into it), and the
/// validator (parses both sides). ONE formatter, ONE parser, in this one file.
///
/// Any change here bumps PromptVersion.current — `prompt_version` covers
/// prompt text AND rendering format as a unit (SPEC §4.5). Do not "refactor"
/// this file without bumping.
public enum CanonicalRendering {

    // MARK: Timestamps

    /// Bare timestamp text: `MM:SS` below one hour, `H:MM:SS` from one hour
    /// (PER-TIMESTAMP rule — a long meeting contains both forms, SPEC §4.5).
    public static func timestampText(_ offset: TimeInterval) -> String {
        let total = max(0, Int(offset.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Bracketed citation form: `[14:32]` / `[1:02:14]`.
    public static func timestamp(_ offset: TimeInterval) -> String {
        "[\(timestampText(offset))]"
    }

    /// Parses `MM:SS`, `H:MM:SS`, with or without brackets. Accepts both
    /// forms unconditionally, anywhere (SPEC §4.5).
    public static func parseTimestamp(_ raw: String) -> TimeInterval? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("["), s.hasSuffix("]") {
            s.removeFirst()
            s.removeLast()
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let v = Int(part), v >= 0 else { return nil }
            values.append(v)
        }
        if values.count == 2 {
            return TimeInterval(values[0] * 60 + values[1])
        }
        return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
    }

    // MARK: Lines

    public static func channelLabel(_ channel: Channel) -> String {
        channel == .local ? "Me" : "Them"
    }

    /// Line template: `[14:32] Me: text` / `[1:02:14] Them: text`.
    public static func transcriptLine(channel: Channel, text: String, offset: TimeInterval) -> String {
        "\(timestamp(offset)) \(channelLabel(channel)): \(text)"
    }

    /// User-note injection: `[USER NOTE @ 14:32] pricing objection` (SPEC §4.5).
    public static func userNoteLine(text: String, anchorOffset: TimeInterval) -> String {
        "[USER NOTE @ \(timestampText(anchorOffset))] \(text)"
    }

    // MARK: Same-speaker blocks (prompt rendering only)

    /// Longest stretch of wall-clock a merged block may cover.
    ///
    /// **This number is pinned to the validator, not to taste.** A merged
    /// block carries ONE timestamp — its first segment's start — and the
    /// model cites that timestamp for anything it quotes out of the block.
    /// `NotesValidator` looks for the quote in segments overlapping
    /// ±`NotesValidator.matchWindow` (30 s) of the cited offset, so a block
    /// whose tail sat more than 30 s after its own head would cite a
    /// timestamp whose window no longer contains the quoted words — a false
    /// `quoteMismatch` on a perfectly genuine quote. 25 s keeps 5 s of
    /// headroom. Raising this above `NotesValidator.matchWindow` breaks
    /// citations; there is a test that says so.
    public static let maxMergedBlockSpan: TimeInterval = 25

    /// Merges consecutive same-speaker segments into one block: one
    /// timestamp, one `Me:`/`Them:` label, texts joined with a single space.
    ///
    /// Two-channel capture already keeps the speakers apart, so "consecutive"
    /// means adjacent in the time-sorted order *and* on the same channel — a
    /// block never spans speakers, which is what keeps
    /// `normalizedTextWindows`' per-channel haystacks a superset of every
    /// block's text (the same segments, the same joiner, the same order).
    ///
    /// - Parameters:
    ///   - barriers: sort keys that must not be swallowed — the effective
    ///     anchors of user notes. A note sorts *before* a transcript line at
    ///     the same key, so a segment starting at or after a barrier may not
    ///     merge into a block that started before it; otherwise the note would
    ///     drift to after speech it was written about.
    ///   - maxSpan: see `maxMergedBlockSpan`.
    public static func mergeConsecutiveSameSpeaker(
        _ segments: [SegmentRecord],
        barriers: [TimeInterval] = [],
        maxSpan: TimeInterval = maxMergedBlockSpan
    ) -> [SegmentRecord] {
        let sorted = segments.sorted {
            ($0.startOffset, $0.id.uuidString) < ($1.startOffset, $1.id.uuidString)
        }
        var result: [SegmentRecord] = []
        for segment in sorted {
            if var block = result.last,
               block.channel == segment.channel,
               segment.endOffset - block.startOffset <= maxSpan,
               !barriers.contains(where: { $0 > block.startOffset && $0 <= segment.startOffset }) {
                block.text += " " + segment.text
                block.endOffset = max(block.endOffset, segment.endOffset)
                result[result.count - 1] = block
            } else {
                result.append(segment)
            }
        }
        return result
    }

    // MARK: Renderings

    /// Full transcript rendering, one line per segment, sorted by start
    /// offset.
    ///
    /// Deliberately NOT merged: this is the verbatim transcript surface (the
    /// History window's Transcript tab), where a reader wants the segment
    /// timeline the recogniser actually produced. Same-speaker merging is a
    /// prompt-side token optimisation and lives in
    /// `renderTranscriptWithFragments`.
    public static func renderTranscript(_ segments: [SegmentRecord]) -> String {
        segments
            .sorted { $0.startOffset < $1.startOffset }
            .map { transcriptLine(channel: $0.channel, text: $0.text, offset: $0.startOffset) }
            .joined(separator: "\n")
    }

    /// Transcript with fragments injected inline at their EFFECTIVE anchor
    /// (`anchorOffset − lookback`, clamped to ≥ 0 — the lookback rule, SPEC §4.3).
    /// User notes sort before transcript lines at the same key.
    ///
    /// This is the PROMPT rendering: consecutive same-speaker segments merge
    /// into one block (`mergeConsecutiveSameSpeaker`), which removes a
    /// timestamp + speaker label per merged segment. User-note anchors act as
    /// merge barriers so a note never drifts past the speech it annotates.
    public static func renderTranscriptWithFragments(
        _ segments: [SegmentRecord],
        fragments: [FragmentRecord],
        lookback: TimeInterval
    ) -> String {
        struct Entry {
            let key: Double
            let order: Int   // 0 = user note, 1 = transcript
            let line: String
        }
        var entries: [Entry] = []
        var barriers: [TimeInterval] = []
        for fragment in fragments {
            let effective = max(0, fragment.anchorOffset - lookback)
            barriers.append(effective)
            entries.append(Entry(
                key: effective,
                order: 0,
                line: userNoteLine(text: fragment.text, anchorOffset: fragment.anchorOffset)
            ))
        }
        for segment in mergeConsecutiveSameSpeaker(segments, barriers: barriers) {
            entries.append(Entry(
                key: segment.startOffset,
                order: 1,
                line: transcriptLine(channel: segment.channel, text: segment.text, offset: segment.startOffset)
            ))
        }
        return entries
            .sorted { ($0.key, $0.order) < ($1.key, $1.order) }
            .map(\.line)
            .joined(separator: "\n")
    }

    // MARK: Normalization (validator matching — judgment-free, SPEC §4.5)

    /// Lowercase, strip punctuation, collapse whitespace. Both quote and
    /// transcript go through this before substring matching. No semantics.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.filter { !$0.isPunctuation }
        return stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Normalized text of segments overlapping `[offset − window, offset + window]`,
    /// **one haystack per channel**, each in time order.
    ///
    /// Quotes may span segment boundaries — matching runs against this
    /// text-only rendering (timestamp/channel tokens stripped), never against
    /// the raw rendering (SPEC §4.5).
    ///
    /// PER-CHANNEL IS LOAD-BEARING, do not "simplify" back to one interleaved
    /// string. Two-channel capture means the other speaker's segments are
    /// routinely time-interleaved with this speaker's: a single backchannel
    /// ("mm hmm") landing between two of the quoted speaker's segments used to
    /// splice itself into the middle of an otherwise verbatim quote and
    /// produce a false `quoteMismatch` — the validator crying wolf on the
    /// normal case. Nobody utters a quote that spans two speakers, so
    /// splitting by channel removes those false positives without weakening
    /// the check (it also stops a quote from "matching" a span it never had,
    /// which the interleaved haystack could invent).
    ///
    /// Channel order in the returned array is fixed (`local` then `remote`)
    /// so validator output is deterministic.
    public static func normalizedTextWindows(
        _ segments: [SegmentRecord],
        around offset: TimeInterval,
        window: TimeInterval
    ) -> [String] {
        let overlapping = segments
            .filter { $0.endOffset >= offset - window && $0.startOffset <= offset + window }
            .sorted { $0.startOffset < $1.startOffset }
        return [Channel.local, Channel.remote].compactMap { channel in
            let texts = overlapping.filter { $0.channel == channel }.map(\.text)
            guard !texts.isEmpty else { return nil }
            let normalized = normalize(texts.joined(separator: " "))
            return normalized.isEmpty ? nil : normalized
        }
    }
}
