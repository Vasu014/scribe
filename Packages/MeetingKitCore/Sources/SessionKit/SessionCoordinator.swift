import CaptureKit
import Foundation
import FusionKit
import Persistence
import ScratchpadKit
import TranscribeKit

// MARK: - Vocabulary

/// Kind strings for `DeviceEvent` (SPEC §4.1/§4.4) as logged by the
/// coordinator. Raw values match the vocabulary in `Persistence.DeviceEvent`
/// docs so CaptureKit (T4) and SessionKit write the same timeline.
public enum DeviceEventKind {
    /// Audio device changed (route change / engine rebuild) — SPEC §4.1.
    public static let deviceChanged = "deviceChanged"
    /// System went to sleep mid-session — SPEC §4.4.
    public static let sleep = "sleep"
    /// System woke mid-session — SPEC §4.4.
    public static let wake = "wake"
}

/// Fusion execution seam: turns a session row into a terminal
/// `FusionRunOutcome`. Chosen as a CLOSURE (not a protocol) because there is
/// exactly one production implementation — `FusionService.fuse` wrapped with
/// its provider and lookback — and a protocol would add a type plus
/// conformance ceremony for no second implementation. The closure also lets
/// the App own provider/Keychain configuration (where it belongs) and lets
/// tests inject flip-flop mocks. See `SessionCoordinator.defaultFusionRunner`.
public typealias FusionRunner = @Sendable (SessionRecord) async -> FusionRunOutcome

/// What the coordinator announces to observers (menu bar, History). Emitted
/// through `SessionCoordinator.events()`; state transitions carry the
/// DERIVED UI state (SPEC §5) — storage states stay on the session rows.
public enum CoordinatorEvent: Equatable, Sendable {
    /// A derived display-state transition (SPEC §5) — e.g. `.recording` at
    /// start, `.processing` while fusion runs, `.done`/`.failed` at the end.
    case stateChanged(SessionDisplayState)
    /// Crash recovery (SPEC §4.4): sessions found stuck in `recording` at
    /// init, now marked `recovered` + moved to `processing` (fusion offer —
    /// NO auto-fusion; the user triggers it via retry). Emitted during init,
    /// so it is buffered for the first subscriber (see `events()`).
    case recoveredSessions([SessionRecord])
    /// A device-interruption event was appended to `sessions.deviceEvents`.
    case deviceEventLogged(DeviceEvent)
    /// Fusion stored a note but the validator flagged citations (SPEC §4.5):
    /// the session stays in `processing` (Retry available); findings feed the
    /// inline warning cards and the eval set.
    case fusionFindings(sessionId: UUID, findings: [NotesValidator.Finding])
    /// Fusion failed (SPEC §4.5): session stays in `processing` with Retry;
    /// the message is for the Retry UI.
    case fusionFailed(sessionId: UUID, message: String)
}

/// Errors thrown by `SessionCoordinator.start()`.
public enum SessionCoordinatorError: Error, Equatable {
    case alreadyRecording
}

// MARK: - Coordinator

/// Session lifecycle + crash safety (SPEC §4.4) — the composition root.
///
/// ORCHESTRATION ONLY (SPEC §3.1 architectural rule, load-bearing): the
/// coordinator wires capture → transcription → store and drives fusion at
/// session end, but DATA STILL FLOWS THROUGH THE STORE. Segments, fragments,
/// notes, device events and session state all live in `Persistence`; nothing
/// is routed between the other modules directly beyond the injected engines.
///
/// Lifecycle (SPEC §4.4): `idle → recording → processing → complete`
/// (+ `recovered` flag). Storage states only — the UI derives its states
/// (SPEC §5) from `CoordinatorEvent.stateChanged`.
public final class SessionCoordinator: @unchecked Sendable {

    /// Lookback for effective fragment anchors (SPEC §4.3 user setting,
    /// default 20 s). The injected `fusionRunner` is expected to honor it;
    /// `defaultFusionRunner(store:provider:lookback:)` does.
    public let lookback: TimeInterval

