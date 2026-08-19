import Foundation
import Persistence

/// Terminal outcome of one fusion run (SPEC §4.5 failure semantics). Never
/// thrown — the caller (SessionKit / App) derives the Retry UI from
/// `.failure` and `.storedWithFindings`, and builds the auto-saved eval case
/// from the findings (SPEC §4.5: failures are surfaced in UI and auto-saved
/// to the eval set).
public enum FusionRunOutcome: Equatable, Sendable {
    /// Provider succeeded, validator clean: note stored as canonical, session
    /// title updated, session state → `complete`.
    case success(noteId: UUID, title: String?)
    /// Provider succeeded but the validator flagged citations: the note IS
    /// stored (canonical) so the warning-card UI and eval-set auto-save have
    /// their inputs; findings are returned; the session stays in `processing`
    /// so Retry remains available (SPEC §4.5: fusion errors leave the session
    /// in `processing` with Retry).
    case storedWithFindings(noteId: UUID, title: String?, findings: [NotesValidator.Finding])
    /// Provider/transport (or local store) failure: nothing stored, the
    /// session stays in `processing`; the error is for the Retry UI.
    case failure(FusionServiceError)
}

/// Local failures surfaced through `FusionRunOutcome.failure`.
public enum FusionServiceError: Error, Equatable, Sendable {
    /// The provider threw; description goes to the Retry UI.
    case provider(String)
    /// The session has no transcript segments — nothing to fuse.
    case emptyTranscript
    /// A local store read/write failed; description for diagnostics.
    case store(String)
}

/// Orchestrates one fusion run (SPEC §4.5 + §3.2 data flow): reads inputs
/// from the store, assembles prompts (`PromptAssembler` +
/// `CanonicalRendering`), calls the provider, extracts/sanitizes the title,
/// runs the deterministic validator, stores the note, and updates the
/// session. Long meetings chunk through the same provider seam (SPEC §4.5
/// operational rules).
public final class FusionService: Sendable {

    /// Beyond ~25k words, chunk by VAD gaps → per-chunk notes → final compose
    /// (SPEC §4.5 long-meeting stopgap; full map-reduce is Phase 2).
    public static let chunkWordLimit = 25_000
    /// Grounding-task temperature (SPEC §4.5: 0–0.3; callers use this value).
    public static let temperature = 0.2

    private let store: MeetingStore

    /// - Parameter store: all inputs are read from and all outputs written to
    ///   this store — fusion never talks to other components directly
    ///   (SPEC §3.1 architectural rule).
    public init(store: MeetingStore) {
        self.store = store
    }

    // MARK: Run

