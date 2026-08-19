import CaptureKit
import FusionKit
import Persistence
import ScratchpadKit
import TranscribeKit
import XCTest
@testable import SessionKit

// MARK: - What this file defends
//
// The package had 82 passing tests while Stop hung forever. Every one of them
// drove a single session to completion before asserting anything, so the whole
// class of defects that lives at a session BOUNDARY — a stop still draining
// when the next start arrives, a fusion landing after its session stopped
// being current, a drain that times out — was invisible.
//
// The four groups below are that class, written as invariants rather than as
// cases:
//
//  1. A transcription stream must END, on every branch, or Stop never returns.
//  2. Two sessions may overlap. Neither may write the other's state — and
//     PERSISTED state and DISPLAY state must be asserted separately, because
//     in the shipped bug they diverged (the row was correct; the menu bar was
//     showing the wrong session).
//  3. A session that ends abnormally must still leave the store in a state
//     something can move it out of.
//  4. When the drain timeout fires, everything that already arrived is kept
//     and nothing leaks into the next session.
//
// Timing: no test here sleeps to "let something happen". Gates
// (`Gate`) are one-shot async events, the drain timeout is injected, and the
// few polling helpers poll on a CONDITION rather than on a duration.

// MARK: - Deterministic gates

/// One-shot async event: `wait()` suspends until `signal()`. Lets a test hold
/// a fusion run, or an abandoned transcription, in a precise state without
/// guessing at durations.
final class Gate: @unchecked Sendable {

