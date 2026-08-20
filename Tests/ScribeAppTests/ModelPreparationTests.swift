import CaptureKit
import FusionKit
import Persistence
import SessionKit
import TranscribeKit
import XCTest

private struct PreparedFakeEngine: WhisperEngine {
    let variant: String
    let probe: EngineFactoryProbe

    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        probe.recordConsumption(of: variant)
        return [WhisperHypothesis(text: variant, startSeconds: 0, endSeconds: 0.5)]
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class SignalCounter<Key: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Key: Int] = [:]
    private var waiters: [(key: Key, target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment(_ key: Key) {
        lock.lock()
        counts[key, default: 0] += 1
        let count = counts[key, default: 0]
        let ready = waiters.filter { $0.key == key && count >= $0.target }
        waiters.removeAll { $0.key == key && count >= $0.target }
        lock.unlock()
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for key: Key, count target: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if counts[key, default: 0] >= target {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((key, target, continuation))
                lock.unlock()
            }
        }
    }
}

private final class EngineFactoryProbe: @unchecked Sendable {
    private struct BuildAccessKey: Hashable {
        let variant: String
        let access: LazyWhisperKitTranscriber.EngineBuildAccess
    }

    private let lock = NSLock()
    private var callsStorage: [String] = []
    private var gates: [String: AsyncGate] = [:]
    private var consumedVariantsStorage: [String] = []
    private let callSignals = SignalCounter<String>()
    private let buildAccessSignals = SignalCounter<BuildAccessKey>()
    var resultAvailable = true

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return callsStorage }
    var consumedVariants: [String] { lock.lock(); defer { lock.unlock() }; return consumedVariantsStorage }
    func suspend(_ variant: String) { lock.lock(); gates[variant] = AsyncGate(); lock.unlock() }
    func release(_ variant: String) {
        lock.lock(); let gate = gates.removeValue(forKey: variant); lock.unlock()
        gate?.open()
    }
    func recordConsumption(of variant: String) {
        lock.lock(); consumedVariantsStorage.append(variant); lock.unlock()
    }
    func recordBuildAccess(
        variant: String,
        access: LazyWhisperKitTranscriber.EngineBuildAccess
    ) {
        buildAccessSignals.increment(BuildAccessKey(variant: variant, access: access))
    }
    func waitForCall(_ variant: String) async {
        await callSignals.wait(for: variant)
    }
    func waitForBuildAccess(
        _ access: LazyWhisperKitTranscriber.EngineBuildAccess,
        variant: String,
        count: Int = 1
    ) async {
        await buildAccessSignals.wait(
            for: BuildAccessKey(variant: variant, access: access), count: count
        )
    }

    func make(_ variant: String) async -> (any WhisperEngine)? {
        lock.lock(); callsStorage.append(variant); let gate = gates[variant]; lock.unlock()
        callSignals.increment(variant)
        await gate?.wait()
        return resultAvailable ? PreparedFakeEngine(variant: variant, probe: self) : nil
    }
}

private final class PreparationCaptureEngine: CaptureEngine, @unchecked Sendable {
    var onAudio: ((CapturedSample) -> Void)?
    var remoteStreamActive = true
    var emitsSpeechOnStart = false
    private let lock = NSLock()
    private var startsStorage = 0
    var starts: Int { lock.lock(); defer { lock.unlock() }; return startsStorage }
    func start() async throws {
        lock.lock(); startsStorage += 1; lock.unlock()
        if emitsSpeechOnStart {
            onAudio?(CapturedSample(
                channel: .local,
                sessionOffset: 0,
                samples: [Float](repeating: 1, count: 8_000)
            ))
        }
    }
    func stop() async {}
}

final class ModelPreparationTests: XCTestCase {
    override func tearDown() {
        LazyWhisperKitTranscriber.engineFactoryForTesting = nil
        LazyWhisperKitTranscriber.onEngineBuildAccessForTesting = nil
        UserDefaults.standard.removeObject(forKey: SettingsKeys.whisperModel)
        super.tearDown()
    }

    private func makeCoordinator(
        transcriber: LazyWhisperKitTranscriber,
        capture: PreparationCaptureEngine = PreparationCaptureEngine()
    ) throws -> (SessionCoordinator, MeetingStore, PreparationCaptureEngine) {
        let store = try MeetingStore.inMemory()
        let coordinator = SessionCoordinator(
            store: store,
            captureEngine: capture,
            transcriber: transcriber,
            transcriptDrainTimeout: 0.2,
            fusionRunner: { _ in .failure(.provider("test")) }
        )
        return (coordinator, store, capture)
    }

