import Foundation
import Persistence

/// `prompt_version` covers prompt text AND canonical rendering format as one
/// unit (SPEC §4.5). Bump on any change to either. This is what makes the
/// eval set a regression suite.
public enum PromptVersion {
    /// v1: initial format — [MM:SS]/[H:MM:SS] per-timestamp rule, Me/Them
    /// labels, [USER NOTE @ …] injection, timestamp+quote citations.
    ///
    /// v2: same prompt text, different transcript bytes — deterministic
    /// cleanup (`TranscriptCleanup`: loop collapse, filler-only segments,
    /// sub-second fragment folding, whitespace/punctuation) plus
    /// same-speaker block merging in the rendering
    /// (`CanonicalRendering.mergeConsecutiveSameSpeaker`). The rendering
    /// format is versioned together with the prompt text, so this is a bump
    /// even though `SystemPrompt.v1` is untouched.
    public static let current = "2"
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
    /// Identifier of the backing model — recorded on note rows (SPEC §4.6
    /// `notes.model`) and eval cases (SPEC §4.5 `model`) so provenance
    /// follows every output.
    var modelIdentifier: String { get }

    /// - Parameters:
    ///   - systemPrompt: assembled system prompt (role, format, grounding rules)
    ///   - userPrompt: assembled user message (rendered transcript + notes)
    ///   - temperature: grounded task — callers pass 0–0.3 (SPEC §4.5)
    /// - Returns: raw model output; parsing (title extraction, validation)
    ///   happens in FusionKit, not the provider.
    func complete(systemPrompt: String, userPrompt: String, temperature: Double) async throws -> String

    /// Same call, plus one thing only the caller knows: whether this user
    /// message is a **reusable prefix** — the same bytes a later request in
    /// this session will send again (a Retry, or a second pass over the same
    /// transcript). Providers that support prompt caching put their
    /// breakpoint there; a breakpoint on content that is unique to one
    /// request buys nothing and still pays the cache-write premium.
    ///
    /// Defaulted in an extension, so existing providers (and every test
    /// double) conform unchanged.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        userPromptIsReusablePrefix: Bool
    ) async throws -> String
}

public extension FusionProvider {
    func complete(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        userPromptIsReusablePrefix: Bool
    ) async throws -> String {
        try await complete(systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature)
    }
}

/// Pure prompt assembly + output parsing. No transport, no side effects —
/// fully unit-testable. The system-prompt text is owned by the fusion task;
/// this file pins the mechanics (rendering calls, citation contract, title
/// extraction/sanitization).
public enum PromptAssembler {

    /// Full user message: deterministically cleaned transcript
    /// (`TranscriptCleanup`) rendered with fragments injected at effective
    /// anchors and consecutive same-speaker segments merged into blocks
    /// (SPEC §4.5 prompt assembly).
    ///
    /// Cleanup is idempotent, so it does not matter whether the caller
    /// already cleaned (`FusionService` does, before chunking).
    public static func userPrompt(for input: FusionInput) -> String {
        CanonicalRendering.renderTranscriptWithFragments(
            TranscriptCleanup.clean(input.segments),
            fragments: input.fragments,
            lookback: input.lookback
        )
    }

    /// User message for the final COMPOSE call of a chunked long meeting
    /// (SPEC §4.5): merges per-chunk notes into one set. Chunk notes carry
    /// global session timestamps already. Part of the versioned prompt text
    /// — any change bumps `PromptVersion.current`.
    public static func composeUserPrompt(chunkNotes: [String]) -> String {
        let parts = chunkNotes.enumerated().map { index, notes in
            "--- Notes for part \(index + 1) of \(chunkNotes.count) ---\n\(notes)"
        }
        return """
        The notes below were written in parts covering consecutive stretches of ONE long meeting; their timestamps are global session timestamps and are already correct. Consolidate them into a single set of notes in the required format: merge duplicates, keep the strongest evidence, and keep a verbatim quote with its existing timestamp for every Decision and Action item — never invent timestamps or quotes.

        \(parts.joined(separator: "\n\n"))
        """
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