    /// Runs one fusion pass for a session.
    ///
    /// - Parameters:
    ///   - session: the session record to fuse (used as the base for updates;
    ///     callers pass the current row).
    ///   - lookback: effective-anchor lookback in seconds (SPEC §4.3 user
    ///     setting, default 20 s).
    ///   - provider: transport for the frontier model (mocked in tests).
    ///   - chunkWordLimit: long-meeting threshold in words (SPEC §4.5 ~25k;
    ///     injectable so tests exercise chunking with small transcripts).
    /// - Returns: the terminal outcome; never throws. On provider failure or
    ///   validator findings the session is left in `processing` so the Retry
    ///   UI (SPEC §5 derived `failed` state) stays available.
    public func fuse(
        session: SessionRecord,
        lookback: TimeInterval = 20,
        provider: any FusionProvider,
        chunkWordLimit: Int = FusionService.chunkWordLimit
    ) async -> FusionRunOutcome {
        let rawSegments: [SegmentRecord]
        let fragments: [FragmentRecord]
        do {
            rawSegments = try store.segments(sessionId: session.id)
            fragments = try store.fragments(sessionId: session.id)
        } catch {
            return .failure(.store("failed reading inputs: \(String(describing: error))"))
        }

        // Zero-fragment mode is normal (empty scratchpad, SPEC §4.5); an
        // empty TRANSCRIPT is not — fail fast instead of burning an API call.
        guard !rawSegments.isEmpty else {
            return .failure(.emptyTranscript)
        }

        // Deterministic cleanup runs BEFORE chunking, not just before
        // rendering: a Whisper repetition loop can add thousands of words to
        // a transcript, and word count is what decides whether this session
        // costs one API call or four. Cleanup is idempotent, so
        // `PromptAssembler.userPrompt` cleaning again is a no-op — and it
        // never empties a non-empty transcript, so `.emptyTranscript` still
        // means exactly what it meant before (no segments at all).
        let segments = TranscriptCleanup.clean(rawSegments)

        let markdown: String
        do {
            let chunks = Self.chunkIfNeeded(segments: segments, wordLimit: chunkWordLimit)
            if chunks.count == 1 {
                let input = FusionInput(
                    session: session,
                    segments: segments,
                    fragments: fragments,
                    lookback: lookback
                )
                markdown = try await complete(input: input, provider: provider)
            } else {
                markdown = try await runChunked(
                    session: session,
                    chunks: chunks,
                    fragments: fragments,
                    lookback: lookback,
                    provider: provider
                )
            }
        } catch {
            // SPEC §4.5: fusion errors leave the session in `processing`
            // with Retry; nothing is stored.
            return .failure(.provider(Self.describe(error)))
        }

        // Parse + validate (deterministic, no model calls, SPEC §4.5).
        let title = PromptAssembler.extractTitle(from: markdown)
        // Validate against the RAW segments: the timeline (check a) must be
        // the one the recogniser produced, and `NotesValidator` searches the
        // cleaned rendering as well, so a quote taken from either resolves.
        let findings = NotesValidator.validate(markdown: markdown, segments: rawSegments)

        // Keep every attempt; latest is canonical (SPEC §4.6).
        let note = NoteRecord(
            sessionId: session.id,
            markdown: markdown,
            model: provider.modelIdentifier,
            promptVersion: PromptVersion.current
        )
        do {
            try store.insertCanonicalNote(note)
        } catch {
            return .failure(.store("failed storing note: \(String(describing: error))"))
        }

        // Title follows the fused output whenever a note was stored (SPEC
        // changelog v1.0→v1.1: "Session titles from fusion output"); STATE
        // only advances on a clean run — findings leave the session in
        // `processing` for Retry (SPEC §4.5).
        var updated = session
        if let title { updated.title = title }
        updated.state = findings.isEmpty ? .complete : .processing
        do {
            try store.updateSession(updated)
        } catch {
            return .failure(.store("failed updating session: \(String(describing: error))"))
        }

        if findings.isEmpty {
            return .success(noteId: note.id, title: title)
        }
        return .storedWithFindings(noteId: note.id, title: title, findings: findings)
    }

    /// Message carried to the Retry UI (SessionCoordinator passes
    /// `FusionServiceError.provider`'s payload through verbatim).
    ///
    /// `String(describing:)` on a provider error renders the enum case —
    /// `httpStatus(401, "{\"type\":\"error\"…")` — which reads identically
    /// whether the user's API key is wrong or Anthropic is down. Providers
    /// that conform to `LocalizedError` get to say which; anything else falls
    /// back to the structural dump so no diagnostic detail is lost.
    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    // MARK: Provider calls

    private func complete(input: FusionInput, provider: any FusionProvider) async throws -> String {
        // The rendered transcript is a reusable prefix: a Retry after a
        // validator finding or a transient failure re-sends these exact
        // bytes, and so would a second pass over the same notes.
        try await provider.complete(
            systemPrompt: SystemPrompt.v1,
            userPrompt: PromptAssembler.userPrompt(for: input),
            temperature: Self.temperature,
            userPromptIsReusablePrefix: true
        )
    }

