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

/// Models the production `LazyWhisperKitTranscriber` failure that produced
/// the T10 dogfood "Stop does nothing" bug: the transcriber resolves its
/// model BEFORE it ever reads the input stream, so finishing that stream does
/// not finish the output stream — the pipeline's consumer task simply never
/// returns. Here the resolution never completes at all.
private final class StalledTranscriber: Transcriber, @unchecked Sendable {

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task {
                // "Loading the model" — never resolves, never touches `stream`.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A transcriber whose FIRST `stallingCalls` streams stall exactly like
/// `StalledTranscriber` (session A, one call per channel), while every later
/// stream behaves like `MockTranscriber` (session B). Models the real
/// sequence behind the drain-window bug: the model is still loading when the
/// user stops meeting A, and has loaded by the time meeting B starts.
private final class StallingFirstSessionTranscriber: Transcriber, @unchecked Sendable {

    private let lock = NSLock()
    private var stallsRemaining: Int
    private let working: MockTranscriber

    init(stallingCalls: Int = 2, revisions: Int = 2) {
        stallsRemaining = stallingCalls
        working = MockTranscriber(revisions: revisions)
    }

    func chunkCount(for channel: Channel) -> Int { working.chunkCount(for: channel) }

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        lock.lock()
        let shouldStall = stallsRemaining > 0
        if shouldStall { stallsRemaining -= 1 }
        lock.unlock()

        guard shouldStall else { return working.transcribe(stream: stream) }
        return AsyncStream { continuation in
            let task = Task {
                // "Loading the model" — never resolves, never touches `stream`.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Fusion runner mock that can be HELD OPEN: every call from `gateFromCall`
/// onwards parks until `openGate()` is called. Lets a test put a fusion run
/// genuinely in flight and then do something else (start a meeting, click
/// Retry again) while it is still running.
private final class GatedFusionRunner: @unchecked Sendable {

    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var callsStorage: [UUID] = []
    private var gateOpen = false
    private let outcomes: [FusionRunOutcome] // last entry is sticky
    private let gateFromCall: Int

    init(outcomes: [FusionRunOutcome], gateFromCall: Int) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
        self.gateFromCall = gateFromCall
    }

    var calls: [UUID] { withLock { callsStorage } }

    func openGate() { withLock { gateOpen = true } }

    func run(_ session: SessionRecord) async -> FusionRunOutcome {
        let index = withLock { () -> Int in
            callsStorage.append(session.id)
            return callsStorage.count - 1
        }
        if index >= gateFromCall {
            // `Task.isCancelled` also breaks the park, so a cancelled test
            // task cannot spin here forever.
            while !withLock({ gateOpen }), !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        return outcomes[min(index, outcomes.count - 1)]
    }

    /// Polls until at least `count` calls have entered `run`.
    func waitUntilEntered(_ count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if calls.count >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return calls.count >= count
    }
}

/// Races `body` against `timeout`, without a task group (which would wait for
/// every child, re-introducing the hang the racing is meant to detect).
/// Returns `false` if `body` had not returned by the deadline.
private func completes(within timeout: TimeInterval, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let (outcomes, report) = AsyncStream<Bool>.makeStream()
    let work = Task { await body(); report.yield(true) }
    let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        report.yield(false)
    }
    var finished = false
    for await outcome in outcomes {
        finished = outcome
        break
    }
    deadline.cancel()
    if !finished { work.cancel() }
    return finished
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

    // T10 dogfood regression (bugs 1 + 2): a transcriber that stalls before
    // it ever reads its input stream must NOT hold the session hostage.
    // Before the fix, stop() awaited the pipeline drain forever: the row
    // stayed `recording`, displayState stayed `.recording` (panel kept the
    // red dot and a dead Stop button), and elapsed() read 0 — a frozen 00:00.
    func testStopCompletesWhenTranscriptionStallsAndNeverDrains() async throws {
        let store = try MeetingStore.inMemory()
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: nil)],
                                      storingNotesIn: store)
        let coordinator = SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: StalledTranscriber(),
            lookback: 20,
            transcriptDrainTimeout: 0.3, // production default is 10 s
            fusionRunner: { await fusion.run($0) }
        )
        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        let session = try await coordinator.start()
        XCTAssertGreaterThan(coordinator.elapsed(), 0, "wall clock runs while recording")

        // The bug was an UNBOUNDED await, so bound the test the same way the
        // fix bounds the drain — a regression fails here instead of wedging
        // the whole suite. (A task group would not do: it waits for every
        // child, including the one stuck awaiting the hung stop.)
        let (outcomes, report) = AsyncStream<Bool>.makeStream()
        let stopping = Task { await coordinator.stop(); report.yield(true) }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            report.yield(false)
        }
        var finishedInTime = false
        for await outcome in outcomes {
            finishedInTime = outcome
            break
        }
        deadline.cancel()
        stopping.cancel()
        XCTAssertTrue(finishedInTime, "stop() must not wait on a stalled transcriber")