    private let store: MeetingStore
    private let engine: any CaptureEngine
    private let transcriber: any Transcriber
    private let fusionRunner: FusionRunner
    private let eventBus = EventBus<CoordinatorEvent>()

    /// Optional relay fired from `handleDeviceChange()` after the
    /// `deviceChanged` event is logged. Rationale: pause/rebuild/resume of
    /// the audio graph is the ENGINE's job (SPEC §4.1) — the real engine
    /// (CaptureKit, T4) rebuilds itself on its own route-change
    /// notifications, and `CaptureEngine` deliberately has no rebuild method
    /// today. This closure is the "notify engine" seam until T4 wires its
    /// own handling; set it once at app wiring time.
    public var onRelayDeviceChange: (@Sendable () -> Void)?

    // Mutable state, guarded by `lock`.
    private let lock = NSLock()
    private enum Phase: Equatable { case idle, recording, stopping, processing }
    private var phase: Phase = .idle
    private var displayStateStorage: SessionDisplayState = .idle
    private var currentSessionStorage: SessionRecord?
    private var clockStorage: SessionClock?
    private var pipelineStorage: TranscriptPipeline?
    private var composerStorage: FragmentComposer?
    private var pendingFragmentId: UUID?
    private var pendingFragmentAnchor: TimeInterval?
    private var lastFusionErrorStorage: String?

    /// - Parameters:
    ///   - store: the single store every component reads/writes (SPEC §3.1).
    ///   - captureEngine: capture seam (stub until Spike 1 / T4).
    ///   - transcriber: transcription seam (stub until Spike 2 / T3).
    ///   - lookback: fragment effective-anchor lookback (SPEC §4.3, default 20 s).
    ///   - fusionRunner: end-of-session fusion executor; see `FusionRunner`
    ///     for why this is a closure. Use `defaultFusionRunner` in the App.
    ///
    /// Crash recovery (SPEC §4.4) runs HERE: sessions stuck in `recording`
    /// are marked `recovered = true`, moved to `processing` (fusion offer on
    /// whatever persisted), and surfaced via `.recoveredSessions`. No
    /// auto-fusion. `endedAt` is deliberately left `nil` — we don't know
    /// when the crash happened, and an invented wall-clock end would lie in
    /// History's duration math.
    public init(
        store: MeetingStore,
        captureEngine: any CaptureEngine,
        transcriber: any Transcriber,
        lookback: TimeInterval = 20,
        fusionRunner: @escaping FusionRunner
    ) {
        self.store = store
        self.engine = captureEngine
        self.transcriber = transcriber
        self.lookback = lookback
        self.fusionRunner = fusionRunner

        // Crash-recovery scan (SPEC §4.4). Best-effort: a store failure here
        // must not take the app down; the sessions stay in `recording` and
        // are picked up on the next launch.
        if let stuck = try? store.sessionsInState(.recording) {
            var recovered: [SessionRecord] = []
            for var session in stuck {
                session.recovered = true
                session.state = .processing
                if (try? store.updateSession(session)) != nil {
                    recovered.append(session)
                }
            }
            if !recovered.isEmpty {
                eventBus.emit(.recoveredSessions(recovered))
            }
        }
    }

    /// Runs `body` under `lock`. Synchronous by design — no call site ever
    /// awaits while holding the lock (store writes happen after release), and
    /// routing the raw `lock()`/`unlock()` through this helper keeps the
    /// async-context availability diagnostics quiet.
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Observation

    /// A fresh `AsyncStream` of coordinator events; call once per observer
    /// (menu bar, History, tests). The bus is a multicast: all subscribers
    /// see every event.
    ///
    /// Events emitted BEFORE the first subscriber ever attached — in
    /// practice the init-time `.recoveredSessions` — are buffered and
    /// replayed to that first subscriber, so subscribing right after init
    /// still sees the recovery offer. Events emitted after all subscribers
    /// have terminated are dropped (the store remains the source of truth).
    public func events() -> AsyncStream<CoordinatorEvent> {
        eventBus.subscribe()
    }