    private let lock = NSLock()
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isSignalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalled
    }

    func signal() {
        lock.lock()
        guard !signalled else { lock.unlock(); return }
        signalled = true
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signalled {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Races `body` against a deadline WITHOUT a task group — a group awaits all
/// its children, so a hung `body` would wedge the suite instead of failing
/// the test. Returns `false` if `body` had not returned in time.
func returnsWithin(_ timeout: TimeInterval, _ body: @escaping @Sendable () async -> Void) async -> Bool {
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

/// Polls a CONDITION (not a duration) until it holds. Used only where the
/// thing being awaited has no event to hang a gate on — a background task
/// unwinding, or a store row being written by another task.
func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

// MARK: - Capture double

/// Capture engine with NO timer: the test decides exactly when a sample is
/// delivered, so "session B recorded audio" is a fact rather than a race with
/// `StubCaptureEngine`'s 100 ms tick.
final class ManualCaptureEngine: CaptureEngine, @unchecked Sendable {

    var onAudio: ((CapturedSample) -> Void)?
    private(set) var remoteStreamActive = true

    private let lock = NSLock()
    private var startCountStorage = 0
    private var stopCountStorage = 0

    /// When set, `start()` throws it — the "engine failed to start" path.
    var startError: Error?

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return startCountStorage }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopCountStorage }

    func start() async throws {
        lock.lock(); startCountStorage += 1; lock.unlock()
        if let startError { throw startError }
    }

    func stop() async {
        lock.lock(); stopCountStorage += 1; lock.unlock()
    }

    /// Delivers one buffer on the engine's contract (synchronously, as the
    /// real engine does from its processing queue).
    func emit(_ channel: Channel, offset: TimeInterval = 0) {
        onAudio?(CapturedSample(
            channel: channel, sessionOffset: offset, samples: [Float](repeating: 0, count: 1_600)
        ))
    }

    /// One buffer per channel — a minimal "this session heard something".
    func emitBothChannels(offset: TimeInterval = 0) {
        emit(.local, offset: offset)
        emit(.remote, offset: offset)
    }
}

// MARK: - Transcriber double

/// A `Transcriber` whose behaviour is scripted PER STREAM, so a test can put
/// one session's transcription in a chosen state (healthy, never-finishing,
/// stalled, or emitting late) while the next session's is healthy.
///
/// `TranscriptPipeline` calls `transcribe(stream:)` once per channel, so a
/// session consumes two entries of the script.
///
/// Every segment's text carries the index of the stream that produced it.
/// That is what makes "session A's abandoned transcription leaked into
/// session B" an assertion instead of an inference.
final class ScriptedTranscriber: Transcriber, @unchecked Sendable {

    enum Behaviour {
        /// Consumes the input, emits one final segment per channel that
        /// delivered audio, then finishes. A healthy stream.
        case healthy
        /// Emits a segment as soon as audio arrives, consumes the rest of the
        /// input — and then NEVER finishes its continuation. This is the
        /// shipped `LazyWhisperKitTranscriber` model-loaded branch: the
        /// transcript was fine, only the stream's end was missing.
        case emitsThenNeverFinishes
        /// Never even reads the input (the model is still loading), so
        /// finishing the input stream does not finish the output stream.
        case stallsWithoutReadingTheInput
        /// Consumes the input, then holds its output open until the gate is
        /// signalled, then emits and finishes — an abandoned stream that
        /// comes back to life after the NEXT session has started.
        case emitsWhenReleased(Gate)
    }

    private let lock = NSLock()
    private var script: [Behaviour]
    private let fallback: Behaviour
    private var streamCountStorage = 0
    private var cancelledStreamsStorage = 0
    private var finishedStreamsStorage = 0
    private var inputsEndedStorage = 0
    private var chunkCountsStorage: [Channel: Int] = [:]

    init(script: [Behaviour] = [], then fallback: Behaviour = .healthy) {
        self.script = script
        self.fallback = fallback
    }

    var streamCount: Int { withLock { streamCountStorage } }
    /// Streams torn down by cancellation — how a timed-out drain is supposed
    /// to dispose of the transcription it abandons.
    var cancelledStreams: Int { withLock { cancelledStreamsStorage } }
    var finishedStreams: Int { withLock { finishedStreamsStorage } }
    /// Streams whose INPUT iteration ended (the pipeline closed the feed).
    var inputsEnded: Int { withLock { inputsEndedStorage } }
    func chunkCount(for channel: Channel) -> Int { withLock { chunkCountsStorage[channel] ?? 0 } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        let (index, behaviour) = withLock { () -> (Int, Behaviour) in
            let index = streamCountStorage
            streamCountStorage += 1
            let behaviour = script.isEmpty ? fallback : script.removeFirst()
            return (index, behaviour)
        }
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.run(behaviour, index: index, stream: stream, into: continuation)
            }
            continuation.onTermination = { [weak self] termination in
                task.cancel()
                guard let self else { return }
                switch termination {
                case .cancelled: self.withLock { self.cancelledStreamsStorage += 1 }
                case .finished: self.withLock { self.finishedStreamsStorage += 1 }
                @unknown default: break
                }
            }
        }
    }

    /// Hoisted out of the stream builder (keeps the closure cheap to
    /// type-check, matching the style of the doubles in the sibling file).
    private func run(
        _ behaviour: Behaviour,
        index: Int,
        stream: AsyncStream<AudioChunk>,
        into continuation: AsyncStream<TranscriptSegment>.Continuation
    ) async {
        if case .stallsWithoutReadingTheInput = behaviour {
            // The model load that never lands: the input is never touched, so
            // closing it changes nothing. Only cancellation ends this.
            await Gate().wait()
            return
        }

        var seen: Set<Channel> = []
        var emittedEarly = false
        for await chunk in stream {
            seen.insert(chunk.channel)
            withLock { chunkCountsStorage[chunk.channel, default: 0] += 1 }
            if case .emitsThenNeverFinishes = behaviour, !emittedEarly {
                emittedEarly = true
                continuation.yield(segment(index: index, channel: chunk.channel))
            }
        }
        withLock { inputsEndedStorage += 1 }

        switch behaviour {
        case .emitsThenNeverFinishes:
            return // the shipped defect: no `continuation.finish()`
        case let .emitsWhenReleased(gate):
            await gate.wait()
            for channel in seen.sorted(by: { $0.rawValue < $1.rawValue }) {
                continuation.yield(segment(index: index, channel: channel))
            }
        case .healthy:
            for channel in seen.sorted(by: { $0.rawValue < $1.rawValue }) {
                continuation.yield(segment(index: index, channel: channel))
            }
        case .stallsWithoutReadingTheInput:
            break // unreachable (handled above)
        }
        continuation.finish()
    }

    private func segment(index: Int, channel: Channel) -> TranscriptSegment {
        TranscriptSegment(
            channel: channel,
            text: Self.text(streamIndex: index, channel: channel),
            startOffset: 0,
            endOffset: 1,
            isFinal: false // stop() is what finalises pending hypotheses
        )
    }

    /// The provenance marker: which stream produced this segment.
    static func text(streamIndex: Int, channel: Channel) -> String {
        "stream \(streamIndex) · \(channel.rawValue)"
    }
}

// MARK: - Fusion double

/// Fusion runner that can hold chosen calls open. `gatedCalls` are indices
/// into the call sequence, so one session's run can be parked in flight while
/// the next session's runs to completion.
final class GatedRunner: @unchecked Sendable {

    private let lock = NSLock()
    private var callsStorage: [UUID] = []
    private let outcomes: [FusionRunOutcome] // last entry is sticky
    private let gatedCalls: Set<Int>
    private let gate = Gate()
    private let entered = Gate()

    init(outcomes: [FusionRunOutcome], gatedCalls: Set<Int> = []) {
        precondition(!outcomes.isEmpty)
        self.outcomes = outcomes
        self.gatedCalls = gatedCalls
    }

    var calls: [UUID] { lock.lock(); defer { lock.unlock() }; return callsStorage }

    /// Suspends until a gated call has actually entered the runner.
    func waitUntilParked() async { await entered.wait() }

    func openGate() { gate.signal() }

