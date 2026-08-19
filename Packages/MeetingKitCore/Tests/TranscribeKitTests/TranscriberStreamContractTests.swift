import Persistence
import XCTest
@testable import TranscribeKit

// MARK: - The invariant
//
// `Transcriber.transcribe(stream:)` hands back an `AsyncStream`. The stream
// ends only when its continuation is FINISHED — a continuation that is merely
// dropped leaves the consumer suspended forever, because the stream's own
// storage owns it. Every consumer in the app is a `for await` inside
// `TranscriptPipeline`, and `SessionCoordinator.stop()` waits on those
// consumers, so "the output stream must end" is the contract that makes Stop
// possible at all.
//
// It shipped broken. `App/LazyWhisperKitTranscriber.transcribe(stream:)`
// finished its continuation on the model-MISSING branch and not on the
// model-LOADED one. Stop worked in every test and every demo where the model
// had not loaded, and hung forever the moment it had (T10 dogfood bug).
//
// So the tests below do not check "this one case works". They enumerate every
// branch a transcription can take — loaded, missing, throwing, cancelled,
// empty input, zero segments, blocked behind another channel's inference —
// and assert termination for each. `runTranscription` is the single harness;
// adding a branch means adding a case, not a new style of test.

// MARK: - Deterministic gates (no sleeps)

/// One-shot async event. `wait()` suspends until `signal()`; no polling, so
/// tests using it are timing-independent rather than timing-tolerant.
final class StreamEvent: @unchecked Sendable {

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

    /// Bounded wait — returns `false` if the signal never came.
    ///
    /// An unbounded `wait()` in a test does not fail, it HANGS, and it takes
    /// the whole suite with it: when the VAD hangover moved from 0.8 s to
    /// 1.2 s, the 1 s of trailing silence below stopped closing windows, no
    /// decode ever started, and `swift test` sat on this file forever with no
    /// output. A test must be able to fail.
    @discardableResult
    func wait(within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isSignalled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return isSignalled
    }
}

/// A suspension that ends on `release()` OR on cancellation of the awaiting
/// task — the deterministic stand-in for "an inference that is taking a long
/// time". Nothing here sleeps.
final class CancellablePark: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func release() { resume() }

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            // May run BEFORE the continuation is installed; `finished` makes
            // that ordering irrelevant.
            self.resume()
        }
    }

    private func resume() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume()
    }
}

// MARK: - Harness

/// What one `transcribe(stream:)` call did.
struct TranscriptionRun {
    /// The output stream ENDED (its continuation was finished) before the
    /// deadline. This is the invariant; `false` is the shipped bug.
    let outputEnded: Bool
    let segments: [TranscriptSegment]
    private let probe: InputTerminationProbe

    init(outputEnded: Bool, segments: [TranscriptSegment], probe: InputTerminationProbe) {
        self.outputEnded = outputEnded
        self.segments = segments
        self.probe = probe
    }

    /// How the transcriber let go of its INPUT stream: `"finished"` when it
    /// consumed to the end, `"cancelled"` when it was torn down, `nil` when it
    /// is STILL HOLDING ON after `timeout` — the leak shape where an abandoned
    /// stream keeps decoding into the next session's lifetime.
    ///
    /// Awaited rather than sampled: a transcriber releases its input one hop
    /// after the output stream ends, and sampling that hop is how a test
    /// becomes a coin flip. The wait is event-driven, so the passing case
    /// costs nothing.
    func inputTermination(within timeout: TimeInterval = 2) async -> String? {
        await probe.reason(within: timeout)
    }
}

/// Records how an input stream was released, so a test can tell "consumed to
/// the end" from "torn down by cancellation" — and can WAIT for either.
final class InputTerminationProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var storedReason: String?
    private let terminated = StreamEvent()

    func record(_ termination: AsyncStream<AudioChunk>.Continuation.Termination) {
        lock.lock()
        switch termination {
        case .finished: storedReason = "finished"
        case .cancelled: storedReason = "cancelled"
        @unknown default: storedReason = "unknown"
        }
        lock.unlock()
        terminated.signal()
    }

    /// Suspends until the input is released, or `timeout` elapses.
    func reason(within timeout: TimeInterval) async -> String? {
        let (reports, report) = AsyncStream<Bool>.makeStream()
        let waiter = Task {
            await terminated.wait()
            report.yield(true)
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            report.yield(false)
        }
        for await _ in reports { break }
        waiter.cancel()
        deadline.cancel()

        lock.lock()
        defer { lock.unlock() }
        return storedReason
    }
}

