import XCTest
import Persistence
@testable import TranscribeKit

// MARK: - Test helpers

/// Instrumented fake engine: no model, no network. Records concurrent
/// entries (serial-exclusivity assertion) and optionally sleeps to widen the
/// race window. Responses are injected per test.
final class FakeEngine: WhisperEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxConcurrent = 0
    var delayNanoseconds: UInt64 = 0
    var respond: @Sendable ([Float]) -> [WhisperHypothesis] = { _ in [] }

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        lock.lock()
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        lock.unlock()

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let result = respond(samples)

        lock.lock()
        inFlight -= 1
        lock.unlock()
        return result
    }
}

/// Thread-safe segment sink so tests can poll emissions while streams run.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var segments: [TranscriptSegment] = []

    func append(_ segment: TranscriptSegment) {
        lock.lock()
        segments.append(segment)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return segments.count
    }

    var snapshot: [TranscriptSegment] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }
}

enum Samples {
    static let sampleRate = 16_000.0

    /// 100 ms of constant-amplitude speech (RMS well above threshold).
    static func speechChunk(channel: Channel, offset: Double) -> AudioChunk {
        AudioChunk(
            channel: channel,
            sessionOffset: offset,
            sampleRate: sampleRate,
            samples: Array(repeating: Float(0.3), count: 1_600)
        )
    }

    /// 100 ms of digital silence.
    static func silenceChunk(channel: Channel, offset: Double) -> AudioChunk {
        AudioChunk(
            channel: channel,
            sessionOffset: offset,
            sampleRate: sampleRate,
            samples: Array(repeating: Float(0), count: 1_600)
        )
    }

    /// Feeds `seconds` of a kind in 100 ms chunks, returning the next offset.
    @discardableResult
    static func feed(
        _ kind: @escaping (Channel, Double) -> AudioChunk,
        seconds: Double,
        startingAt start: Double,
        channel: Channel,
        into continuation: AsyncStream<AudioChunk>.Continuation
    ) -> Double {
        var offset = start
        // Rounded, not truncated: 0.3 / 0.1 is 2.999… in binary FP.
        let chunkCount = Int((seconds / 0.1).rounded())
        for _ in 0..<chunkCount {
            continuation.yield(kind(channel, offset))
            offset += 0.1
        }
        return offset
    }
}

/// Wires a transcriber to a chunk stream; returns the feed continuation and
/// a collector task (call `task.value` after `continuation.finish()`).
func makePipeline(
    _ transcriber: any Transcriber
) -> (AsyncStream<AudioChunk>.Continuation, Collector, Task<Void, Never>) {
    let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
    let collector = Collector()
    let segments = transcriber.transcribe(stream: stream)
    let task = Task {
        for await segment in segments {
            collector.append(segment)
        }
    }
    return (continuation, collector, task)
}

func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @autoclosure () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - Windowing

final class WhisperKitTranscriberWindowingTests: XCTestCase {