    func run(_ session: SessionRecord) async -> FusionRunOutcome {
        let index = lock.withLockCounting { callsStorage.append(session.id); return callsStorage.count - 1 }
        if gatedCalls.contains(index) {
            entered.signal()
            await gate.wait()
        }
        return outcomes[min(index, outcomes.count - 1)]
    }
}

private extension NSLock {
    func withLockCounting<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Event recorder

/// Records coordinator events so a test can assert on the DISPLAY-state
/// sequence, which is where the boundary bugs showed up for the user.
final class BoundaryEventRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: [CoordinatorEvent] = []
    private var task: Task<Void, Never>?

    func subscribe(to coordinator: SessionCoordinator) {
        let stream = coordinator.events()
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    private func append(_ event: CoordinatorEvent) {
        lock.lock(); stored.append(event); lock.unlock()
    }

    var events: [CoordinatorEvent] { lock.lock(); defer { lock.unlock() }; return stored }

    var displayStates: [SessionDisplayState] {
        events.compactMap {
            if case .stateChanged(let state) = $0 { return state }
            return nil
        }
    }

    func drainTimeouts(for sessionId: UUID) -> Int {
        events.reduce(0) { count, event in
            if case .transcriptDrainTimedOut(let id) = event, id == sessionId { return count + 1 }
            return count
        }
    }

    var recoveredSessionEvents: Int {
        events.reduce(0) { count, event in
            if case .recoveredSessions = event { return count + 1 }
            return count
        }
    }
}

// MARK: - Fixture

/// One coordinator plus the doubles it was built from, so tests read as
/// behaviour rather than as wiring.
struct Fixture {
    let store: MeetingStore
    let engine: ManualCaptureEngine
    let transcriber: ScriptedTranscriber
    let fusion: GatedRunner
    let coordinator: SessionCoordinator
    let recorder: BoundaryEventRecorder
}

func makeFixture(
    script: [ScriptedTranscriber.Behaviour] = [],
    then fallback: ScriptedTranscriber.Behaviour = .healthy,
    outcomes: [FusionRunOutcome] = [.success(noteId: UUID(), title: "Notes")],
    gatedCalls: Set<Int> = [],
    drainTimeout: TimeInterval = 0.3,
    store: MeetingStore? = nil
) throws -> Fixture {
    let store = try store ?? MeetingStore.inMemory()
    let engine = ManualCaptureEngine()
    let transcriber = ScriptedTranscriber(script: script, then: fallback)
    let fusion = GatedRunner(outcomes: outcomes, gatedCalls: gatedCalls)
    let coordinator = SessionCoordinator(
        store: store,
        captureEngine: engine,
        transcriber: transcriber,
        lookback: 20,
        transcriptDrainTimeout: drainTimeout,
        fusionRunner: { await fusion.run($0) }
    )
    let recorder = BoundaryEventRecorder()
    recorder.subscribe(to: coordinator)
    return Fixture(
        store: store, engine: engine, transcriber: transcriber,
        fusion: fusion, coordinator: coordinator, recorder: recorder
    )
}

// MARK: - 1. Stream termination, seen from the session

final class StopTerminationRegressionTests: XCTestCase {

    // The exact shape that shipped. The transcriber is NOT stalled: it reads
    // every chunk, produces a perfectly good transcript, and simply never
    // finishes its output continuation. `TranscriptPipeline`'s consumer
    // therefore never returns, and before the drain was bounded `stop()`
    // awaited it forever — the row stayed `recording`, the panel kept the red
    // dot and a dead Stop, and elapsed froze at 00:00.
    //
    // The existing stall test cannot see this case: it uses a transcriber
    // that never reads the input, which is a different failure with the same
    // symptom, and a fix that only handled reading transcribers would pass it.
    func testStopReturnsWhenTheTranscriberDrainsItsInputButNeverEndsItsOutput() async throws {
        let fixture = try makeFixture(then: .emitsThenNeverFinishes)
        let session = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()

        let returned = await returnsWithin(5) { await fixture.coordinator.stop() }
        XCTAssertTrue(returned, "stop() must not be hostage to a stream that never ends")

        // Persisted state: the user-visible half of Stop was committed.
        let row = try XCTUnwrap(try fixture.store.session(id: session.id))
        XCTAssertNotEqual(row.state, .recording, "the row leaves `recording`")
        XCTAssertNotNil(row.endedAt, "wall-clock end is written")

        // Display state: the recording face is dropped (asserted separately —
        // row and display diverged in the real bug).
        XCTAssertTrue(fixture.recorder.displayStates.contains(.processing),
                      "the UI leaves the recording face; states: \(fixture.recorder.displayStates)")
        XCTAssertEqual(fixture.coordinator.elapsed(), 0, "no live session once stopped")
        XCTAssertEqual(fixture.recorder.drainTimeouts(for: session.id), 1,
                       "the abandoned drain is announced, not swallowed")
    }