        let row = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertNotEqual(row.state, .recording, "the row leaves `recording` (nothing to recover)")
        XCTAssertNotNil(row.endedAt, "wall-clock end is written at stop")
        XCTAssertEqual(coordinator.elapsed(), 0, "no live session once stopped")
        XCTAssertEqual(fusion.calls.count, 1, "fusion still runs on what was persisted")
        let announced = await recorder.waitFor {
            $0.contains(.transcriptDrainTimedOut(sessionId: session.id))
        }
        XCTAssertTrue(announced, "the abandoned drain is announced, not swallowed")
        let leftRecordingFace = await recorder.waitFor { _ in
            recorder.displayStates.contains(.processing)
        }
        XCTAssertTrue(leftRecordingFace,
                      "the UI leaves the recording face (panel drops the red dot and Stop)")
    }

    // MARK: Session-boundary interleaving (audit #1/#2/#3)

    // Audit #1 (critical). The bounded drain made `start()` legal while a
    // previous `stop()` is still draining — and `stop()` then cleared the
    // single pipeline slot unconditionally, so the NEW session's pipeline was
    // nilled by its predecessor's teardown and every `feedAudio` was dropped.
    // Session B recorded normally (red dot, timer, fragments) and persisted
    // ZERO segments, with no error anywhere. The irony worth remembering: this
    // hole was opened BY the fix for the T10 stop hang.
    func testStartDuringAStalledDrainStillPersistsTheNewSessionsSegments() async throws {
        let store = try MeetingStore.inMemory()
        // Session A's two channel streams stall (model still loading); B's work.
        let transcriber = StallingFirstSessionTranscriber(stallingCalls: 2)
        let fusion = MockFusionRunner(results: [.success(noteId: UUID(), title: nil)],
                                      storingNotesIn: store)
        let coordinator = SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: transcriber,
            lookback: 20,
            transcriptDrainTimeout: 0.6, // production default is 10 s
            fusionRunner: { await fusion.run($0) }
        )

        let a = try await coordinator.start()
        let stoppingA = Task { await coordinator.stop() }

        // Wait for the drain window to open: `stop()` writes `processing`
        // BEFORE the drain, and that is exactly when Start becomes legal
        // again (menu bar enables it from `processing`).
        var polls = 0
        while (try store.session(id: a.id)?.state) != .processing, polls < 400 {
            try await Task.sleep(nanoseconds: 10_000_000)
            polls += 1
        }
        XCTAssertEqual(try store.session(id: a.id)?.state, .processing,
                       "stop() commits `processing` before the bounded drain")

        // Start B *inside* A's drain window.
        let b = try await coordinator.start()
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(coordinator.displayState, .recording)

        // Let A's drain time out (that is where the unconditional clear ran),
        // then keep recording B across the teardown.
        await stoppingA.value
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(transcriber.chunkCount(for: .local), 0,
                             "capture wiring routed audio during session B")

        await coordinator.stop()

        // THE assertion: B's audio reached the store. Before the fix this was
        // empty — a full meeting recorded into a nil pipeline.
        let segments = try store.segments(sessionId: b.id)
        XCTAssertFalse(segments.isEmpty,
                       "session B must persist its segments; a late teardown of A must not kill B's pipeline")
        XCTAssertTrue(segments.allSatisfy(\.isFinal))
        XCTAssertEqual(try store.session(id: b.id)?.state, .complete)
    }

    // Audit #2 (major). `retryFusion` resolved `drivesDisplay` at ENTRY and
    // applied it after an unbounded network await, so a retry finishing during
    // a LATER recording fired `.done`/`.failed` over the live `.recording`
    // state. All three surfaces derive from it, so the chip hid and the menu
    // item flipped to "Start Meeting" — leaving a running meeting with no
    // visible way to stop it.
    func testRetryFinishingDuringALaterRecordingLeavesTheDisplayRecording() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber()
        let fusion = GatedFusionRunner(
            outcomes: [
                .failure(.provider("network down")),           // call 0: stop()'s run
                .success(noteId: UUID(), title: "Late retry"), // call 1: the retry, held open
            ],
            gateFromCall: 1
        )
        let coordinator = SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: transcriber,
            lookback: 20,
            transcriptDrainTimeout: 1,
            fusionRunner: { await fusion.run($0) }
        )
        let recorder = EventRecorder()
        recorder.subscribe(to: coordinator)

        let a = try await coordinator.start()
        await coordinator.stop()
        XCTAssertEqual(coordinator.displayState, .failed(sessionId: a.id))

        // Click Retry; its fusion parks in flight.
        let retrying = Task { await coordinator.retryFusion() }
        let retryInFlight = await fusion.waitUntilEntered(2)
        XCTAssertTrue(retryInFlight, "the retry's fusion is in flight")

        // Start the next meeting while the retry is still running.
        let b = try await coordinator.start()
        XCTAssertEqual(coordinator.displayState, .recording)

        fusion.openGate()
        await retrying.value

        XCTAssertEqual(coordinator.displayState, .recording,
                       "a retry for session A must not overwrite session B's live recording state")
        XCTAssertEqual(recorder.displayStates.last, .recording,
                       "no display transition is announced after .recording; events: \(recorder.events)")

        // The retry still applies to its OWN session — only the display is scoped.
        XCTAssertEqual(try store.session(id: a.id)?.state, .complete)
        XCTAssertEqual(try store.session(id: a.id)?.title, "Late retry")

        await coordinator.stop()
        XCTAssertEqual(try store.session(id: b.id)?.state, .complete)
    }

    // Audit #3 (major). Retry had no in-flight guard: a second click while a
    // fusion was already running spawned a second concurrent run — a second
    // PAID API call — and the stale outcome could land last and win.
    func testSecondRetryWhileOneIsInFlightDoesNotStartASecondFusionRun() async throws {
        let store = try MeetingStore.inMemory()
        let transcriber = MockTranscriber()
        let fusion = GatedFusionRunner(
            outcomes: [
                .failure(.provider("network down")), // call 0: stop()'s run
                .failure(.provider("still down")),   // call 1: first retry, held open
                .success(noteId: UUID(), title: "Third time"), // call 2: only after release
            ],
            gateFromCall: 1
        )
        let coordinator = SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: transcriber,
            lookback: 20,
            transcriptDrainTimeout: 1,
            fusionRunner: { await fusion.run($0) }
        )

        let a = try await coordinator.start()
        await coordinator.stop()
        XCTAssertEqual(fusion.calls.count, 1)

        let firstRetry = Task { await coordinator.retryFusion() }
        let firstRetryInFlight = await fusion.waitUntilEntered(2)
        XCTAssertTrue(firstRetryInFlight, "the first retry's fusion is in flight")

        // Second click, while the first run is still going. Raced against a
        // deadline: without the guard this call ENTERS the parked runner and
        // never returns, which would wedge the suite instead of failing it.
        let returnedPromptly = await completes(within: 2) { await coordinator.retryFusion() }
        XCTAssertTrue(returnedPromptly,
                      "a Retry while a run is in flight must be a no-op, not a second parked run")
        XCTAssertEqual(fusion.calls.count, 2,
                       "no second concurrent fusion run (a second PAID API call)")

        fusion.openGate()
        await firstRetry.value
        XCTAssertEqual(fusion.calls.count, 2, "still exactly one run per retry")
        XCTAssertEqual(try store.session(id: a.id)?.state, .processing,
                       "the in-flight run's own outcome (failure) is what landed")

        // The guard is released on completion: the next Retry is admitted.
        await coordinator.retryFusion()
        XCTAssertEqual(fusion.calls.count, 3, "the in-flight guard is released on every exit path")
        XCTAssertEqual(try store.session(id: a.id)?.state, .complete)
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