    /// Current DERIVED display state (SPEC §5). Storage state lives on the
    /// session row; this is the coordinator's projection for the menu bar.
    public var displayState: SessionDisplayState {
        withLock { displayStateStorage }
    }

    /// The session the coordinator is currently driving (recording, or the
    /// most recently stopped one — the retry target). `nil` before the first
    /// start; replaced by the next `start()`.
    public var currentSession: SessionRecord? {
        withLock { currentSessionStorage }
    }

    /// Last fusion failure message (drives the persistent ⚠ derived state,
    /// SPEC §5); `nil` when no failure is outstanding.
    public var lastFusionError: String? {
        withLock { lastFusionErrorStorage }
    }

    // MARK: Lifecycle

    /// Starts a session: creates the session row (wall-clock `startedAt`
    /// stored once, SPEC §4.1), starts the session clock, wires capture →
    /// per-channel transcription → immediate segment upserts
    /// (see `TranscriptPipeline`), then starts the capture engine.
    ///
    /// If the engine fails to start, the empty session row is deleted so the
    /// next launch's recovery scan doesn't offer fusion on a zero-transcript
    /// session, and the error is rethrown.
    @discardableResult
    public func start() async throws -> SessionRecord {
        try withLock {
            guard phase == .idle || phase == .processing else {
                throw SessionCoordinatorError.alreadyRecording
            }
        }

        // Session row first: a crash between here and engine start leaves an
        // empty `recording` row — acceptable, and recovery handles it.
        let session = try store.createSession()
        let clock = SessionClock()
        let pipeline = TranscriptPipeline(store: store, sessionId: session.id, transcriber: transcriber)

        withLock {
            clockStorage = clock
            pipelineStorage = pipeline
            currentSessionStorage = session
            phase = .recording
        }

        engine.onAudio = { [weak self] sample in
            self?.feedAudio(sample)
        }
        do {
            try await engine.start()
        } catch {
            engine.onAudio = nil
            await engine.stop()
            await pipeline.finish()
            withLock {
                phase = .idle
                currentSessionStorage = nil
                pipelineStorage = nil
                clockStorage = nil
            }
            try? store.deleteSession(id: session.id)
            throw error
        }
        setDisplay(.recording)
        return session
    }

    /// Stops the session and runs fusion (SPEC §4.4: stop finalizes pending
    /// segments → `processing` → fusion). Order:
    ///
    /// 1. Flush the pending fragment (composer, if attached — SPEC §4.3
    ///    pending-row: a crash loses at most ~1 s of typing, a stop loses
    ///    nothing).
    /// 2. Stop the capture engine, then drain the transcript pipeline so
    ///    every hypothesis already emitted is in SQLite.
    /// 3. Finalize pending segments: DECISION — non-final hypotheses are
    ///    marked `isFinal = true`. The meeting is over; they will never be
    ///    revised, and History/export should read settled rows. (Leaving
    ///    them non-final would also be defensible; the flag exists so later
    ///    phases can distinguish live revisions, and post-stop there are
    ///    none.)
    /// 4. Wall-clock `endedAt` + state `.processing`, then fusion via the
    ///    injected runner. Outcome (SPEC §4.5): success → `.complete` +
    ///    `.done`; validator findings → stays `.processing`, findings
    ///    surfaced; failure → stays `.processing`, error surfaced for Retry.
    ///
    /// Idempotent: extra calls while not recording are no-ops; a second
    /// call while a stop is already in flight returns immediately (it does
    /// not wait for the first one's fusion).
    public func stop() async {
        let held: (session: SessionRecord, clock: SessionClock, composer: FragmentComposer?, pipeline: TranscriptPipeline?)? = withLock {
            guard phase == .recording,
                  let session = currentSessionStorage,
                  let clock = clockStorage else { return nil }
            phase = .stopping
            return (session, clock, composerStorage, pipelineStorage)
        }
        guard let held else { return }
        let session = held.session

        // 1. Flush the pending fragment while the clock is still queryable.
        held.composer?.flush(at: held.clock.nowOffset())

        // 2. Stop producing audio, then drain transcription into the store.
        engine.onAudio = nil
        await engine.stop()
        if let pipeline = held.pipeline {
            await pipeline.finish()
            withLock { pipelineStorage = nil }
        }

        // 3. Finalize non-final hypotheses (decision documented above).
        finalizeNonFinalSegments(sessionId: session.id)

        // 4. `processing` + wall-clock end, then fusion.
        var row = (try? store.session(id: session.id)) ?? session
        row.endedAt = Date()
        row.state = .processing
        try? store.updateSession(row)

        withLock {
            phase = .processing
            currentSessionStorage = row
        }
        setDisplay(.processing)

        let outcome = await fusionRunner(row)
        apply(outcome, to: row, drivesDisplay: true)
    }

