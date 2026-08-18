import CaptureKit
import FusionKit
import Persistence
import ScratchpadKit
import SessionKit
import TranscribeKit
import XCTest

// MARK: - Test doubles

/// Consumes each per-channel input stream; when the input FINISHES, emits a
/// run of hypothesis revisions (stable UUID, per SPEC §4.2 upsert semantics)
/// for every channel that actually delivered audio, then finishes. Records
/// chunk counts so tests can prove the capture wiring routed audio.
private final class MockTranscriber: Transcriber, @unchecked Sendable {

    private let lock = NSLock()
    private var chunkCountsStorage: [Channel: Int] = [:]
    private let revisions: Int

    /// - Parameter revisions: hypotheses emitted per channel; all share one
    ///   UUID and only the last is `isFinal` (streaming revision semantics).
    init(revisions: Int = 2) {
        self.revisions = max(1, revisions)
    }

    func chunkCount(for channel: Channel) -> Int {
        lock.lock(); defer { lock.unlock() }
        return chunkCountsStorage[channel] ?? 0
    }

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            self.consume(stream, into: continuation)
        }
    }

    /// Hoisted out of the stream builder so the closure type-checks quickly.
    private func consume(
        _ stream: AsyncStream<AudioChunk>,
        into continuation: AsyncStream<TranscriptSegment>.Continuation
    ) {
        let task = Task { [weak self] in
            var channel: Channel?
            for await chunk in stream {
                channel = chunk.channel
                self?.record(chunk.channel)
            }
            guard let channel, let self else {
                continuation.finish()
                return
            }
            for segment in self.revisions(channel: channel) {
                continuation.yield(segment)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }

    private func record(_ channel: Channel) {
        lock.lock(); defer { lock.unlock() }
        chunkCountsStorage[channel, default: 0] += 1
    }

    private func revisions(channel: Channel) -> [TranscriptSegment] {
        let id = UUID()
        var segments: [TranscriptSegment] = []
        for index in 0..<revisions {
            let isLast = index == revisions - 1
            let start = TimeInterval(index)
            segments.append(TranscriptSegment(
                id: id,
                channel: channel,
                text: isLast ? "final hypothesis" : "draft \(index)",
                startOffset: start,
                endOffset: start + 1,
                isFinal: isLast
            ))
        }
        return segments
    }
}

/// Fusion runner mock: dequeues scripted outcomes (last is sticky) and can
/// mimic the real `FusionService` side effect of storing a canonical note,
/// so tests exercise the store contract end to end.
private final class MockFusionRunner: @unchecked Sendable {

    private let lock = NSLock()

    /// Runs `body` under `lock` (sync helper — keeps async-context
    /// availability diagnostics quiet; nothing awaits under the lock).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var queue: [FusionRunOutcome]
    private let sticky: FusionRunOutcome
    private var callsStorage: [SessionRecord] = []
    private let noteStore: MeetingStore?
    private let noteMarkdown = "Title: Mock outcome\n\n## Summary\nStored by the mock runner."

    init(results: [FusionRunOutcome], storingNotesIn store: MeetingStore? = nil) {
        precondition(!results.isEmpty)
        queue = Array(results.dropLast())
        sticky = results.last!
        noteStore = store
    }

    var calls: [SessionRecord] {
        withLock { callsStorage }
    }

    func run(_ session: SessionRecord) async -> FusionRunOutcome {
        let outcome = withLock {
            callsStorage.append(session)
            return queue.isEmpty ? sticky : queue.removeFirst()
        }

        if let noteStore, case let .success(noteId, _) = outcome {
            try? noteStore.insertCanonicalNote(NoteRecord(
                id: noteId,
                sessionId: session.id,
                markdown: noteMarkdown,
                model: "mock-runner",
                promptVersion: "test"
            ))
        }
        return outcome
    }
}

/// Subscribes to a coordinator's events and records them for polling
/// assertions (stream iteration is asynchronous even for buffered events).
private final class EventRecorder: @unchecked Sendable {

    private let lock = NSLock()

    /// Sync helper around the raw lock (see MockFusionRunner.withLock).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var stored: [CoordinatorEvent] = []
    private var task: Task<Void, Never>?

    /// The stream is created (and its continuation registered) synchronously
    /// here, so any event emitted AFTER this call is guaranteed buffered.
    func subscribe(to coordinator: SessionCoordinator) {
        let stream = coordinator.events()
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    private func append(_ event: CoordinatorEvent) {
        withLock { stored.append(event) }
    }

    var events: [CoordinatorEvent] {
        withLock { stored }
    }

    var displayStates: [SessionDisplayState] {
        events.compactMap {
            if case .stateChanged(let state) = $0 { return state }
            return nil
        }
    }

    /// Polls until the recorded events satisfy `condition` (stream delivery
    /// is async even for buffered events), with a generous timeout for CI
    /// hiccups.
    func waitFor(
        _ condition: ([CoordinatorEvent]) -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(events) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition(events)
    }
}

// MARK: - Coordinator lifecycle (SPEC §4.4)

final class SessionCoordinatorTests: XCTestCase {

    private func makeCoordinator(
        store: MeetingStore,
        transcriber: MockTranscriber,
        fusion: MockFusionRunner
    ) -> SessionCoordinator {
        SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: transcriber,
            lookback: 20,
            fusionRunner: { await fusion.run($0) }
        )
    }

    // start/stop happy path: stub capture → mock transcription (revisions) →
    // store; fusion success → .complete, note + segments persisted, display
    // events observed in order (SPEC §4.4, §3.2).
    func testStartStopHappyPathPersistsEverythingAndCompletes() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber(revisions: 3)
        let noteId = UUID()
        let fusion = MockFusionRunner(
            results: [.success(noteId: noteId, title: "Planning sync")],
            storingNotesIn: store
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)

        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        let session = try await coordinator.start()
        XCTAssertEqual(coordinator.displayState, .recording)
        XCTAssertEqual(try store.session(id: session.id)?.state, .recording)

        // Let the stub engine emit some local-channel audio.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(transcriber.chunkCount(for: .local), 0,
                             "capture wiring routed mic audio to the transcriber")
        XCTAssertGreaterThan(coordinator.elapsed(), 0, "wall-clock elapsed runs while recording")
        XCTAssertGreaterThan(coordinator.nowOffset(), 0, "session clock runs while recording")

        await coordinator.stop()

        // Session row: complete, titled, ended (SPEC §4.4 → §4.5).
        let row = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(row.state, .complete)
        XCTAssertEqual(row.title, "Planning sync")
        XCTAssertNotNil(row.endedAt)

        // Note stored (by the runner, as FusionService would).
        let note = try XCTUnwrap(try store.canonicalNote(sessionId: session.id))
        XCTAssertEqual(note.id, noteId)
        XCTAssertEqual(fusion.calls.map(\.id), [session.id], "fusion ran exactly once on stop")

        // Segments: 3 revisions on one stable UUID → ONE final row
        // (SPEC §4.2 upsert; stop finalizes pending hypotheses).
        let segments = try store.segments(sessionId: session.id)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].isFinal)
        XCTAssertEqual(segments[0].channel, .local)
        XCTAssertEqual(segments[0].text, "final hypothesis")

        // Display events in order: recording → processing → done (SPEC §5).
        let sawDone = await recorder.waitFor { events in
            events.contains { if case .stateChanged(.done(let id)) = $0 { return id == session.id }; return false }
        }
        XCTAssertTrue(sawDone, "missing .done; events: \(recorder.events)")
        XCTAssertEqual(coordinator.displayState, .done(sessionId: session.id))
        XCTAssertEqual(recorder.displayStates, [
            .recording, .processing, .done(sessionId: session.id),
        ])
    }

    // Fusion failure: session stays .processing, error surfaced, derived
    // state .failed; retryFusion() succeeds once the runner flips.
    func testFusionFailureSurfacesErrorThenRetrySucceeds() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber(revisions: 2)
        let fusion = MockFusionRunner(
            results: [
                .failure(.provider("network down")),
                .success(noteId: UUID(), title: "Retry works"),
            ],
            storingNotesIn: store
        )
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)

        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        let session = try await coordinator.start()
        await coordinator.stop()

        // SPEC §4.5: failure leaves the session in `processing` with Retry.
        let row = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(row.state, .processing)
        XCTAssertNil(try store.canonicalNote(sessionId: session.id))
        XCTAssertEqual(coordinator.displayState, .failed(sessionId: session.id))
        XCTAssertEqual(coordinator.lastFusionError, "network down")

        let sawFailure = await recorder.waitFor { events in
            events.contains { if case .fusionFailed(_, let message) = $0 { return message == "network down" }; return false }
        }
        XCTAssertTrue(sawFailure, "error surfaced via event; events: \(recorder.events)")

        // Retry: mock flips to success → complete + done.
        await coordinator.retryFusion()

        let retried = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(retried.state, .complete)
        XCTAssertEqual(retried.title, "Retry works")
        XCTAssertNotNil(try store.canonicalNote(sessionId: session.id))
        XCTAssertNil(coordinator.lastFusionError)
        XCTAssertEqual(fusion.calls.count, 2)

        let sawDone = await recorder.waitFor { events in
            events.contains { if case .stateChanged(.done) = $0 { return true }; return false }
        }
        XCTAssertTrue(sawDone)
        XCTAssertEqual(recorder.displayStates, [
            .recording,
            .processing,
            .failed(sessionId: session.id),
            .processing, // retry in flight: leave the ⚠ state
            .done(sessionId: session.id),
        ])
    }

    // Crash recovery (SPEC §4.4): a session stuck in .recording at init is
    // marked recovered → .processing, surfaced via event; NO auto-fusion.
    func testCrashRecoveryMarksRecoveredAndOffersFusionWithoutRunningIt() async throws {
        let store = try MeetingStore.inMemory()
        let crashed = try store.createSession() // still .recording, as after a kill -9
        try store.upsertSegment(SegmentRecord(
            sessionId: crashed.id, channel: .remote,
            text: "partial transcript up to the kill point",
            startOffset: 12, endOffset: 20, isFinal: true
        ))

        let transcriber = MockTranscriber()
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: "Recovered")],
                                      storingNotesIn: store)
        // init runs the scan; subscribe AFTER init — the event must still
        // arrive (buffered for the first subscriber).
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)
        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        let sawRecovery = await recorder.waitFor { events in
            events.contains {
                if case .recoveredSessions(let sessions) = $0 {
                    return sessions.contains { $0.id == crashed.id }
                }
                return false
            }
        }
        XCTAssertTrue(sawRecovery, "recoveredSessions event; events: \(recorder.events)")

        let row = try XCTUnwrap(try store.session(id: crashed.id))
        XCTAssertTrue(row.recovered, "recovered flag set (SPEC §4.4)")
        XCTAssertEqual(row.state, .processing, "moved to processing for the fusion offer")
        XCTAssertNil(row.endedAt, "crash time unknown — no invented wall-clock end")
        XCTAssertTrue(fusion.calls.isEmpty, "no auto-fusion on recovery")

        // The offer: user-initiated fusion on the recovered session works.
        XCTAssertEqual(coordinator.displayState, .idle)
        await coordinator.retryFusion(for: crashed)
        XCTAssertEqual(try store.session(id: crashed.id)?.state, .complete)
        XCTAssertEqual(fusion.calls.map(\.id), [crashed.id])
        XCTAssertEqual(coordinator.displayState, .idle,
                       "non-current retry drives no menu-bar state changes")
    }

    // Interruptions (SPEC §4.1/§4.4): device-change + sleep/wake land in
    // sessions.deviceEvents with session-clock offsets; ignored when idle.
    func testDeviceChangeAndSleepWakeLoggedToDeviceEvents() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber()
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: nil)],
                                      storingNotesIn: store)
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)
        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        // Before start: no session, no crash, no events.
        coordinator.handleDeviceChange()
        coordinator.handleSleep()
        coordinator.handleWake()
        XCTAssertTrue(recorder.events.isEmpty)

        let session = try await coordinator.start()
        try await Task.sleep(nanoseconds: 50_000_000) // let the clock advance a little
        coordinator.handleDeviceChange()
        coordinator.handleSleep()
        coordinator.handleWake()

        let sawAll = await recorder.waitFor { $0.deviceEventLoggedCount >= 3 }
        XCTAssertTrue(sawAll, "deviceEventLogged events; events: \(recorder.events)")

        let row = try XCTUnwrap(try store.session(id: session.id))
        let events = row.deviceEventList
        XCTAssertEqual(events.map(\.kind), [DeviceEventKind.deviceChanged, DeviceEventKind.sleep, DeviceEventKind.wake])
        XCTAssertTrue(events.allSatisfy { $0.offset >= 0 })
        XCTAssertEqual(events.map(\.offset), events.map(\.offset).sorted(),
                       "session-clock offsets are non-decreasing on one timeline")

        await coordinator.stop() // also releases the stub engine
        XCTAssertEqual(try store.session(id: session.id)?.state, .complete)
    }

    // Scratchpad wiring: an attached composer's pending row is flushed and
    // frozen at stop (SPEC §4.3 pending-row pattern, stable id per burst).
    func testAttachedComposerFlushesPendingFragmentAtStop() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber()
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: nil)],
                                      storingNotesIn: store)
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)

        let composer = FragmentComposer()
        coordinator.attach(composer)

        let session = try await coordinator.start()
        composer.edit("pricing", at: 1.0)           // pending row persisted immediately
        composer.edit("pricing objection", at: 1.4) // within debounce — pending only
        await coordinator.stop()

        // One frozen fragment on the stable burst id: burst-start anchor,
        // final text, exactly one row (upserts collapsed).
        let fragments = try store.fragments(sessionId: session.id)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments[0].text, "pricing objection")
        XCTAssertEqual(fragments[0].anchorOffset, 1.0,
                       "anchor is the burst START on the session clock (SPEC §4.3)")
    }

    // stop() is idempotent: a second stop while not recording is a no-op
    // (no second fusion run).
    func testStopIsIdempotent() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber()
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: nil)],
                                      storingNotesIn: store)
        let coordinator = makeCoordinator(store: store, transcriber: transcriber, fusion: fusion)

        _ = try await coordinator.start()
        await coordinator.stop()
        await coordinator.stop()

        XCTAssertEqual(fusion.calls.count, 1, "second stop is a no-op")
    }
}

