import XCTest
@testable import FusionKit
import Persistence

// MARK: - Mock provider (no network anywhere in these tests — T1)

/// Queue-backed mock: each call dequeues the next canned response (the last
/// is sticky); throws `failure` instead when set. Records every call.
final class MockFusionProvider: FusionProvider, @unchecked Sendable {

    struct Call {
        let systemPrompt: String
        let userPrompt: String
        let temperature: Double
    }

    private let lock = NSLock()
    private var queue: [String]
    private var sticky: String
    private let failure: Error?
    private var storedCalls: [Call] = []

    var modelIdentifier: String { "mock-model" }

    init(responses: [String] = [], failure: Error? = nil) {
        self.queue = responses
        self.sticky = responses.last ?? ""
        self.failure = failure
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func complete(systemPrompt: String, userPrompt: String, temperature: Double) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        storedCalls.append(Call(systemPrompt: systemPrompt, userPrompt: userPrompt, temperature: temperature))
        if let failure {
            throw failure
        }
        if !queue.isEmpty {
            let next = queue.removeFirst()
            sticky = next
            return next
        }
        return sticky
    }
}

// MARK: - FusionService orchestration (SPEC §4.5)

final class FusionServiceTests: XCTestCase {

    /// Creates a session and moves it to `processing`, mirroring what
    /// SessionKit does at stop (SPEC §4.4) before fusion runs.
    private func makeProcessingSession(_ store: MeetingStore) throws -> SessionRecord {
        var session = try store.createSession()
        session.state = .processing
        try store.updateSession(session)
        return session
    }