    /// Per-chunk notes, then one final compose — all through the same
    /// provider (SPEC §4.5 long-meeting rule).
    private func runChunked(
        session: SessionRecord,
        chunks: [[SegmentRecord]],
        fragments: [FragmentRecord],
        lookback: TimeInterval,
        provider: any FusionProvider
    ) async throws -> String {
        // Chunks render with GLOBAL session offsets from the start (SPEC
        // §4.5): the canonical renderer stamps each segment's true offset,
        // so chunk-local timestamps never exist and the validator runs the
        // same shared code path against the global timeline.
        let assigned = Self.assignFragments(fragments, toChunks: chunks, lookback: lookback)
        var chunkNotes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let input = FusionInput(
                session: session,
                segments: chunk,
                fragments: assigned[index],
                lookback: lookback
            )
            chunkNotes.append(try await complete(input: input, provider: provider))
        }
        // The compose message is unique to this one request (it carries the
        // chunk notes this run just produced), so it is NOT a cacheable
        // prefix — marking it would pay the cache-write premium for an entry
        // no later request can read.
        return try await provider.complete(
            systemPrompt: SystemPrompt.v1,
            userPrompt: PromptAssembler.composeUserPrompt(chunkNotes: chunkNotes),
            temperature: Self.temperature,
            userPromptIsReusablePrefix: false
        )
    }

    // MARK: Chunking (pure, unit-tested — no network)

    /// Long-meeting chunking (SPEC §4.5 operational rules): strictly beyond
    /// `wordLimit` words, split the transcript at the LARGEST start-offset
    /// deltas between consecutive segments — the biggest VAD gaps / silences,
    /// where a cut loses the least. Returns a single chunk (the whole input,
    /// time-sorted) when the transcript fits one shot.
    ///
    /// Chunks are approximately word-bounded: seams follow silence, not word
    /// counts, so a pathological transcript (one giant segment) stays whole.
    public static func chunkIfNeeded(
        segments: [SegmentRecord],
        wordLimit: Int = FusionService.chunkWordLimit
    ) -> [[SegmentRecord]] {
        let sorted = segments.sorted { ($0.startOffset, $0.id.uuidString) < ($1.startOffset, $1.id.uuidString) }
        guard sorted.count > 1 else { return [sorted] }

        let totalWords = sorted.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        guard totalWords > wordLimit else { return [sorted] }

        // Enough chunks to get under the limit, i.e. cutsWanted seams.
        let cutsWanted = max(1, Int(ceil(Double(totalWords) / Double(wordLimit))) - 1)

        // Candidate seams: delta between consecutive start offsets. Largest
        // gap first; ties cut earlier (deterministic).
        let gaps: [(gap: TimeInterval, cutBefore: Int)] = (1..<sorted.count).map { index in
            (sorted[index].startOffset - sorted[index - 1].startOffset, index)
        }
        let cuts = gaps
            .sorted { $0.gap != $1.gap ? $0.gap > $1.gap : $0.cutBefore < $1.cutBefore }
            .prefix(min(cutsWanted, gaps.count))
            .map(\.cutBefore)
            .sorted()

        var chunks: [[SegmentRecord]] = []
        var start = 0
        for cut in cuts where cut > start {
            chunks.append(Array(sorted[start..<cut]))
            start = cut
        }
        chunks.append(Array(sorted[start...]))
        return chunks
    }

    /// Assigns each fragment to its chunk by EFFECTIVE anchor
    /// (`anchorOffset − lookback`, SPEC §4.3): the chunk whose time range
    /// contains the anchor, else the nearest chunk — lookback can land an
    /// anchor in the silence seam between two chunks, and it belongs with the
    /// speech it refers to, not the speech behind it.
    static func assignFragments(
        _ fragments: [FragmentRecord],
        toChunks chunks: [[SegmentRecord]],
        lookback: TimeInterval
    ) -> [[FragmentRecord]] {
        let ranges = chunks.map { chunk -> ClosedRange<TimeInterval> in
            let lower = chunk.first?.startOffset ?? 0
            let upper = max(lower, chunk.last?.endOffset ?? lower)
            return lower...upper
        }
        var assigned = Array(repeating: [FragmentRecord](), count: chunks.count)
        for fragment in fragments {
            let effective = max(0, fragment.anchorOffset - lookback)
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (index, range) in ranges.enumerated() {
                let distance: TimeInterval
                if effective < range.lowerBound {
                    distance = range.lowerBound - effective
                } else if effective > range.upperBound {
                    distance = effective - range.upperBound
                } else {
                    distance = 0
                }
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }
            assigned[bestIndex].append(fragment)
        }
        return assigned
    }
}