    // A never-finishing stream costs at most the final in-flight window. What
    // already reached the store must survive, and must be finalised — this is
    // the difference between "we lost the tail" and "we lost the meeting".
    func testSegmentsThatArrivedBeforeAMissingFinishAreKeptAndFinalised() async throws {
        let fixture = try makeFixture(then: .emitsThenNeverFinishes)
        let session = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        let arrived = await eventually { (try? fixture.store.segmentCount(sessionId: session.id)) ?? 0 >= 2 }
        XCTAssertTrue(arrived, "both channels emitted before the drain")

        await fixture.coordinator.stop()

        let segments = try fixture.store.segments(sessionId: session.id)
        XCTAssertEqual(segments.count, 2, "nothing that had already arrived is dropped")
        XCTAssertTrue(segments.allSatisfy(\.isFinal),
                      "stop finalises pending hypotheses even when the drain timed out")
    }
}

// MARK: - 2. TranscriptPipeline (the drain itself)

final class TranscriptPipelineTests: XCTestCase {

    private func chunk(_ channel: Channel) -> CapturedSample {
        CapturedSample(channel: channel, sessionOffset: 0, samples: [Float](repeating: 0, count: 1_600))
    }

    func testFinishReportsDrainedWhenBothConsumersEnd() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber()
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        pipeline.feed(chunk(.local))
        pipeline.feed(chunk(.remote))
        let drained = await pipeline.finish(timeout: 5)

        XCTAssertTrue(drained, "healthy consumers drain")
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 2, "one segment per channel")
    }

    // The bounded drain's whole reason for existing.
    func testFinishReportsTimeoutWhenAConsumerNeverEndsAndStillKeepsItsSegments() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber(then: .emitsThenNeverFinishes)
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        pipeline.feed(chunk(.local))
        let persisted = await eventually { (try? store.segmentCount(sessionId: session.id)) ?? 0 == 1 }
        XCTAssertTrue(persisted, "the pipeline persists on every emission, not at the end")

        var drained = true
        let returned = await returnsWithin(5) { drained = await pipeline.finish(timeout: 0.2) }

        XCTAssertTrue(returned, "finish() is bounded")
        XCTAssertFalse(drained, "and reports the timeout to its caller")
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 1,
                       "everything already emitted is in SQLite — the timeout costs the tail, not the meeting")
    }

    // A timed-out drain that merely walked away would leave the abandoned
    // transcription running: still decoding, still holding the model, into
    // the next session's lifetime.
    func testFinishCancelsTheConsumersItAbandons() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber(then: .stallsWithoutReadingTheInput)
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        pipeline.feed(chunk(.local))
        let drained = await pipeline.finish(timeout: 0.2)

        XCTAssertFalse(drained)
        let cancelled = await eventually { transcriber.cancelledStreams == 2 }
        XCTAssertTrue(cancelled,
                      "both abandoned streams are cancelled; cancelled: \(transcriber.cancelledStreams)")
    }

    // `start()`'s engine-failure path finishes with timeout 0 precisely so a
    // UI click is not left waiting on a model load. Even then the input
    // streams must be closed, or the abandoned transcription keeps consuming.
    func testZeroTimeoutFinishStillClosesTheInputStreams() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber()
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        var drained = true
        let returned = await returnsWithin(2) { drained = await pipeline.finish(timeout: 0) }

        XCTAssertTrue(returned, "a zero timeout returns immediately")
        _ = drained // either outcome is legal at timeout 0; the closing is the contract
        let closed = await eventually { transcriber.inputsEnded == 2 }
        XCTAssertTrue(closed, "both input streams are closed regardless of the timeout")
    }

    func testFeedAfterFinishIsDropped() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber()
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        pipeline.feed(chunk(.local))
        _ = await pipeline.finish(timeout: 5)
        let before = transcriber.chunkCount(for: .local)

        pipeline.feed(chunk(.local))
        pipeline.feed(chunk(.remote))

        XCTAssertEqual(transcriber.chunkCount(for: .local), before,
                       "audio arriving after the drain is dropped, not queued into a dead stream")
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 1)
    }

    // Double-stop reaches here as a second `finish()`. It must be a no-op,
    // not a second `continuation.finish()` on an already-finished stream.
    func testFinishIsSafeToCallTwice() async throws {
        let store = try MeetingStore.inMemory()
        let session = try store.createSession()
        let transcriber = ScriptedTranscriber()
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        pipeline.feed(chunk(.local))
        let first = await pipeline.finish(timeout: 5)
        var second = false
        let returned = await returnsWithin(2) { second = await pipeline.finish(timeout: 5) }

        XCTAssertTrue(first)
        XCTAssertTrue(returned, "the second finish returns")
        XCTAssertTrue(second, "and reports drained — the consumers are long gone")
        XCTAssertEqual(try store.segmentCount(sessionId: session.id), 1, "no duplicate segments")
    }
}

// MARK: - 3. Session-boundary races

final class SessionBoundaryRaceTests: XCTestCase {