// MARK: - SessionClock (SPEC §4.1)

final class SessionClockTests: XCTestCase {

    func testOffsetsMonotonicNonDecreasingAndStartNearZero() async throws {
        let clock = SessionClock()
        let first = clock.nowOffset()
        XCTAssertLessThan(first, 5, "clock starts at session begin (offset ≈ 0)")

        var last = first
        for _ in 0..<2_000 {
            let now = clock.nowOffset()
            XCTAssertGreaterThanOrEqual(now, last, "monotonic non-decreasing")
            last = now
        }

        // Time actually passes on the clock basis (mach_continuous_time).
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(clock.nowOffset(), last)
    }

    func testFreshClockRestartsTimeline() {
        let first = SessionClock()
        let second = SessionClock()
        XCTAssertLessThan(second.nowOffset(), 5,
                          "a new clock begins a new timeline at ≈ 0")
        // Both share the mach_continuous_time basis; both origins are ~now.
        XCTAssertLessThan(abs(first.nowOffset() - second.nowOffset()), 5)
    }
}

// MARK: - Test helpers

private extension Array where Element == CoordinatorEvent {
    var deviceEventLoggedCount: Int {
        reduce(0) { count, event in
            if case .deviceEventLogged = event { return count + 1 }
            return count
        }
    }
}
