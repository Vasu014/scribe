import Foundation
import Persistence

/// Deterministic post-fusion validator (SPEC §4.5). Day one, no model calls,
/// no API cost. Two checks:
///   (a) timestamp exists — every cited timestamp lies within the transcript timeline
///   (b) quote matches — the normalized quote appears in the normalized
///       text-only rendering within ±30 s of the citation
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
    }

    public struct Finding: Codable, Equatable, Sendable {
        public let kind: FindingKind
        public let detail: String

        public init(kind: FindingKind, detail: String) {
            self.kind = kind
            self.detail = detail
        }
    }

    /// Citations look like: `[14:32] "verbatim quote …" — item text`.
    /// Curly quotes accepted; the model sometimes emits them.
    private static let citationRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}:\d{2}:\d{2}|\d{1,2}:\d{2})\]\s*[“"]([^“”"]{3,})[”"]"#
    )

    public static func citations(in markdown: String) -> [Citation] {
        let ns = markdown as NSString
        let matches = citationRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let tsGroup = ns.substring(with: match.range(at: 1))
            let quoteGroup = ns.substring(with: match.range(at: 2))
            guard let offset = CanonicalRendering.parseTimestamp(tsGroup) else { return nil }
            return Citation(
                offset: offset,
                quote: quoteGroup,
                rawLine: ns.substring(with: match.range)
            )
        }
    }

    /// Validate Decisions/Action-item citations against the transcript.
    /// Returns findings; empty array = green (exit-gate §2.5).
    public static func validate(markdown: String, segments: [SegmentRecord]) -> [Finding] {
        guard !segments.isEmpty else { return [] }
        let maxEnd = segments.map(\.endOffset).max() ?? 0
        var findings: [Finding] = []

        for citation in citations(in: markdown) {
            // (a) timestamp exists within the session timeline
            if citation.offset < 0 || citation.offset > maxEnd + 1 {
                findings.append(Finding(
                    kind: .missingTimestamp,
                    detail: "Cited \(CanonicalRendering.timestamp(citation.offset)) is outside the transcript timeline (0 – \(CanonicalRendering.timestampText(maxEnd)))."
                ))
                continue
            }
            // (b) normalized quote appears in the ±30 s text-only window
            let needle = CanonicalRendering.normalize(citation.quote)
            guard !needle.isEmpty else { continue }
            let haystack = CanonicalRendering.normalizedTextWindow(
                segments, around: citation.offset, window: matchWindow
            )
            if !haystack.contains(needle) {
                findings.append(Finding(
                    kind: .quoteMismatch,
                    detail: "Quote near \(CanonicalRendering.timestamp(citation.offset)) — “\(citation.quote)” — has no matching span in the transcript within ±\(Int(matchWindow)) s. Verify before sending."
                ))
            }
        }
        return findings
    }
}