/// Drives ONE transcription end to end and reports whether its output stream
/// terminated. The deadline race is deliberately not a task group: a group
/// awaits every child, so the stalled consumer would re-introduce the very
/// hang the harness exists to detect.
///
/// - Parameters:
///   - timeout: bound on the OUTPUT stream ending. Kept short — a passing
///     case ends immediately, so this only sets how long a regression costs.
///   - finishInput: whether to end the input stream after `feed` (false
///     models a session that is torn down mid-recording).
///   - cancelConsumerWhen: optional gate; when it signals, the consuming task
///     is cancelled. This is how "the pipeline abandoned this stream" is
///     reproduced.
func runTranscription(
    _ transcriber: any Transcriber,
    timeout: TimeInterval = 2,
    finishInput: Bool = true,
    cancelConsumerWhen: StreamEvent? = nil,
    feed: (AsyncStream<AudioChunk>.Continuation) -> Void = { _ in }
) async -> TranscriptionRun {
    let probe = InputTerminationProbe()
    let (input, feeder) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
    feeder.onTermination = { probe.record($0) }

    let output = transcriber.transcribe(stream: input)
    let sink = SegmentSink()
    let (reports, report) = AsyncStream<Bool>.makeStream()
    let consumer = Task {
        for await segment in output { sink.append(segment) }
        report.yield(true)
    }
    if let cancelConsumerWhen {
        Task {
            await cancelConsumerWhen.wait()
            consumer.cancel()
        }
    }

    feed(feeder)
    if finishInput { feeder.finish() }

    let deadline = Task {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        report.yield(false)
    }
    var ended = false
    for await outcome in reports {
        ended = outcome
        break
    }
    deadline.cancel()
    if !ended { consumer.cancel() }
    return TranscriptionRun(outputEnded: ended, segments: sink.snapshot, probe: probe)
}

/// Thread-safe sink (the target already has a `Collector`; this one is local
/// to the contract harness so the two can evolve independently).
final class SegmentSink: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [TranscriptSegment] = []

    func append(_ segment: TranscriptSegment) {
        lock.lock()
        storage.append(segment)
        lock.unlock()
    }

    var snapshot: [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - Engines

/// Answers every window, then fails from `failingFromCall` onwards. Models an
/// engine that dies mid-meeting (OOM, model unload, a decode error).
final class FlakyEngine: WhisperEngine, @unchecked Sendable {

    struct DecodeFailure: Error {}

    private let lock = NSLock()
    private var calls = 0
    private let failingFromCall: Int

    /// - Parameter failingFromCall: 0 fails every call; 1 answers the first
    ///   window and fails afterwards.
    init(failingFromCall: Int) {
        self.failingFromCall = failingFromCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        lock.lock()
        let index = calls
        calls += 1
        lock.unlock()

        if index >= failingFromCall { throw DecodeFailure() }
        return [WhisperHypothesis(text: "window \(index)", startSeconds: 0, endSeconds: 1)]
    }
}

/// Parks inside the decode until released or cancelled — a decode that is
/// genuinely in flight, without a sleep anywhere.
final class ParkingEngine: WhisperEngine, @unchecked Sendable {

    let entered = StreamEvent()
    let left = StreamEvent()
    private let park = CancellablePark()

    func release() { park.release() }

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        entered.signal()
        await park.wait()
        left.signal()
        return [WhisperHypothesis(text: "released", startSeconds: 0, endSeconds: 1)]
    }
}