    func testSuccessPathStoresCanonicalNoteAndCompletesSession() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)

        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote,
            text: "We agreed to defer the database migration until Q3",
            startOffset: 860, endOffset: 890, isFinal: true
        ))
        try store.upsertFragment(FragmentRecord(sessionId: session.id, text: "migration timing", anchorOffset: 875))

        let canned = """
        Title: Migration planning call

        ## Summary
        The team discussed the database migration timeline. They agreed to defer it.

        ## Key points
        - **Timeline** — Migration timing dominated the discussion.

        ## Decisions
        - [14:30] "defer the database migration until Q3" — Migration moves to Q3.

        ## Action items
        - [14:35] "defer the database migration until Q3" — Draft the Q3 migration plan.
        """
        let provider = MockFusionProvider(responses: [canned])
        let service = FusionService(store: store)

        let outcome = await service.fuse(session: session, lookback: 20, provider: provider)

        guard case let .success(noteId, title) = outcome else {
            return XCTFail("expected .success, got \(outcome)")
        }
        XCTAssertEqual(title, "Migration planning call")

        let note = try XCTUnwrap(try store.canonicalNote(sessionId: session.id))
        XCTAssertEqual(note.id, noteId)
        XCTAssertEqual(note.markdown, canned)
        XCTAssertEqual(note.model, "mock-model")
        XCTAssertEqual(note.promptVersion, PromptVersion.current)

        let updated = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(updated.state, .complete)
        XCTAssertEqual(updated.title, "Migration planning call")

        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(provider.calls[0].temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(provider.calls[0].systemPrompt, SystemPrompt.v1)
    }

    func testProviderFailureLeavesSessionProcessingAndSurfacesError() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote,
            text: "some talk", startOffset: 10, endOffset: 20, isFinal: true
        ))

        let provider = MockFusionProvider(failure: URLError(.notConnectedToInternet))
        let service = FusionService(store: store)

        let outcome = await service.fuse(session: session, provider: provider)

        guard case let .failure(error) = outcome else {
            return XCTFail("expected .failure, got \(outcome)")
        }
        guard case .provider(let message) = error else {
            return XCTFail("expected .provider error, got \(error)")
        }
        XCTAssertFalse(message.isEmpty, "error description is for the Retry UI")

        // SPEC §4.5: fusion errors leave the session in `processing` with
        // Retry; raw transcript stays viewable, no note stored.
        let updated = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(updated.state, .processing)
        XCTAssertNil(updated.title)
        XCTAssertTrue(try store.notes(sessionId: session.id).isEmpty)
        XCTAssertEqual(provider.calls.count, 1)
    }

    func testValidatorFindingsStoresNoteAndReturnsFindings() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote,
            text: "We agreed to defer the database migration until Q3",
            startOffset: 860, endOffset: 890, isFinal: true
        ))

        // One bad quote (no transcript match) + one good citation: only the
        // bad one may be flagged — the validator must not cry wolf.
        let canned = """
        Title: Migration planning call

        ## Summary
        The team discussed the database migration timeline.

        ## Decisions
        - [14:30] "buy everyone pizza immediately" — Order lunch for the team.

        ## Action items
        - [14:32] "defer the database migration until Q3" — Draft the migration plan.
        """
        let provider = MockFusionProvider(responses: [canned])
        let service = FusionService(store: store)

        let outcome = await service.fuse(session: session, provider: provider)

        guard case let .storedWithFindings(noteId, title, findings) = outcome else {
            return XCTFail("expected .storedWithFindings, got \(outcome)")
        }
        XCTAssertEqual(title, "Migration planning call")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].kind, .quoteMismatch)

        // SPEC §4.5: failures are surfaced in UI and auto-saved to the eval
        // set — the note IS stored (warning-card UI + eval inputs).
        let note = try XCTUnwrap(try store.canonicalNote(sessionId: session.id))
        XCTAssertEqual(note.id, noteId)
        XCTAssertEqual(note.markdown, canned)

        // Session stays in `processing` so Retry remains available.
        let updated = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(updated.state, .processing)
        XCTAssertEqual(updated.title, "Migration planning call")
    }

    func testEmptyTranscriptFailsWithoutProviderCall() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        // No segments — nothing to fuse (fail fast, no API call).
        try store.upsertFragment(FragmentRecord(sessionId: session.id, text: "orphan note", anchorOffset: 10))

        let provider = MockFusionProvider(responses: ["Title: x"])
        let service = FusionService(store: store)

        let outcome = await service.fuse(session: session, provider: provider)

        guard case .failure(.emptyTranscript) = outcome else {
            return XCTFail("expected .failure(.emptyTranscript), got \(outcome)")
        }
        XCTAssertTrue(provider.calls.isEmpty)
        XCTAssertEqual(try store.session(id: session.id)?.state, .processing)
    }

    // MARK: Chunking (pure splitting logic — synthetic segments, no network)

    func testChunkIfNeededSplitsAtLargestGaps() {
        let sessionId = UUID()
        func seg(_ start: Double, _ end: Double) -> SegmentRecord {
            SegmentRecord(
                sessionId: sessionId, channel: .remote,
                text: (1...40).map { "word\($0)" }.joined(separator: " "),
                startOffset: start, endOffset: end
            )
        }
        // Three dense clusters separated by ~990 s silences (largest VAD gaps).
        let segments = [
            seg(0, 8), seg(8, 10),
            seg(1000, 1008), seg(1008, 1010),
            seg(2000, 2008), seg(2008, 2010),
        ]
        // 240 words, limit 100 → 3 chunks; the two largest start-offset
        // deltas (≈990 s) are the seams.
        let chunks = FusionService.chunkIfNeeded(segments: segments, wordLimit: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].map(\.startOffset), [0, 8])
        XCTAssertEqual(chunks[1].map(\.startOffset), [1000, 1008])
        XCTAssertEqual(chunks[2].map(\.startOffset), [2000, 2008],
                       "chunks keep GLOBAL session offsets (SPEC §4.5)")
    }

    func testChunkIfNeededSingleChunkAtOrBelowThreshold() {
        let sessionId = UUID()
        let segments = [
            SegmentRecord(sessionId: sessionId, channel: .local, text: "a b c", startOffset: 0, endOffset: 2),
            SegmentRecord(sessionId: sessionId, channel: .remote, text: "d e f", startOffset: 100, endOffset: 102),
        ]
        // 6 words ≤ limit 100 → single shot, segments time-sorted.
        let chunks = FusionService.chunkIfNeeded(segments: segments.reversed(), wordLimit: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].map(\.startOffset), [0, 100])
    }

    func testChunkedRunSequencesPerChunkNotesThenCompose() async throws {
        let store = try MeetingStore.inMemory()
        let session = try makeProcessingSession(store)
        let sessionId = session.id

        func seg(_ start: Double, _ end: Double, marker: String) -> SegmentRecord {
            SegmentRecord(
                sessionId: sessionId, channel: .remote,
                text: marker + " " + (1...40).map { "w\($0)" }.joined(separator: " "),
                startOffset: start, endOffset: end
            )
        }
        try store.upsertSegment(seg(0, 8, marker: "ALPHA"))
        try store.upsertSegment(seg(8, 10, marker: "ALPHA2"))
        try store.upsertSegment(seg(1000, 1008, marker: "BRAVO"))
        try store.upsertSegment(seg(1008, 1010, marker: "BRAVO2"))
        try store.upsertSegment(seg(2000, 2008, marker: "CHARLIE"))
        try store.upsertSegment(seg(2008, 2010, marker: "CHARLIE2"))
        // Effective anchor 1005 − 20 = 985 lands in the silence seam before
        // BRAVO — nearest-chunk assignment puts it with chunk 2.
        try store.upsertFragment(FragmentRecord(sessionId: sessionId, text: "pricing note", anchorOffset: 1005))

        let final = """
        Title: Long meeting consolidated

        ## Summary
        Notes from all three parts were merged onto one timeline.

        ## Key points
        - **Structure** — Three clusters of discussion.

        ## Decisions
        None recorded.

        ## Action items
        None recorded.
        """
        let provider = MockFusionProvider(responses: [
            "CHUNK-ONE-NOTES", "CHUNK-TWO-NOTES", "CHUNK-THREE-NOTES", final,
        ])
        let service = FusionService(store: store)

        let outcome = await service.fuse(
            session: session,
            lookback: 20,
            provider: provider,
            chunkWordLimit: 100
        )

        // 3 per-chunk calls + 1 compose call (SPEC §4.5 long-meeting rule).
        XCTAssertEqual(provider.calls.count, 4)
        XCTAssertTrue(provider.calls[0].userPrompt.contains("ALPHA "), "chunk 1 prompt covers cluster 1 only")
        XCTAssertFalse(provider.calls[0].userPrompt.contains("BRAVO"))
        XCTAssertTrue(provider.calls[1].userPrompt.contains("BRAVO "))
        XCTAssertTrue(provider.calls[1].userPrompt.contains("[USER NOTE @ 16:45] pricing note"),
                      "fragment rides its chunk (nearest assignment across the seam)")
        XCTAssertTrue(provider.calls[2].userPrompt.contains("CHARLIE "))
        // The compose call sees every chunk's notes on the global timeline.
        XCTAssertTrue(provider.calls[3].userPrompt.contains("CHUNK-ONE-NOTES"))
        XCTAssertTrue(provider.calls[3].userPrompt.contains("CHUNK-THREE-NOTES"))

        guard case let .success(_, title) = outcome else {
            return XCTFail("expected .success, got \(outcome)")
        }
        XCTAssertEqual(title, "Long meeting consolidated")
        let note = try XCTUnwrap(try store.canonicalNote(sessionId: sessionId))
        XCTAssertEqual(note.markdown, final, "the COMPOSE output is the stored note")
        XCTAssertEqual(try store.session(id: sessionId)?.state, .complete)
    }
}

// MARK: - System prompt pins (SPEC §4.5)

final class SystemPromptTests: XCTestCase {

    func testV1PinsOutputFormatAndGroundingRules() {
        let prompt = SystemPrompt.v1
        // Fixed output format (SPEC §4.5 output format §0–4).
        XCTAssertTrue(prompt.contains("Title:"))
        XCTAssertTrue(prompt.contains("8 words or fewer"))
        XCTAssertTrue(prompt.contains("2–4 sentences"))
        XCTAssertTrue(prompt.contains("grouped by topic"))
        XCTAssertTrue(prompt.contains(#""verbatim transcript quote (5–15 words)""#))
        XCTAssertTrue(prompt.contains("owner if one is inferable"))
        // Grounding rules.
        XCTAssertTrue(prompt.contains("[USER NOTE @"))
        XCTAssertTrue(prompt.contains("Only state what the transcript supports"))
        XCTAssertTrue(prompt.contains("Never invent a timestamp"))
        XCTAssertTrue(prompt.contains("produce complete notes from the transcript alone"))
    }
}