    /// Re-runs fusion for a session stuck in `processing` after a failure
    /// (SPEC §4.5 "Retry"), including crash-recovered sessions (SPEC §4.4
    /// fusion offer — the user initiates it, e.g. from History).
    ///
    /// - Parameter session: the row to retry; `nil` (default) retries the
    ///   coordinator's current session. Only rows currently in `processing`
    ///   in the store are retried; anything else is a no-op. Display-state
    ///   events are emitted only when the retried session is the current
    ///   one — otherwise the History surface reads the store directly.
    public func retryFusion(for session: SessionRecord? = nil) async {
        let resolved: (target: SessionRecord, drivesDisplay: Bool)? = withLock {
            guard phase != .recording, phase != .stopping else { return nil }
            guard let target = session ?? currentSessionStorage else { return nil }
            return (target, target.id == currentSessionStorage?.id)
        }
        guard let resolved,
              let row = try? store.session(id: resolved.target.id),
              row.state == .processing else { return }

        if resolved.drivesDisplay {
            setDisplay(.processing) // leave the ⚠ state while retrying
        }
        let outcome = await fusionRunner(row)
        apply(outcome, to: row, drivesDisplay: resolved.drivesDisplay)
    }

    // MARK: Interruptions (SPEC §4.1/§4.4)

    /// Logs a `deviceChanged` event on the session timeline and fires the
    /// engine relay. Pause/rebuild/resume of the audio graph is the engine's
    /// job (SPEC §4.1); the coordinator logs and relays — see
    /// `onRelayDeviceChange`. Only meaningful while recording; otherwise a
    /// no-op.
    public func handleDeviceChange() {
        logDeviceEvent(kind: DeviceEventKind.deviceChanged, relay: true)
    }

    /// Logs a `sleep` event. The session clock KEEPS RUNNING through sleep
    /// (SPEC §4.1/§4.4) — offsets carry honest gaps, explained by this event.
    /// No-op while not recording.
    public func handleSleep() {
        logDeviceEvent(kind: DeviceEventKind.sleep)
    }

    /// Logs a `wake` event. No-op while not recording.
    public func handleWake() {
        logDeviceEvent(kind: DeviceEventKind.wake)
    }

    // MARK: Scratchpad wiring

    /// Attaches the scratchpad's fragment composer and wires its
    /// persist/freeze callbacks to the store for the CURRENT session — the
    /// pending-row pattern (SPEC §4.3) needs a stable row id per burst, which
    /// this owns: the same id is re-upserted on every debounce persist until
    /// the burst freezes. The panel (T6) drives `edit`/`newline`/`heartbeat`
    /// with `nowOffset()` values. Attach once at app wiring time; fragments
    /// arriving while no session is recording are dropped (the no-meeting
    /// state discards typing, SPEC §5 scratchpad header).
    public func attach(_ composer: FragmentComposer) {
        withLock { composerStorage = composer }
        composer.onPersistPending = { [weak self] text, anchor in
            self?.persistPendingFragment(text: text, anchor: anchor)
        }
        composer.onFreeze = { [weak self] text, anchor in
            self?.freezeFragment(text: text, anchor: anchor)
        }
    }

    // MARK: Clocks (two clocks, two jobs — SPEC §4.1)