    // Start during a stalled drain, asserted on BOTH kinds of state. The
    // sibling file covers session B's segments; what is added here is the
    // display: A's teardown, its drain-timeout announcement and its fusion all
    // land while B is recording, and none of them may move the menu bar off
    // `.recording`. That divergence — correct rows, wrong menu bar — is what
    // left a live meeting with no visible way to stop it.
    func testATeardownLandingDuringTheNextRecordingNeverMovesTheDisplay() async throws {
        let fixture = try makeFixture(
            script: [.stallsWithoutReadingTheInput, .stallsWithoutReadingTheInput],
            then: .healthy,
            drainTimeout: 0.3
        )
        let a = try await fixture.coordinator.start()
        let stopAReturned = Gate()
        let stoppingA = Task { await fixture.coordinator.stop(); stopAReturned.signal() }

        // `stop()` commits `processing` BEFORE the drain — that write is what
        // makes Start legal again, so it is the signal to race against.
        let windowOpen = await eventually { (try? fixture.store.session(id: a.id))?.state == .processing }
        XCTAssertTrue(windowOpen, "stop() commits `processing` before the bounded drain")

        let b = try await fixture.coordinator.start()
        // Self-check: if A's drain had already finished, the overlap this test
        // exists to cover never happened and every assertion below would pass
        // vacuously. Fail loudly instead — the fix is a longer drainTimeout.
        XCTAssertFalse(stopAReturned.isSignalled,
                       "B must start INSIDE A's drain window; raise drainTimeout if this trips")
        fixture.engine.emitBothChannels()
        XCTAssertEqual(fixture.coordinator.displayState, .recording)

        await stoppingA.value // A's drain times out and its fusion applies

        XCTAssertEqual(fixture.coordinator.displayState, .recording,
                       "session A's teardown must not overwrite session B's live recording state")
        XCTAssertEqual(fixture.recorder.displayStates.last, .recording,
                       "no display transition is announced after B started; \(fixture.recorder.events)")
        XCTAssertEqual(fixture.recorder.drainTimeouts(for: a.id), 1)

        // Persisted state: A finished its own lifecycle, B is still live.
        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .complete)
        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .recording)
        XCTAssertNil(try fixture.store.session(id: b.id)?.endedAt)

        await fixture.coordinator.stop()
        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .complete)
        XCTAssertFalse(try fixture.store.segments(sessionId: b.id).isEmpty,
                       "B's audio reached the store — its pipeline outlived A's teardown")
    }

    // A second Start while recording is a user error, not a state change. It
    // must not create a row: an orphan `recording` row would be offered for
    // fusion by the next launch's recovery scan.
    func testASecondStartWhileRecordingLeavesTheFirstSessionUntouched() async throws {
        let fixture = try makeFixture()
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()

        do {
            _ = try await fixture.coordinator.start()
            XCTFail("a second start while recording must throw")
        } catch {
            XCTAssertEqual(error as? SessionCoordinatorError, .alreadyRecording)
        }

        XCTAssertEqual(try fixture.store.allSessions().count, 1, "no orphan row was created")
        XCTAssertEqual(fixture.coordinator.currentSession?.id, a.id)
        XCTAssertEqual(fixture.coordinator.displayState, .recording)
        XCTAssertEqual(fixture.engine.startCount, 1, "the engine was not restarted under the live session")

        await fixture.coordinator.stop()
        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .complete)
        XCTAssertFalse(try fixture.store.segments(sessionId: a.id).isEmpty)
    }

    // Two Stop clicks landing together (or the chip and the menu item both
    // firing). Exactly one fusion run — a second is a second PAID API call
    // whose stale outcome can land last and win.
    func testTwoConcurrentStopsRunFusionExactlyOnce() async throws {
        let fixture = try makeFixture()
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()

        async let first: Void = fixture.coordinator.stop()
        async let second: Void = fixture.coordinator.stop()
        _ = await (first, second)

        XCTAssertEqual(fixture.fusion.calls.count, 1, "one stop, one fusion")
        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .complete)
        XCTAssertEqual(fixture.engine.stopCount, 1, "the engine is torn down once")
        XCTAssertEqual(fixture.recorder.displayStates.filter { $0 == .processing }.count, 1,
                       "one processing announcement; \(fixture.recorder.displayStates)")
    }

    // Back-to-back meetings. The second must be a clean session: its own
    // pipeline, its own segments, and nothing carried over from the first.
    func testStartingImmediatelyAfterStopReturnsGivesTheNewSessionItsOwnTranscript() async throws {
        let fixture = try makeFixture()
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        await fixture.coordinator.stop()

        let b = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        await fixture.coordinator.stop()

        let aSegments = try fixture.store.segments(sessionId: a.id)
        let bSegments = try fixture.store.segments(sessionId: b.id)
        XCTAssertEqual(aSegments.count, 2)
        XCTAssertEqual(bSegments.count, 2)
        // Streams 0/1 served A, streams 2/3 served B: no segment crossed over.
        XCTAssertTrue(aSegments.allSatisfy { $0.text.hasPrefix("stream 0") || $0.text.hasPrefix("stream 1") },
                      "A's transcript came from A's streams: \(aSegments.map(\.text))")
        XCTAssertTrue(bSegments.allSatisfy { $0.text.hasPrefix("stream 2") || $0.text.hasPrefix("stream 3") },
                      "B's transcript came from B's streams: \(bSegments.map(\.text))")
        XCTAssertEqual(fixture.fusion.calls, [a.id, b.id])
    }

    // Stop the NEXT meeting while the previous meeting's fusion is still in
    // flight. Both rows must reach their own outcome, and the display must
    // follow the session the user is actually looking at.
    func testStoppingTheNextSessionWhileThePreviousFusionIsInFlightKeepsBothRowsCorrect() async throws {
        let fixture = try makeFixture(
            outcomes: [
                .failure(.provider("A's provider timed out")), // call 0: A, held open
                .success(noteId: UUID(), title: "B's notes"),  // call 1: B, immediate
            ],
            gatedCalls: [0]
        )
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        let stoppingA = Task { await fixture.coordinator.stop() }
        await fixture.fusion.waitUntilParked()

        // A's fusion is parked; the next meeting runs its full lifecycle.
        let b = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        await fixture.coordinator.stop()

        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .complete)
        XCTAssertEqual(fixture.coordinator.displayState, .done(sessionId: b.id))

        // Now let A's fusion land — after its session stopped being current.
        fixture.fusion.openGate()
        await stoppingA.value

        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .processing,
                       "A's own failure is recorded on A's row (SPEC §4.5)")
        XCTAssertEqual(try fixture.store.session(id: a.id)?.fusionErrorMessage, "A's provider timed out")
        XCTAssertEqual(fixture.coordinator.displayState, .done(sessionId: b.id),
                       "a late outcome for A must not repaint the menu bar for B")
        XCTAssertNil(fixture.coordinator.lastFusionError,
                     "and must not raise the ⚠ state over a session that succeeded")
        XCTAssertEqual(try fixture.store.session(id: b.id)?.fusionErrorMessage, nil)
    }

    // The `stop()` mirror of the retry bug: stop()'s OWN fusion completing
    // during a later recording. `drivesDisplay` is resolved after the await
    // for exactly this reason; resolving it at entry hands a finished run
    // permission to overwrite a live `.recording`.
    func testStopsOwnFusionCompletingDuringALaterRecordingLeavesTheDisplayRecording() async throws {
        let fixture = try makeFixture(
            outcomes: [
                .success(noteId: UUID(), title: "A's notes"), // call 0: A, held open
                .success(noteId: UUID(), title: "B's notes"),
            ],
            gatedCalls: [0]
        )
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        let stoppingA = Task { await fixture.coordinator.stop() }
        await fixture.fusion.waitUntilParked()

        let b = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        XCTAssertEqual(fixture.coordinator.displayState, .recording)

        fixture.fusion.openGate()
        await stoppingA.value

        XCTAssertEqual(fixture.coordinator.displayState, .recording,
                       "A's fusion outcome must not hide B's recording chip")
        XCTAssertEqual(fixture.recorder.displayStates.last, .recording,
                       "no transition announced after B's; \(fixture.recorder.displayStates)")
        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .complete,
                       "A's row still gets its outcome — only the display is scoped")

        await fixture.coordinator.stop()
        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .complete)
    }

    // A retry that FAILS during a later recording. The display guard is the
    // known fix; the warning state is the other half of it — `lastFusionError`
    // drives the persistent ⚠ and must not be raised for a session the user is
    // no longer in.
    func testARetryFailingDuringALaterRecordingRaisesNoWarningOnTheLiveSession() async throws {
        let fixture = try makeFixture(
            outcomes: [
                .failure(.provider("first failure")),  // call 0: stop()'s run
                .failure(.provider("second failure")), // call 1: the retry, held open
                .success(noteId: UUID(), title: "B's notes"), // call 2: B's own stop
            ],
            gatedCalls: [1]
        )
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        await fixture.coordinator.stop()
        XCTAssertEqual(fixture.coordinator.displayState, .failed(sessionId: a.id))
        XCTAssertEqual(fixture.coordinator.lastFusionError, "first failure")

        let retrying = Task { await fixture.coordinator.retryFusion() }
        await fixture.fusion.waitUntilParked()

        let b = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        XCTAssertEqual(fixture.coordinator.displayState, .recording)

        fixture.fusion.openGate()
        await retrying.value

        XCTAssertEqual(fixture.coordinator.displayState, .recording,
                       "a failed retry for A must not flip B's chip to ⚠")
        XCTAssertNotEqual(fixture.coordinator.lastFusionError, "second failure",
                          "and must not publish A's error as the live session's warning")
        XCTAssertEqual(try fixture.store.session(id: a.id)?.fusionErrorMessage, "second failure",
                       "the row still records why A failed, for History and the next launch")
        XCTAssertEqual(try fixture.store.session(id: a.id)?.state, .processing, "A stays retryable")

        await fixture.coordinator.stop()
        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .complete)
    }
}

