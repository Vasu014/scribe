import Foundation
import Persistence

/// `prompt_version` covers prompt text AND canonical rendering format as one
/// unit (SPEC §4.5). Bump on any change to either. This is what makes the
/// eval set a regression suite.
public enum PromptVersion {
    /// v1: initial format — [MM:SS]/[H:MM:SS] per-timestamp rule, Me/Them
    /// labels, [USER NOTE @ …] injection, timestamp+quote citations.
    public static let current = "1"
}

/// Fusion input — everything the prompt assembler needs, read from the store.
public struct FusionInput: Sendable, Equatable {
    public let session: SessionRecord
    public let segments: [SegmentRecord]
    public let fragments: [FragmentRecord]
    /// Effective-anchor lookback (SPEC §4.3; user setting, default 20 s).
    public let lookback: TimeInterval

    public init(session: SessionRecord, segments: [SegmentRecord], fragments: [FragmentRecord], lookback: TimeInterval = 20) {
        self.session = session
        self.segments = segments
        self.fragments = fragments
        self.lookback = lookback
    }
}

/// Fusion result — raw markdown plus the extracted (sanitized) title.
public struct FusionOutput: Sendable, Equatable {
    public let markdown: String
    public let title: String?

    public init(markdown: String, title: String?) {
        self.markdown = markdown
        self.title = title
    }
}

/// Transport seam for the frontier model (SPEC §4.5). Prompt assembly is pure
/// and lives in FusionKit (PromptAssembler); providers are thin transports.
/// Phase 2 relocates this server-side behind the same protocol — no upstream
/// changes. The Anthropic implementation arrives with the fusion task; UI and
/// SessionKit code against this seam in the meantime.
public protocol FusionProvider: Sendable {
    /// - Parameters:
    ///   - systemPrompt: assembled system prompt (role, format, grounding rules)
    ///   - userPrompt: assembled user message (rendered transcript + notes)
    ///   - temperature: grounded task — callers pass 0–0.3 (SPEC §4.5)
    /// - Returns: raw model output; parsing (title extraction, validation)
    ///   happens in FusionKit, not the provider.
    func complete(systemPrompt: String, userPrompt: String, temperature: Double) async throws -> String
}

/// Pure prompt assembly + output parsing. No transport, no side effects —
/// fully unit-testable. The system-prompt text is owned by the fusion task;
/// this file pins the mechanics (rendering calls, citation contract, title
/// extraction/sanitization).
public enum PromptAssembler {

    /// Full user message: rendered transcript with fragments injected at
    /// effective anchors (SPEC §4.5 prompt assembly).
    public static func userPrompt(for input: FusionInput) -> String {
        CanonicalRendering.renderTranscriptWithFragments(
            input.segments,
            fragments: input.fragments,
            lookback: input.lookback
        )
    }

    /// Extracts the `Title:` line (output format §0) and sanitizes it for
    /// storage/display (SPEC §4.5): strip markdown, quotes, trailing
    /// punctuation; collapse whitespace; cap length; empty → nil (caller
    /// falls back to date/duration).
    public static func extractTitle(from markdown: String) -> String? {
        guard let line = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("title") })
        else { return nil }

        var title = line
        // Drop a leading "Title:" (optionally markdown-bolded) and its space.
        if let colon = title.firstIndex(of: ":") {
            title = String(title[title.index(after: colon)...])
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown emphasis and quotes.
        for token in ["*", "_", "`", "\"", "“", "”", "'"] {
            title = title.replacingOccurrences(of: token, with: "")
        }
        // Em/en dashes read poorly in sidebar titles; treat as word separators.
        title = title.replacingOccurrences(of: "—", with: " ")
            .replacingOccurrences(of: "–", with: " ")
        // Strip trailing punctuation (keep interior).
        while let last = title.last, last.isPunctuation {
            title.removeLast()
        }
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        guard !title.isEmpty else { return nil }
        // ≤8 words per the output contract; hard cap at display width.
        let words = title.split(separator: " ")
        if words.count > 8 {
            title = words.prefix(8).joined(separator: " ")
        }
        if title.count > 64 {
            title = String(title.prefix(64))
        }
        return title
    }
}