    func testAVariantBuildIsSingleFlightAcrossAToBToASelection() async throws {
        let probe = EngineFactoryProbe()
        probe.suspend("tiny.en")
        probe.suspend("base.en")
        LazyWhisperKitTranscriber.engineFactoryForTesting = { await probe.make($0) }
        LazyWhisperKitTranscriber.onEngineBuildAccessForTesting = {
            probe.recordBuildAccess(variant: $0, access: $1)
        }
        let transcriber = LazyWhisperKitTranscriber()

        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let firstA = Task { try await transcriber.prepare() }
        await probe.waitForBuildAccess(.started, variant: "tiny.en")

        UserDefaults.standard.set("base.en", forKey: SettingsKeys.whisperModel)
        let b = Task { try await transcriber.prepare() }
        await probe.waitForBuildAccess(.started, variant: "base.en")

        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let secondA = Task { try await transcriber.prepareForSession() }
        await probe.waitForBuildAccess(.joined, variant: "tiny.en")

        XCTAssertEqual(probe.calls.filter { $0 == "tiny.en" }.count, 1,
                       "the second A has joined the still-blocked first A build")
        XCTAssertEqual(probe.calls.filter { $0 == "base.en" }.count, 1)
        probe.release("tiny.en")
        try await firstA.value
        _ = try await secondA.value
        probe.release("base.en")
        try await b.value
        XCTAssertEqual(probe.calls.filter { $0 == "tiny.en" }.count, 1)
        XCTAssertEqual(probe.calls.filter { $0 == "base.en" }.count, 1)
    }

    func testBackgroundPreparationAndStartShareOneEngineBuild() async throws {
        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let probe = EngineFactoryProbe()
        probe.suspend("tiny.en")
        LazyWhisperKitTranscriber.engineFactoryForTesting = { await probe.make($0) }
        LazyWhisperKitTranscriber.onEngineBuildAccessForTesting = {
            probe.recordBuildAccess(variant: $0, access: $1)
        }
        let (coordinator, _, capture) = try makeCoordinator(transcriber: LazyWhisperKitTranscriber())

        let background = Task { await coordinator.prepareTranscriberInBackground() }
        await probe.waitForBuildAccess(.started, variant: "tiny.en")
        let start = Task { try await coordinator.start() }
        await probe.waitForBuildAccess(.joined, variant: "tiny.en")

        XCTAssertEqual(probe.calls, ["tiny.en"],
                       "background and Start are both waiting on one in-flight build")
        XCTAssertEqual(capture.starts, 0, "capture cannot start before the joined build is released")
        probe.release("tiny.en")

        await background.value
        _ = try await start.value
        XCTAssertEqual(probe.calls, ["tiny.en"])
        XCTAssertEqual(capture.starts, 1)
        await coordinator.stop()
    }

    func testPreauthorizedBackgroundCannotChangeStartsBoundVariant() async throws {
        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let probe = EngineFactoryProbe()
        probe.suspend("tiny.en")
        LazyWhisperKitTranscriber.engineFactoryForTesting = { await probe.make($0) }
        let transcriber = LazyWhisperKitTranscriber()
        let capture = PreparationCaptureEngine()
        capture.emitsSpeechOnStart = true
        let (coordinator, store, _) = try makeCoordinator(transcriber: transcriber, capture: capture)

        // Coordinator admits background A while idle; it remains suspended
        // after Start synchronously reserves `.preparing` and binds B.
        let background = Task { await coordinator.prepareTranscriberInBackground() }
        await probe.waitForCall("tiny.en")
        UserDefaults.standard.set("base.en", forKey: SettingsKeys.whisperModel)
        let session = try await coordinator.start()

        // Let stale background A finish after B's session is recording.
        probe.release("tiny.en")
        await background.value
        await coordinator.stop()

        XCTAssertEqual(try store.segments(sessionId: session.id).map(\.text), ["base.en"])
        XCTAssertEqual(probe.consumedVariants, ["base.en"],
                       "a stale background engine must never be consumed by Start")
    }

    func testSelectedModelChangesOnlyAtNextSessionAndWarmEngineIsReused() async throws {
        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let probe = EngineFactoryProbe()
        LazyWhisperKitTranscriber.engineFactoryForTesting = { await probe.make($0) }
        let (coordinator, _, _) = try makeCoordinator(transcriber: LazyWhisperKitTranscriber())

        _ = try await coordinator.start()
        UserDefaults.standard.set("base.en", forKey: SettingsKeys.whisperModel)
        await coordinator.prepareTranscriberInBackground()
        XCTAssertEqual(probe.calls, ["tiny.en"], "an active session retains its prepared engine")
        await coordinator.stop()

        _ = try await coordinator.start()
        XCTAssertEqual(probe.calls, ["tiny.en", "base.en"])
        await coordinator.stop()

        _ = try await coordinator.start()
        XCTAssertEqual(probe.calls, ["tiny.en", "base.en"], "the prepared model is warm-reused")
        await coordinator.stop()
    }

    func testUnavailableModelFailsActionablyWithoutCaptureOrRow() async throws {
        UserDefaults.standard.set("tiny.en", forKey: SettingsKeys.whisperModel)
        let probe = EngineFactoryProbe()
        probe.resultAvailable = false
        LazyWhisperKitTranscriber.engineFactoryForTesting = { await probe.make($0) }
        let (coordinator, store, capture) = try makeCoordinator(transcriber: LazyWhisperKitTranscriber())

        do {
            _ = try await coordinator.start()
            XCTFail("Start must not capture without a ready model")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Settings → Whisper Model"))
        }
        XCTAssertEqual(capture.starts, 0)
        XCTAssertTrue(try store.allSessions().isEmpty)
        XCTAssertEqual(coordinator.displayState, .idle)
    }
}