    /// 0.3 s silence → 2 s speech → 1.5 s (≥ the 1.2 s hangover) silence emits EXACTLY one
    /// segment whose text/offsets round-trip (SPEC §4.2 windowing rule).
    /// The trailing-silence amount also proves hangover closure happened
    /// BEFORE stream end: finish() would otherwise emit the window itself.
    func testTwoSecondBurstFollowedBySilenceEmitsExactlyOneSegment() async throws {
        let engine = FakeEngine()
        engine.respond = { samples in
            [WhisperHypothesis(
                text: "hello there",
                startSeconds: 0,
                endSeconds: Double(samples.count) / Samples.sampleRate
            )]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.silenceChunk, seconds: 0.3, startingAt: offset, channel: .local, into: continuation)
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        offset = Samples.feed(Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        XCTAssertEqual(collector.count, 1, "one window, one segment — silence dropped, no duplicates")
        let segment = try XCTUnwrap(collector.snapshot.first)
        XCTAssertEqual(segment.text, "hello there")
        XCTAssertEqual(segment.channel, .local)
        // Window opens at the first speech sample (0.3 s in); the fake
        // hypothesis spans the trimmed speech buffer.
        XCTAssertEqual(segment.startOffset, 0.3, accuracy: 0.05)
        XCTAssertEqual(segment.endOffset, 2.3, accuracy: 0.05)
        XCTAssertTrue(segment.isFinal, "v0: first emission is final (no re-decode loop)")
    }

    /// Leading silence is dropped entirely — no engine call, no segment.
    func testPureSilenceEmitsNothing() async {
        let engine = FakeEngine()
        engine.respond = { _ in
            XCTFail("engine must not be called for pure silence")
            return []
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        Samples.feed(Samples.silenceChunk, seconds: 3.0, startingAt: 0, channel: .remote, into: continuation)
        continuation.finish()
        await task.value

        XCTAssertTrue(collector.segments.isEmpty)
    }

    /// A second burst after a hangover-length pause opens a NEW window
    /// (proves the first window actually closed on hangover, not on finish).
    func testSecondBurstAfterSilenceOpensNewWindow() async {
        let engine = FakeEngine()
        engine.respond = { samples in
            [WhisperHypothesis(text: "burst", startSeconds: 0, endSeconds: Double(samples.count) / Samples.sampleRate)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)
        offset = Samples.feed(Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)
        offset = Samples.feed(Samples.speechChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 2)
        continuation.finish()
        await task.value

        let segments = collector.snapshot
        XCTAssertEqual(segments.count, 2)
        XCTAssertTrue(segments[0].id != segments[1].id, "different windows mint different ids")
        XCTAssertEqual(segments[1].startOffset, 3.0, accuracy: 0.05, "second burst starts at 1.5 + 1.5 of silence")
    }

    /// Speech shorter than the 0.4 s minimum is dropped (not worth a decode).
    func testSubMinimumBurstIsDropped() async {
        let engine = FakeEngine()
        engine.respond = { _ in
            XCTFail("engine must not be called for a sub-minimum burst")
            return []
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.speechChunk, seconds: 0.2, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)
        continuation.finish()
        await task.value

        XCTAssertTrue(collector.segments.isEmpty)
    }

    /// Session stop finalizes pending speech even without trailing silence
    /// (SPEC §4.4: stop finalizes pending segments).
    func testFinishFlushesPendingSpeech() async {
        let engine = FakeEngine()
        engine.respond = { samples in
            [WhisperHypothesis(text: "cut off", startSeconds: 0, endSeconds: Double(samples.count) / Samples.sampleRate)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: 0, channel: .local, into: continuation)
        continuation.finish()
        await task.value

        XCTAssertEqual(collector.count, 1)
        XCTAssertEqual(collector.snapshot[0].text, "cut off")
    }

    /// A session-clock gap (device switch, SPEC §4.1) closes the window
    /// rather than stitching across the hole.
    func testDeviceGapSplitsWindows() async {
        let engine = FakeEngine()
        engine.respond = { samples in
            [WhisperHypothesis(text: "gap", startSeconds: 0, endSeconds: Double(samples.count) / Samples.sampleRate)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        // 1.2 s speech, then the next chunk arrives 5 s later (no silence
        // chunks in between — an honest gap in offsets).
        Samples.feed(Samples.speechChunk, seconds: 1.2, startingAt: 0, channel: .local, into: continuation)
        Samples.feed(Samples.speechChunk, seconds: 1.2, startingAt: 6.2, channel: .local, into: continuation)
        continuation.finish()
        await task.value

        XCTAssertEqual(collector.count, 2, "gap splits the window; neither side may stitch across")
        if collector.count == 2 {
            XCTAssertEqual(collector.snapshot[1].startOffset, 6.2, accuracy: 0.05)
        }
    }
}

// MARK: - Segment id stability

final class SegmentIdStabilityTests: XCTestCase {

    /// SPEC §4.2 hard rule, unit level: the LRU mints one id per window and
    /// reuses it for revisions (re-emissions) of the same window start; a
    /// different window mints a new id.
    func testSameWindowReusesIdDifferentWindowMintsNew() {
        var cache = SegmentIdCache()
        let first = cache.id(forWindowStart: 11.5)
        let revision = cache.id(forWindowStart: 11.5)
        let otherWindow = cache.id(forWindowStart: 42.0)

        XCTAssertEqual(first, revision, "revisions of the same window share the id (upsert key)")
        XCTAssertNotEqual(first, otherWindow, "a different window mints a new id")
    }

    func testLRUEvictsOldestWindow() {
        var cache = SegmentIdCache(capacity: 2)
        let a = cache.id(forWindowStart: 1.0)
        _ = cache.id(forWindowStart: 2.0)
        _ = cache.id(forWindowStart: 3.0) // evicts window 1.0
        let aAgain = cache.id(forWindowStart: 1.0)

        XCTAssertNotEqual(a, aAgain, "evicted window revisions mint a fresh id (accepted Phase 2 edge)")
    }

    /// Through-path: two decodes of the same window (revision) share the id,
    /// exercised via the worker's decode path with a fake that returns the
    /// same window twice — the second emission replaces (same id), never
    /// appends. Driven directly since v0 has no re-decode loop: this pins
    /// the contract Phase 2 builds on.
    func testRevisionsThroughWorkerShareId() async {
        let engine = FakeEngine()
        engine.respond = { _ in [WhisperHypothesis(text: "first take", startSeconds: 0, endSeconds: 2.0)] }
        let collector = Collector()
        let worker = ChannelWorker(channel: .local, engine: engine) { collector.append($0) }

        var offset = 0.0
        for _ in 0..<30 { await worker.feed(Samples.speechChunk(channel: .local, offset: offset)); offset += 0.1 }
        for _ in 0..<15 { await worker.feed(Samples.silenceChunk(channel: .local, offset: offset)); offset += 0.1 }
        await waitUntil(collector.count == 1)

        // "Revision": a Phase 2 re-decode of the same window replays through
        // the same id-cache lookup. The window opened at offset 0.0 (speech
        // from the very first chunk).
        await worker.reviseForTesting(windowStart: 0.0, text: "better take")

        XCTAssertEqual(collector.count, 2)
        XCTAssertEqual(collector.snapshot[0].id, collector.snapshot[1].id, "revision reuses the window id — upsert, not append")
        XCTAssertEqual(collector.snapshot[1].text, "better take")
    }
}

// MARK: - Serial-queue exclusivity

final class EngineExclusivityTests: XCTestCase {

    /// SPEC §4.2: one model, two serial queues — a slow engine hit from BOTH
    /// channels concurrently must never run two inferences at once.
    func testBothChannelsNeverRunConcurrentInferences() async {
        let engine = FakeEngine()
        engine.delayNanoseconds = 120_000_000 // 120 ms — wide race window
        engine.respond = { samples in
            [WhisperHypothesis(text: "x", startSeconds: 0, endSeconds: Double(samples.count) / Samples.sampleRate)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)

        let (localStream, localContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let (remoteStream, remoteContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let localCollector = Collector()
        let remoteCollector = Collector()

        let localSegments = transcriber.transcribe(stream: localStream)
        let remoteSegments = transcriber.transcribe(stream: remoteStream)
        let localTask = Task { for await s in localSegments { localCollector.append(s) } }
        let remoteTask = Task { for await s in remoteSegments { remoteCollector.append(s) } }

        for pair in [(Channel.local, localContinuation), (Channel.remote, remoteContinuation)] {
            let (chan, continuation) = pair
            var offset = 0.0
            for _ in 0..<15 { continuation.yield(Samples.speechChunk(channel: chan, offset: offset)); offset += 0.1 }
            for _ in 0..<10 { continuation.yield(Samples.silenceChunk(channel: chan, offset: offset)); offset += 0.1 }
        }

        await waitUntil(localCollector.count == 1 && remoteCollector.count == 1)
        localContinuation.finish()
        remoteContinuation.finish()
        await localTask.value
        await remoteTask.value

        XCTAssertEqual(localCollector.count, 1)
        XCTAssertEqual(remoteCollector.count, 1)
        XCTAssertEqual(engine.maxConcurrent, 1, "two serial queues share ONE engine; inference is globally exclusive")
    }
}

// MARK: - Offsets

final class OffsetMathTests: XCTestCase {

    /// 16 kHz math sanity (SPEC §4.2): chunk at sessionOffset 10 s, speech
    /// starting 1.5 s into the accumulated buffer → startOffset ≈ 11.5 s.
    func testStartOffsetAnchorsAtSessionPlusBufferPosition() async throws {
        let engine = FakeEngine()
        engine.respond = { samples in
            [WhisperHypothesis(text: "anchored", startSeconds: 0, endSeconds: Double(samples.count) / Samples.sampleRate)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 10.0
        offset = Samples.feed(Samples.silenceChunk, seconds: 1.5, startingAt: offset, channel: .local, into: continuation)
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .local, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .local, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        let segment = try XCTUnwrap(collector.snapshot.first)
        XCTAssertEqual(segment.startOffset, 11.5, accuracy: 0.05)
        XCTAssertEqual(segment.endOffset, 13.5, accuracy: 0.05)
    }

    /// Hypothesis offsets are window-relative: a hypothesis starting mid
    /// window shifts the segment start by the same amount.
    func testHypothesisOffsetsAreWindowRelative() async throws {
        let engine = FakeEngine()
        engine.respond = { _ in
            [WhisperHypothesis(text: "late", startSeconds: 0.75, endSeconds: 1.9)]
        }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        var offset = 0.0
        offset = Samples.feed(Samples.silenceChunk, seconds: 0.5, startingAt: offset, channel: .remote, into: continuation)
        offset = Samples.feed(Samples.speechChunk, seconds: 2.0, startingAt: offset, channel: .remote, into: continuation)
        Samples.feed(Samples.silenceChunk, seconds: 1.0, startingAt: offset, channel: .remote, into: continuation)

        await waitUntil(collector.count == 1)
        continuation.finish()
        await task.value

        let segment = try XCTUnwrap(collector.snapshot.first)
        XCTAssertEqual(segment.startOffset, 0.5 + 0.75, accuracy: 0.05, "window start + hypothesis start")
        XCTAssertEqual(segment.endOffset, 0.5 + 1.9, accuracy: 0.05)
        XCTAssertEqual(segment.channel, .remote)
    }
}

// MARK: - Model download manager (no network)

final class ModelDownloadManagerTests: XCTestCase {

    func testLocalFolderLivesUnderAppSupportModelsRoot() {
        let root = URL(fileURLWithPath: "/tmp/scribe-test-models")
        let manager = ModelDownloadManager(modelRoot: root)
        XCTAssertEqual(
            manager.localFolder(forModelNamed: "small.en").path,
            root.appending(path: "small.en").path
        )
    }

    func testIsDownloadedFalseForMissingModel() {
        let manager = ModelDownloadManager(modelRoot: URL(fileURLWithPath: "/tmp/scribe-test-models-missing"))
        XCTAssertFalse(manager.isDownloaded("small.en"))
    }

    func testIsDownloadedDetectsCompiledBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "scribe-mdm-\(UUID().uuidString)")
        let variant = root
            .appending(path: "models--argmaxinc--whisperkit-coreml/snapshots/abc/openai_whisper-small.en")
        let bundle = variant.appending(path: "melSpectrogram.mlmodelc")
        try FileManager.default.createDirectory(
            at: bundle.appending(path: "weights"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = ModelDownloadManager(modelRoot: root)

        // An interrupted download leaves the directory tree and the small
        // metadata files but no weights, and that state used to report
        // "Downloaded" — a real 889 MB model stalled at 9.7 MB, said it was
        // ready, then failed to load at session start and produced an empty
        // transcript with no error. Presence therefore requires real weights.
        XCTAssertFalse(
            manager.isDownloaded("small.en"),
            "a bundle with an empty weights/ directory is a half-finished download"
        )

        try Data(repeating: 0, count: 2_000_000)
            .write(to: bundle.appending(path: "weights/weight.bin"))
        XCTAssertTrue(manager.isDownloaded("small.en"))
        XCTAssertFalse(manager.isDownloaded("large-v3-turbo"))
    }

    func testDefaultRootIsScribeAppSupportModels() {
        XCTAssertTrue(
            ModelDownloadManager.defaultModelRoot.path
                .hasSuffix("Library/Application Support/Scribe/models")
        )
    }
}