    /// Session-clock offset (audio timeline) — for scratchpad anchors and
    /// anything aligned with segment offsets. `0` while not recording.
    public func nowOffset() -> TimeInterval {
        withLock {
            guard phase == .recording || phase == .stopping, let clock = clockStorage else { return 0 }
            return clock.nowOffset()
        }
    }

    /// WALL-CLOCK elapsed for the menu-bar timer (SPEC §4.1: elapsed
    /// displays derive from wall clock, never the session clock). Valid
    /// while recording; `0` otherwise. Durations in History are
    /// `endedAt − startedAt` on the same basis.
    public func elapsed() -> TimeInterval {
        withLock {
            guard phase == .recording, let session = currentSessionStorage else { return 0 }
            return Date().timeIntervalSince(session.startedAt)
        }
    }

    // MARK: Default fusion wiring

    /// The production `FusionRunner`: `FusionService.fuse` (which never
    /// throws, SPEC §4.5) bound to its provider and lookback. The App builds
    /// this where Keychain/config live, and hands it to the coordinator.
    public static func defaultFusionRunner(
        store: MeetingStore,
        provider: any FusionProvider,
        lookback: TimeInterval
    ) -> FusionRunner {
        let service = FusionService(store: store)
        return { session in
            await service.fuse(session: session, lookback: lookback, provider: provider)
        }
    }

    // MARK: Internals

    /// Capture callback (engine's queue; non-blocking — routes into the
    /// pipeline's streams). Only fed while recording; after `finish()` the
    /// pipeline drops everything.
    private func feedAudio(_ sample: CapturedSample) {
        let pipeline = withLock {
            phase == .recording ? pipelineStorage : nil
        }
        pipeline?.feed(sample)
    }

    /// Sets the derived display state and announces the transition (SPEC §5).
    /// The transient semantics of `.done` (4 s, clickable) and the clearing
    /// of `.failed` are owned by the menu bar; the coordinator only reports
    /// storage-driven transitions.
    private func setDisplay(_ state: SessionDisplayState) {
        withLock { displayStateStorage = state }
        eventBus.emit(.stateChanged(state))
    }

    private func logDeviceEvent(kind: String, relay: Bool = false) {
        let held: (session: SessionRecord, offset: TimeInterval, onRelay: (@Sendable () -> Void)?)? = withLock {
            guard phase == .recording,
                  let session = currentSessionStorage,
                  let clock = clockStorage else { return nil }
            return (session, clock.nowOffset(), relay ? onRelayDeviceChange : nil)
        }
        guard let held else { return }

        // Session-clock offset (audio timeline) so the event lines up with
        // the segment timeline it explains (SPEC §4.1 pause/clock semantics).
        let event = DeviceEvent(kind: kind, offset: held.offset)
        try? store.appendDeviceEvent(sessionId: held.session.id, event: event)
        eventBus.emit(.deviceEventLogged(event))
        held.onRelay?()
    }

    /// Pending-row upsert (SPEC §4.3): stable id per burst — a NEW id only
    /// when the burst anchor changes — re-saved on every debounce persist.
    private func persistPendingFragment(text: String, anchor: TimeInterval) {
        let target: (sessionId: UUID, fragmentId: UUID)? = withLock {
            guard let session = currentSessionStorage, phase == .recording else { return nil }
            if pendingFragmentId == nil || pendingFragmentAnchor != anchor {
                pendingFragmentId = UUID()
                pendingFragmentAnchor = anchor
            }
            guard let id = pendingFragmentId else { return nil }
            return (session.id, id)
        }
        guard let target else { return }
        try? store.upsertFragment(FragmentRecord(
            id: target.fragmentId, sessionId: target.sessionId, text: text, anchorOffset: anchor
        ))
    }

    /// Burst frozen (SPEC §4.3): final upsert of the row on the same stable
    /// id, then the id is released for the next burst.
    private func freezeFragment(text: String, anchor: TimeInterval) {
        let target: (sessionId: UUID, fragmentId: UUID)? = withLock {
            guard let session = currentSessionStorage else { return nil }
            if pendingFragmentId == nil || pendingFragmentAnchor != anchor {
                pendingFragmentId = UUID()
            }
            guard let id = pendingFragmentId else { return nil }
            pendingFragmentId = nil
            pendingFragmentAnchor = nil
            return (session.id, id)
        }
        guard let target else { return }
        try? store.upsertFragment(FragmentRecord(
            id: target.fragmentId, sessionId: target.sessionId, text: text, anchorOffset: anchor
        ))
    }