// MARK: - 4. Abnormal termination

final class AbnormalTerminationTests: XCTestCase {

    // Every stuck session is recovered, not just the newest — and the scan is
    // not repeated once it has done its job, or every launch would re-offer
    // sessions the user already dealt with.
    func testEveryStuckSessionIsRecoveredOnceAndNotAgainOnTheNextLaunch() async throws {
        let store = try MeetingStore.inMemory()
        let stuck = try (0..<3).map { _ in try store.createSession() } // still `recording`, as after a kill -9

        let first = try makeFixture(store: store)
        let sawRecovery = await eventually { first.recorder.recoveredSessionEvents == 1 }
        XCTAssertTrue(sawRecovery, "events: \(first.recorder.events)")

        for session in stuck {
            let row = try XCTUnwrap(try store.session(id: session.id))
            XCTAssertTrue(row.recovered, "every stuck row is flagged, not only the last one")
            XCTAssertEqual(row.state, .processing, "moved to the fusion offer")
            XCTAssertNil(row.endedAt, "crash time is unknown — no invented wall-clock end")
        }
        XCTAssertTrue(first.fusion.calls.isEmpty, "no auto-fusion on recovery")

        // Next launch on the same store: nothing is left in `recording`, so
        // nothing is re-offered.
        let second = try makeFixture(store: store)
        _ = try await second.coordinator.start()
        let started = await eventually { second.recorder.displayStates.contains(.recording) }
        XCTAssertTrue(started)
        XCTAssertEqual(second.recorder.recoveredSessionEvents, 0,
                       "a recovered session is not recovered twice; \(second.recorder.events)")
        await second.coordinator.stop()
    }