/// Reproduces the SHAPE of `App/LazyWhisperKitTranscriber`: resolve a model
/// first, forward an inner transcriber's output on the loaded branch, drain
/// through `UnimplementedTranscriber` on the missing branch.
///
/// `finishesLoadedBranch` is the whole point. `false` is the code that
/// shipped — and the reason this harness exists rather than a single happy
/// case. The App target has no test target of its own; this double keeps the
/// contract that file must satisfy inside a suite that runs on every build.
final class ResolvingTranscriberDouble: Transcriber, @unchecked Sendable {

    private let engine: (any WhisperEngine)?
    private let finishesLoadedBranch: Bool

    /// - Parameters:
    ///   - engine: `nil` reproduces "model not downloaded".
    ///   - finishesLoadedBranch: `false` reproduces the shipped defect.
    init(engine: (any WhisperEngine)?, finishesLoadedBranch: Bool = true) {
        self.engine = engine
        self.finishesLoadedBranch = finishesLoadedBranch
    }

    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task { [engine, finishesLoadedBranch] in
                if let engine {
                    let inner = WhisperKitTranscriber(engine: engine)
                    for await segment in inner.transcribe(stream: stream) {
                        continuation.yield(segment)
                    }
                    guard finishesLoadedBranch else { return } // the shipped bug
                } else {
                    let fallback = UnimplementedTranscriber()
                    for await _ in fallback.transcribe(stream: stream) {}
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Every branch ends its stream

final class TranscriberStreamTerminationTests: XCTestCase {

    private func speechThenSilence(_ feeder: AsyncStream<AudioChunk>.Continuation) {
        let afterSpeech = Samples.feed(
            Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .local, into: feeder
        )
        Samples.feed(
            Samples.silenceChunk, seconds: 1.5, startingAt: afterSpeech, channel: .local, into: feeder
        )
    }

    // The ordinary path: a model is loaded, audio decodes, the input ends.
    // The output stream must end too, or Stop never returns.
    func testALoadedModelEndsItsStreamOnceTheInputEnds() async {
        let engine = FakeEngine()
        engine.respond = { _ in [WhisperHypothesis(text: "hello", startSeconds: 0, endSeconds: 1)] }

        let run = await runTranscription(WhisperKitTranscriber(engine: engine), feed: speechThenSilence)

        XCTAssertTrue(run.outputEnded, "a completed transcription must end its output stream")
        let released = await run.inputTermination()
        XCTAssertEqual(released, "finished", "the input was consumed, not abandoned")
        XCTAssertFalse(run.segments.isEmpty, "and it produced the transcript it was asked for")
    }

    // The missing-model fallback. This branch DID finish, which is exactly why
    // the defect stayed hidden: everything worked until the model loaded.
    func testTheMissingModelFallbackEndsItsStream() async {
        let run = await runTranscription(UnimplementedTranscriber(), feed: speechThenSilence)

        XCTAssertTrue(run.outputEnded, "the fallback drains the pipeline and ends")
        let released = await run.inputTermination()
        XCTAssertEqual(released, "finished")
        XCTAssertTrue(run.segments.isEmpty, "no model, no transcript — but the stream still ends")
    }

    // A meeting that recorded nothing (started and stopped immediately, or a
    // channel that never received audio) still has to release Stop.
    func testAStreamThatNeverReceivesAudioEndsImmediately() async {
        let run = await runTranscription(WhisperKitTranscriber(engine: FakeEngine()))

        XCTAssertTrue(run.outputEnded, "an empty session must not wedge the drain")
        XCTAssertTrue(run.segments.isEmpty)
    }

    // Audio arrived but nothing was speech: the VAD emits zero segments. A
    // path with no emissions is precisely where a missing `finish()` hides,
    // since there is no output to notice the absence of.
    func testAStreamThatProducesZeroSegmentsStillEnds() async {
        let run = await runTranscription(WhisperKitTranscriber(engine: FakeEngine())) { feeder in
            Samples.feed(Samples.silenceChunk, seconds: 3, startingAt: 0, channel: .local, into: feeder)
        }

        XCTAssertTrue(run.outputEnded)
        XCTAssertTrue(run.segments.isEmpty, "silence decodes to nothing (VAD never opened a window)")
    }

    // Every decode fails. v0 drops the window (documented in ChannelWorker);
    // dropping a window must not mean dropping the stream's termination.
    func testAnEngineThatFailsEveryDecodeStillEndsTheStream() async {
        let engine = FlakyEngine(failingFromCall: 0)

        let run = await runTranscription(WhisperKitTranscriber(engine: engine), feed: speechThenSilence)

        XCTAssertTrue(run.outputEnded, "a failing engine must not hold the session open")
        XCTAssertTrue(run.segments.isEmpty)
        XCTAssertGreaterThan(engine.callCount, 0, "the engine really was asked to decode")
    }

    // The engine dies partway through: earlier segments survive, the stream
    // still ends. (Two speech bursts → two windows → two decodes.)
    func testAnEngineThatFailsMidStreamKeepsEarlierSegmentsAndStillEnds() async {
        let engine = FlakyEngine(failingFromCall: 1)

        let run = await runTranscription(WhisperKitTranscriber(engine: engine)) { feeder in
            var offset = Samples.feed(
                Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .local, into: feeder
            )
            offset = Samples.feed(
                Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: feeder
            )
            offset = Samples.feed(
                Samples.speechChunk, seconds: 1.5, startingAt: offset, channel: .local, into: feeder
            )
            Samples.feed(
                Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: feeder
            )
        }

        XCTAssertTrue(run.outputEnded, "a mid-stream engine failure must not wedge the drain")
        XCTAssertEqual(run.segments.count, 1, "the window decoded before the failure is kept")
        XCTAssertEqual(run.segments.first?.text, "window 0")
        XCTAssertEqual(engine.callCount, 2, "the second window was attempted and failed")
    }

    // The pipeline's bounded drain cancels its consumers on timeout. A
    // cancelled consumer must make the transcriber let go of the input, or
    // the abandoned stream keeps decoding into the next session's lifetime.
    func testCancellingTheConsumerReleasesTheTranscribersHoldOnTheInput() async {
        let cancel = StreamEvent()
        let engine = FakeEngine()
        engine.respond = { _ in [] }

        // Input is never finished: this is a teardown mid-recording.
        let run = await runTranscription(
            WhisperKitTranscriber(engine: engine),
            finishInput: false,
            cancelConsumerWhen: cancel
        ) { feeder in
            Samples.feed(Samples.speechChunk, seconds: 0.5, startingAt: 0, channel: .local, into: feeder)
            cancel.signal()
        }

        // The consumer was cancelled, so `outputEnded` is not the assertion
        // here — the transcriber releasing its input is.
        let released = await run.inputTermination()
        XCTAssertEqual(released, "cancelled",
                       "an abandoned stream must stop consuming, not decode on into the next session")
    }

    // Cancellation while an inference is genuinely in flight. Nothing may
    // outlive the cancellation — including the decode itself.
    func testCancellationUnblocksATranscriberParkedInsideAnInference() async {
        let engine = ParkingEngine()
        let cancel = StreamEvent()

        let run = await runTranscription(
            WhisperKitTranscriber(engine: engine),
            finishInput: false,
            cancelConsumerWhen: cancel
        ) { feeder in
            let afterSpeech = Samples.feed(
                Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .local, into: feeder
            )
            Samples.feed(
                Samples.silenceChunk, seconds: 1.5, startingAt: afterSpeech, channel: .local, into: feeder
            )
            Task {
                await engine.entered.wait(within: 5) // the decode is in flight
                cancel.signal()
            }
        }

        XCTAssertTrue(engine.entered.isSignalled, "the decode really started")
        let released = await run.inputTermination()
        XCTAssertEqual(released, "cancelled",
                       "cancellation reaches through the in-flight decode")
        // The parked decode itself unwound, not just its caller.
        let unwound = await engine.left.wait(within: 5)
        XCTAssertTrue(unwound, "the in-flight decode never unwound")
    }

    // SPEC §4.2 serialises both channels onto one model. A stream cancelled
    // while QUEUED behind the other channel's decode is not unblocked by the
    // cancellation itself (the gate has no cancellation path) — it unblocks
    // when the permit is released. Asserting that it does terminate then is
    // what keeps that from being an unbounded hold.
    func testAStreamQueuedBehindAnotherChannelsInferenceStillTerminates() async {
        let engine = ParkingEngine()
        let transcriber = WhisperKitTranscriber(engine: engine)

        // Channel one takes the single permit and parks inside the decode.
        let (holderInput, holderFeeder) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let holder = Task {
            for await _ in transcriber.transcribe(stream: holderInput) {}
        }
        let afterSpeech = Samples.feed(
            Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .local, into: holderFeeder
        )
        Samples.feed(
            Samples.silenceChunk, seconds: 1.5, startingAt: afterSpeech, channel: .local, into: holderFeeder
        )
        let holderDecoding = await engine.entered.wait(within: 5)
        XCTAssertTrue(holderDecoding, "channel one never reached a decode — nothing to queue behind")

        // Channel two queues behind it, then the permit is released.
        let release = StreamEvent()
        Task {
            await release.wait()
            engine.release()
        }
        let run = await runTranscription(transcriber) { feeder in
            let afterSpeech = Samples.feed(
                Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .remote, into: feeder
            )
            Samples.feed(
                Samples.silenceChunk, seconds: 1.5, startingAt: afterSpeech, channel: .remote, into: feeder
            )
            release.signal()
        }

        XCTAssertTrue(run.outputEnded, "a queued stream must terminate once the permit frees up")
        holderFeeder.finish()
        holder.cancel()
    }
}

// MARK: - The shipped defect, reproduced

final class LazyResolutionBranchTerminationTests: XCTestCase {

    private func speechThenSilence(_ feeder: AsyncStream<AudioChunk>.Continuation) {
        let afterSpeech = Samples.feed(
            Samples.speechChunk, seconds: 1.5, startingAt: 0, channel: .local, into: feeder
        )
        Samples.feed(
            Samples.silenceChunk, seconds: 1.5, startingAt: afterSpeech, channel: .local, into: feeder
        )
    }

    // Both branches of the resolve-then-transcribe shape, as the App wires it
    // today. Enumerated together on purpose: the defect was one branch
    // finishing and the other not, which no single-branch test can see.
    func testBothResolutionBranchesEndTheirStream() async {
        let engine = FakeEngine()
        engine.respond = { _ in [WhisperHypothesis(text: "hello", startSeconds: 0, endSeconds: 1)] }

        let loaded = await runTranscription(
            ResolvingTranscriberDouble(engine: engine), feed: speechThenSilence
        )
        XCTAssertTrue(loaded.outputEnded, "model LOADED branch must finish its continuation")
        XCTAssertFalse(loaded.segments.isEmpty)

        let missing = await runTranscription(
            ResolvingTranscriberDouble(engine: nil), feed: speechThenSilence
        )
        XCTAssertTrue(missing.outputEnded, "model MISSING branch must finish its continuation")
        XCTAssertTrue(missing.segments.isEmpty)
    }

    // Teeth. The pre-fix implementation is injected verbatim (the loaded
    // branch returns without finishing) and the harness must report a stream
    // that never ended. If this ever passes with `outputEnded == true`, the
    // harness has stopped being able to see the bug it was built for, and
    // every other assertion in this file is worthless.
    func testTheHarnessDetectsTheUnfinishedLoadedBranchThatShipped() async {
        let engine = FakeEngine()
        engine.respond = { _ in [WhisperHypothesis(text: "hello", startSeconds: 0, endSeconds: 1)] }

        let run = await runTranscription(
            ResolvingTranscriberDouble(engine: engine, finishesLoadedBranch: false),
            timeout: 0.5,
            feed: speechThenSilence
        )

        XCTAssertFalse(run.outputEnded,
                       "the pre-fix loaded branch never ends its stream — the harness must see that")
        let released = await run.inputTermination()
        XCTAssertEqual(released, "finished",
                       "and the input WAS fully consumed, which is why the hang looked like a stall")
        XCTAssertFalse(run.segments.isEmpty,
                       "segments even arrived — the transcript was fine; only Stop was broken")
    }
}