    /// Marks every non-final segment of the session final (decision
    /// documented on `stop()`).
    private func finalizeNonFinalSegments(sessionId: UUID) {
        guard let segments = try? store.segments(sessionId: sessionId) else { return }
        for var segment in segments where !segment.isFinal {
            segment.isFinal = true
            try? store.upsertSegment(segment)
        }
    }

    /// Applies a fusion outcome to the session (SPEC §4.5 failure
    /// semantics). Re-reads the row first: the runner may be the real
    /// `FusionService`, which already stored the note, title, and state —
    /// these updates are idempotent and cover mock runners that touch
    /// nothing. The coordinator owns the lifecycle transitions regardless of
    /// who wrote them first. Menu-bar display state moves only when
    /// `drivesDisplay` (the session is the coordinator's current one);
    /// session-scoped events (findings, failure) are emitted regardless so
    /// History surfaces them.
    private func apply(_ outcome: FusionRunOutcome, to session: SessionRecord, drivesDisplay: Bool) {
        let fresh = (try? store.session(id: session.id)) ?? session
        switch outcome {
        case let .success(_, title):
            var row = fresh
            row.state = .complete
            if row.title == nil { row.title = title }
            try? store.updateSession(row)
            if drivesDisplay {
                withLock { lastFusionErrorStorage = nil }
                setDisplay(.done(sessionId: session.id))
            }

        case let .storedWithFindings(_, title, findings):
            var row = fresh
            row.state = .processing // Retry stays available (SPEC §4.5)
            if row.title == nil { row.title = title }
            try? store.updateSession(row)
            if drivesDisplay {
                withLock { lastFusionErrorStorage = nil }
                setDisplay(.processing)
            }
            eventBus.emit(.fusionFindings(sessionId: session.id, findings: findings))

        case let .failure(error):
            let message = Self.describe(error)
            if drivesDisplay {
                withLock { lastFusionErrorStorage = message }
                setDisplay(.failed(sessionId: session.id))
            }
            eventBus.emit(.fusionFailed(sessionId: session.id, message: message))
        }
    }

    private static func describe(_ error: FusionServiceError) -> String {
        switch error {
        case .provider(let message): return message
        case .emptyTranscript:
            return "No transcript segments were persisted for this session."
        case .store(let message): return message
        }
    }
}

// MARK: - Event bus (multicast AsyncStream)

/// Minimal multicast for `AsyncStream` (single-consumer by default).
/// All current subscribers receive every event. Events emitted before ANY
/// subscriber ever attached are buffered and replayed to that first
/// subscriber — that is what makes the init-time crash-recovery event
/// observable after `init` returns. Once a subscriber has existed, events
/// with zero live subscribers are dropped (the store stays the source of
/// truth; the bus is a projection, not a queue).
private final class EventBus<Event: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var backlog: [Event] = []
    private var hasSubscribed = false

    func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        // AsyncStream's build closure runs synchronously inside init, so the
        // continuation is registered before subscribe() returns — an emit
        // after that point is buffered by the stream itself and cannot be
        // missed by a later iteration.
        return AsyncStream(bufferingPolicy: .unbounded) { [weak self] continuation in
            guard let self else { return }
            let replay = self.register(id: id, continuation: continuation)
            for event in replay {
                continuation.yield(event)
            }
        }
    }

    private func register(
        id: UUID, continuation: AsyncStream<Event>.Continuation
    ) -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        guard !hasSubscribed else { return [] }
        hasSubscribed = true
        let replay = backlog
        backlog = []
        return replay
    }

    private func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        subscribers[id] = nil
    }

    func emit(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        guard hasSubscribed, !subscribers.isEmpty else {
            if !hasSubscribed {
                backlog.append(event)
            }
            return
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}