    // A crash DURING recovery leaves a row in `processing` with no `endedAt`.
    // The recovery scan only looks at `recording`, so nothing will ever pick
    // this row up again on its own — which is fine only as long as the user
    // can still move it. Assert it is offered-and-actionable rather than
    // stuck, and that fusing it does not invent an end time.
    func testASessionLeftProcessingWithNoEndTimeIsStillFusable() async throws {
        let store = try MeetingStore.inMemory()
        var orphan = try store.createSession()
        orphan.state = .processing
        orphan.recovered = true
        try store.updateSession(orphan)
        try store.upsertSegment(SegmentRecord(
            sessionId: orphan.id, channel: .remote, text: "what was captured before the crash",
            startOffset: 3, endOffset: 9, isFinal: true
        ))

        let fixture = try makeFixture(outcomes: [.success(noteId: UUID(), title: "Recovered")], store: store)
        XCTAssertEqual(fixture.recorder.recoveredSessionEvents, 0, "not in `recording`, so not re-scanned")

        await fixture.coordinator.retryFusion(for: orphan)

        let row = try XCTUnwrap(try store.session(id: orphan.id))
        XCTAssertEqual(row.state, .complete, "the row is movable — nothing is permanently stuck")
        XCTAssertEqual(row.title, "Recovered")
        XCTAssertNil(row.endedAt, "still no invented end time")
        XCTAssertEqual(fixture.coordinator.displayState, .idle,
                       "a non-current session drives no menu-bar state")
    }

    // The engine refuses to start (TCC revoked mid-launch, device gone). The
    // empty row must be deleted — a leftover `recording` row would be offered
    // for fusion by the next launch — and the coordinator must be usable
    // again immediately, not left half-started.
    func testAnEngineThatFailsToStartLeavesNoRowAndNoWedgedCoordinator() async throws {
        struct EngineUnavailable: Error {}
        let fixture = try makeFixture()
        fixture.engine.startError = EngineUnavailable()

        do {
            _ = try await fixture.coordinator.start()
            XCTFail("start() must rethrow the engine's failure")
        } catch {
            XCTAssertTrue(error is EngineUnavailable)
        }

        XCTAssertTrue(try fixture.store.allSessions().isEmpty,
                      "no empty `recording` row survives for the recovery scan to offer")
        XCTAssertNil(fixture.coordinator.currentSession)
        XCTAssertEqual(fixture.coordinator.displayState, .idle)
        let closed = await eventually { fixture.transcriber.inputsEnded == 2 }
        XCTAssertTrue(closed, "the abandoned pipeline's streams are closed, not left consuming")

        // And the next attempt works — the failure is not sticky.
        fixture.engine.startError = nil
        let session = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        await fixture.coordinator.stop()
        XCTAssertEqual(try fixture.store.session(id: session.id)?.state, .complete)
    }
}

// MARK: - 5. Timeout-path consistency

final class DrainTimeoutConsistencyTests: XCTestCase {

