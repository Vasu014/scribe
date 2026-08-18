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

    // MARK: Renderings

    /// Full transcript rendering, sorted by start offset.
    public static func renderTranscript(_ segments: [SegmentRecord]) -> String {
        segments
            .sorted { $0.startOffset < $1.startOffset }
            .map { transcriptLine(channel: $0.channel, text: $0.text, offset: $0.startOffset) }
            .joined(separator: "\n")
    }

    /// Transcript with fragments injected inline at their EFFECTIVE anchor
    /// (`anchorOffset − lookback`, clamped to ≥ 0 — the lookback rule, SPEC §4.3).
    /// User notes sort before transcript lines at the same key.
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
        for fragment in fragments {
            let effective = max(0, fragment.anchorOffset - lookback)
            entries.append(Entry(
                key: effective,
                order: 0,
                line: userNoteLine(text: fragment.text, anchorOffset: fragment.anchorOffset)
            ))
        }
        for segment in segments {
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

    /// Normalized text of segments overlapping `[offset − window, offset + window]`.
    /// Quotes may span segment boundaries — matching runs against this
    /// text-only rendering (timestamp/channel tokens stripped), never against
    /// the raw rendering.
    public static func normalizedTextWindow(
        _ segments: [SegmentRecord],
        around offset: TimeInterval,
        window: TimeInterval
    ) -> String {
        let overlapping = segments
            .filter { $0.endOffset >= offset - window && $0.startOffset <= offset + window }
            .sorted { $0.startOffset < $1.startOffset }
        return normalize(overlapping.map(\.text).joined(separator: " "))
    }
}