    // The drain timeout is recent, and a timeout that leaves a session
    // un-actionable is worse than the hang it replaced. Everything the user
    // needs afterwards has to be true at once: state written, segments kept,
    // reason recorded, Retry working.
    func testATimedOutDrainLeavesTheSessionRetryableWithItsSegmentsIntact() async throws {
        let fixture = try makeFixture(
            then: .emitsThenNeverFinishes,
            outcomes: [
                .failure(.provider("network down")),
                .success(noteId: UUID(), title: "Retried after the timeout"),
            ]
        )
        let session = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        _ = await eventually { (try? fixture.store.segmentCount(sessionId: session.id)) ?? 0 == 2 }

        await fixture.coordinator.stop()

        // 1. State written, 2. segments kept, 3. reason recorded.
        var row = try XCTUnwrap(try fixture.store.session(id: session.id))
        XCTAssertEqual(row.state, .processing, "a timed-out drain still reaches the retryable state")
        XCTAssertNotNil(row.endedAt)
        XCTAssertEqual(row.fusionErrorMessage, "network down")
        XCTAssertEqual(try fixture.store.segmentCount(sessionId: session.id), 2,
                       "no segment that had already arrived is lost to the timeout")
        XCTAssertEqual(fixture.recorder.drainTimeouts(for: session.id), 1)

        // 4. Retry actually works on it.
        await fixture.coordinator.retryFusion()
        row = try XCTUnwrap(try fixture.store.session(id: session.id))
        XCTAssertEqual(row.state, .complete)
        XCTAssertNil(row.fusionErrorMessage)
        XCTAssertEqual(try fixture.store.segmentCount(sessionId: session.id), 2,
                       "the retry fuses the same transcript, it does not re-derive one")
    }

    // The leak the timeout opened: a stale transcription that outlived its
    // session used to be handed to the next one, so session A's abandoned
    // stream and session B's live stream shared a channel worker and an
    // emission sink. Segments then vanished, or landed in the wrong meeting at
    // the wrong offsets. Provenance is asserted per segment: B's transcript
    // may contain only B's streams, and A's late output may reach nobody.
    func testATimedOutDrainsAbandonedStreamsCannotWriteIntoTheNextSession() async throws {
        let late = Gate()
        let fixture = try makeFixture(
            script: [.emitsWhenReleased(late), .emitsWhenReleased(late)], // session A
            then: .healthy,                                              // session B
            drainTimeout: 0.3
        )
        let a = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()
        let stopAReturned = Gate()
        let stoppingA = Task { await fixture.coordinator.stop(); stopAReturned.signal() }

        let windowOpen = await eventually { (try? fixture.store.session(id: a.id))?.state == .processing }
        XCTAssertTrue(windowOpen)

        let b = try await fixture.coordinator.start()
        XCTAssertFalse(stopAReturned.isSignalled,
                       "B must start INSIDE A's drain window; raise drainTimeout if this trips")
        fixture.engine.emitBothChannels()
        await stoppingA.value
        XCTAssertEqual(fixture.recorder.drainTimeouts(for: a.id), 1, "A's drain timed out")

        // A's abandoned streams come back to life mid-way through B.
        late.signal()
        let disposed = await eventually { fixture.transcriber.cancelledStreams >= 2 }
        XCTAssertTrue(disposed,
                      "the timed-out drain disposed of A's streams; cancelled: \(fixture.transcriber.cancelledStreams)")

        fixture.engine.emitBothChannels(offset: 1)
        await fixture.coordinator.stop()

        let bSegments = try fixture.store.segments(sessionId: b.id)
        XCTAssertFalse(bSegments.isEmpty, "B produced its own transcript")
        XCTAssertTrue(bSegments.allSatisfy { $0.text.hasPrefix("stream 2") || $0.text.hasPrefix("stream 3") },
                      "no segment from A's streams (0/1) landed in B: \(bSegments.map(\.text))")
        XCTAssertTrue(try fixture.store.segments(sessionId: a.id)
            .allSatisfy { $0.text.hasPrefix("stream 0") || $0.text.hasPrefix("stream 1") },
                      "and nothing of B's landed in A")
        XCTAssertEqual(try fixture.store.session(id: b.id)?.state, .complete)
    }

    // The timeout is announced once per session, not once per channel stream
    // and not again on a repeat Stop — History and any notice UI key off it.
    func testTheDrainTimeoutIsAnnouncedExactlyOncePerSession() async throws {
        let fixture = try makeFixture(then: .stallsWithoutReadingTheInput)
        let session = try await fixture.coordinator.start()
        fixture.engine.emitBothChannels()

        await fixture.coordinator.stop()
        await fixture.coordinator.stop() // idempotent: no second announcement

        let announced = await eventually { fixture.recorder.drainTimeouts(for: session.id) == 1 }
        XCTAssertTrue(announced,
                      "one announcement per session; events: \(fixture.recorder.events)")
        XCTAssertEqual(fixture.fusion.calls.count, 1, "and one fusion run")
    }
}
