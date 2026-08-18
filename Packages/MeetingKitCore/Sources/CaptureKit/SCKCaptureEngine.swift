import AVFAudio
import CoreAudio
import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import Persistence
import ScreenCaptureKit

// MARK: - Start order (SPEC §4.1 / §7 Spike 1)

/// Which capture backend is activated first at session begin. SPEC §7 Spike 1
/// exists because activating SCK audio capture while an AVAudioEngine input
/// tap runs can silently kill the mic stream (or vice versa) on macOS 14.x.
public enum RemoteStartOrder: String, Sendable {
    case screenCaptureKitFirst
    case audioEngineFirst
}

// MARK: - Errors

/// Unrecoverable engine failures (SPEC §4.1: only *permission loss* throws
/// out of `start()`; every remote-side failure degrades to mic-only instead).
public enum CaptureEngineError: LocalizedError, Sendable {
    /// Mic TCC denied (or the user answered the prompt with Deny).
    case microphonePermissionDenied
    /// The AVAudioEngine input graph could not be built/started (no input
    /// device, HAL failure). The engine tears down any started remote stream
    /// before throwing.
    case microphoneStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied (macOS Settings → Privacy → Microphone)"
        case .microphoneStartFailed(let detail):
            return "Audio input engine failed to start: \(detail)"
        }
    }
}

/// Why the system-audio (remote) stream degraded to mic-only. Surfaced as a
/// human-readable string via `SCKCaptureEngine.onRemoteDegraded` (the
/// coordinator logs it into `device_events`, SPEC §4.1 failure modes).
public enum RemoteDegradationReason: String, Sendable {
    /// Screen Recording TCC missing/revoked at start, or revoked mid-session
    /// (revocation surfaces as an SCStream error → same ladder).
    case screenPermissionNotGranted
    /// No display to capture (headless / exotic setup).
    case noDisplayFound
    /// SCStream failed twice (start failure or unexpected stop).
    case remoteStreamFailed
}

// MARK: - Session clock

/// Session clock (SPEC §4.1, pinned): `mach_continuous_time`-based, epoch at
/// session begin. `mach_continuous_time` is chosen deliberately — it advances
/// across system sleep, matching the stated model "the clock keeps running,
/// gaps are honest". Device switches and sleep/wake never pause it.
///
/// EPOCH CONVENTION (shared with `SessionKit.SessionClock`, reimplemented
/// here ON PURPOSE): CaptureKit must not depend on SessionKit (SPEC §3.1
/// store-mediated rule + T4 task constraint), so the clock is duplicated
/// locally. Both implementations use the same basis and the same convention —
/// offset 0 = session begin = the coordinator's `engine.start()` — so audio
/// offsets, fragment anchors and device-event offsets are comparable.
/// Value type: copies carry the same origin ticks; handing one out never
/// restarts the timeline.
struct MachSessionClock: Sendable {
    private let startTicks: UInt64
    /// Seconds per tick: `mach_timebase_info` gives NANOseconds per tick
    /// (numer/denom — e.g. 125/3 on Apple Silicon), hence the 1e9 divisor.
    private let secondsPerTick: Double

    /// Starts the clock NOW (call at session begin).
    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / (Double(info.denom) * 1_000_000_000)
        startTicks = mach_continuous_time()
    }

    /// Seconds elapsed since `init()` on the continuous monotonic clock.
    func nowOffset() -> TimeInterval {
        Double(mach_continuous_time() - startTicks) * secondsPerTick
    }
}

// MARK: - Engine

/// The real capture engine (T4; SPEC §4.1): ScreenCaptureKit system audio
/// (`remote`) + AVAudioEngine mic (`local`), downsampled to 16 kHz mono
/// Float32 `CapturedSample`s on a shared session clock.
///
/// ## Threading model
/// - `stateQueue` (serial): owns all mutable lifecycle state — the SCStream,
///   AVAudioEngine, observers, restart counter, degradation flags. All
///   mutations hop through it; public reads (`remoteStreamActive`) sync on it.
/// - `processingQueue` (serial): all PCM conversion and `onAudio` delivery
///   for BOTH channels — serial, so cross-channel sample ordering is
///   deterministic for downstream consumers.
/// - Real-time surfaces (AVAudioEngine tap thread, SCStream sample queue):
///   do exactly two things — read the (lock-free, value-copied) session clock
///   and dispatch the immutable buffer to `processingQueue`. No locks, no
///   conversion on RT threads, per the `CaptureEngine.onAudio` contract
///   ("handlers must not block" — we also guarantee the *engine side* never
///   blocks the audio HAL: conversion is cheap-but-allocating, so it lives on
///   the utility queue, not the tap).
///
/// ## Session stamping
/// Both channels stamp `sessionOffset` at ARRIVAL on the engine (clock read
/// in the callback, before the queue hop, so hop delay never skews offsets).
/// The sub-buffer-latency error this introduces is consistent across channels
/// and irrelevant at Whisper-chunk granularity.
public final class SCKCaptureEngine: NSObject, CaptureEngine, @unchecked Sendable {

    // MARK: Start order — SPEC §4.1/§7 Spike 1 outcome

    /// Spec-pinned default start order (SPEC §4.1: "determined by the §7
    /// spike (default hypothesis: SCStream first, then engine)") — the
    /// default value of `Configuration.startOrder`, the knob the Spike-1
    /// matrix varies (harness: `Tools/SpikeHarness`, runner:
    /// `scripts/spike1-run.sh`, `docs/spikes/spike1.md`).
    ///
    /// Current value = the default hypothesis. The Spike-1 matrix —
    /// {SCStream first, engine first} × {VP on, off} × {machine 1, 2},
    /// 8 runs — validates or flips this. When the results land, record the
    /// tested macOS build numbers here and update the constant if the
    /// matrix disagrees.
    ///
    /// Tested macOS builds: **pending Spike 1 (T10 hardware runs)**.
    public static let defaultStartOrder: RemoteStartOrder = .screenCaptureKitFirst

    // MARK: Configuration

    /// Engine tuning. `voiceProcessingEnabled` is the SPEC §4.1 mic knob —
    /// echo cancellation ON by default, **subject to the Spike-1 outcome**
    /// (SPEC §4.1: "if voice processing destabilizes coexistence with SCStream
    /// on either machine, fall back to voice processing off and accept partial
    /// bleed"). See `docs/spikes/spike1.md`.
    public struct Configuration: Sendable {
        public var voiceProcessingEnabled: Bool

        /// Which capture backend activates first at session begin — the
        /// Spike-1 matrix knob (SPEC §4.1/§7). Defaults to the spec-pinned
        /// `SCKCaptureEngine.defaultStartOrder`; the harness overrides it
        /// per matrix cell. Whatever the matrix decides, the winner gets
        /// pinned back into `defaultStartOrder`.
        public var startOrder: RemoteStartOrder

        public init(voiceProcessingEnabled: Bool = true,
                    startOrder: RemoteStartOrder = SCKCaptureEngine.defaultStartOrder) {
            self.voiceProcessingEnabled = voiceProcessingEnabled
            self.startOrder = startOrder
        }
    }

    // MARK: Callbacks (set before start(); invoked on internal queues)

    /// Audio callback — `CaptureEngine` protocol contract: called on the
    /// engine's serial processing queue; handlers must not block.
    public var onAudio: ((CapturedSample) -> Void)?

    /// Fired when the input device graph was rebuilt around a device change
    /// (route change / config change; SPEC §4.1 device switching). The
    /// coordinator wires this to its `onRelayDeviceChange` seam (T2), which
    /// logs a `deviceChanged` event. Called on an internal queue.
    public var onDeviceChange: (() -> Void)?

    /// Fired exactly once per session when the remote (system audio) stream
    /// degrades to mic-only (permission missing/revoked, or SCStream failed
    /// twice — SPEC §4.1 failure modes). The string is a human-readable
    /// reason suitable for the `device_events` log. Called on an internal
    /// queue.
    public var onRemoteDegraded: ((String) -> Void)?

    // MARK: State (stateQueue-confined unless noted)

    private let config: Configuration

    /// Lifecycle + graph ownership. Never blocked-on from RT surfaces.
    private let stateQueue = DispatchQueue(label: "scribe.capture.state")
    /// All PCM conversion + `onAudio` delivery (both channels; serial).
    /// Fileprivate: `RemoteAudioRelay` hops onto it from SCK's sample queue.
    fileprivate let processingQueue = DispatchQueue(label: "scribe.capture.pcm")
    /// Delivery queue handed to ScreenCaptureKit for audio sample buffers.
    private let remoteSampleQueue = DispatchQueue(label: "scribe.capture.sck-audio")

    private var running = false
    private var audioEngine: AVAudioEngine?
    private var scStream: SCStream?
    private var remoteSink: RemoteAudioRelay?
    private var observers: [NSObjectProtocol] = []
    /// Set during intentional teardown so `didStopWithError` doesn't trigger
    /// the restart ladder.
    private var expectingTeardown = false
    /// SPEC §4.1: "SCStream error/stall → ONE silent restart; on second
    /// failure, continue mic-only." Counts restarts used this session.
    private var remoteRestartsUsed = 0
    private var remoteActive = false
    private var remoteDegradationAnnounced = false

    /// Session clock, written once at `start()` (before any callback source
    /// exists) and read-only afterwards; value-copied into callbacks.
    private var sessionClock = MachSessionClock()

    /// Monotonic per-start generation. Bumped on every start/stop so stale
    /// in-flight callbacks from a previous/teardown session get dropped.
    /// Guarded by its own tiny lock: written at start/stop, read on
    /// `processingQueue` (never from RT surfaces).
    private var generation = 0
    private let generationLock = NSLock()

    /// Per-channel 16 kHz downsamplers — processingQueue-confined only.
    private var downsamplers: [Channel: PCMDownsampler] = [:]

    // MARK: Init

    public init(config: Configuration = Configuration()) {
        self.config = config
        super.init()
    }

    // MARK: - CaptureEngine

    /// True when the system-audio stream is live; false once degraded to
    /// mic-only (SPEC §4.1 degradation paths).
    public var remoteStreamActive: Bool {
        stateQueue.sync { remoteActive }
    }

    public func start() async throws {
        // Permissions first (SPEC §4.1): mic denied is the only FATAL
        // permission at start; screen-recording issues degrade to mic-only.
        if CapturePermissions.microphone == .undetermined {
            _ = await CapturePermissions.requestMicrophone()
        }
        guard CapturePermissions.microphone == .granted else {
            throw CaptureEngineError.microphonePermissionDenied
        }

        let generation = bumpGeneration()
        let clock = MachSessionClock() // epoch = session begin (SPEC §4.1)

        var screenGranted = CapturePermissions.screenRecording == .granted
        if !screenGranted {
            // Surface the TCC prompt so the NEXT session can capture (grant
            // requires relaunch — SPEC §4.1 first-run flow). This session
            // degrades: a stream restart cannot fix TCC, so no restart is
            // spent on the permission-missing case (restarts are for SCStream
            // runtime failures, where they can actually help).
            screenGranted = CapturePermissions.requestScreenRecording()
        }

        await onStateQueue {
            self.sessionClock = clock
            self.running = true
            self.expectingTeardown = false
            self.remoteRestartsUsed = 0
            self.remoteActive = false
            self.remoteDegradationAnnounced = false
            self.registerObserversLocked()
        }

        // Start order per `config.startOrder` (Spike 1 knob; see
        // `defaultStartOrder` doc comment).
        do {
            switch config.startOrder {
            case .screenCaptureKitFirst:
                if screenGranted {
                    await startRemoteStream(generation: generation, clock: clock)
                } else {
                    await degradeRemote(reason: .screenPermissionNotGranted)
                }
                try await startMic(generation: generation, clock: clock)
            case .audioEngineFirst:
                try await startMic(generation: generation, clock: clock)
                if screenGranted {
                    await startRemoteStream(generation: generation, clock: clock)
                } else {
                    await degradeRemote(reason: .screenPermissionNotGranted)
                }
            }
        } catch {
            // Never leave a half-started engine behind.
            await stop()
            throw error
        }
    }

    public func stop() async {
        let hadAnything: Bool = await onStateQueue {
            let had = self.running || self.audioEngine != nil || self.scStream != nil
            self.running = false
            self.expectingTeardown = true
            self.removeObserversLocked()
            self.stopMicLocked()
            return had
        }
        guard hadAnything else { return } // safe when stopped (protocol doc)
        _ = bumpGeneration() // drop in-flight callbacks from the stopped session
        await teardownRemote()
        await onStateQueue { self.expectingTeardown = false }
    }

    // MARK: - Mic (AVAudioEngine, SPEC §4.1)

    /// Builds (or rebuilds) the mic graph. Runs the body on `stateQueue`
    /// because `AVAudioEngine` wiring is not thread-safe; `engine.start()`
    /// may block briefly on the HAL — acceptable on a utility queue, never
    /// called from an RT surface.
    private func startMic(generation: Int, clock: MachSessionClock) async throws {
        let started = await onStateQueue { self.startMicLocked(generation: generation, clock: clock) }
        guard started else {
            throw CaptureEngineError.microphoneStartFailed(
                "input format \(await micFormatDescription()) unusable or engine.start() failed")
        }
    }

    /// StateQueue-confined. Returns true on success. Idempotent: tears down
    /// any previous engine first (device-change rebuilds land here too).
    @discardableResult
    private func startMicLocked(generation: Int, clock: MachSessionClock) -> Bool {
        stopMicLocked()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Voice processing BEFORE tap install: toggling it changes the input
        // node's format, so a tap installed earlier would hold a stale
        // format. Failure is deliberately non-fatal (SPEC §7 fallback ladder
        // rung 2: VP off, accept partial bleed) — Spike 1 decides whether
        // the default should change at all.
        if config.voiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                // Fall through: capture continues with VP off.
            }
        }

        // Mic HW format (often 48 kHz stereo); the tap must use the node's
        // own output format — resampling to 16 kHz happens downstream.
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // RT-thread contract (class doc): stamp + dispatch, nothing else.
            guard let self else { return }
            let offset = clock.nowOffset() // value copy — lock-free read
            self.processingQueue.async {
                self.ingest(buffer, channel: .local, sessionOffset: offset, generation: generation)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
        audioEngine = engine
        return true
    }

    /// StateQueue-confined. Safe when no engine exists.
    private func stopMicLocked() {
        guard let engine = audioEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
        processingQueue.async { [weak self] in self?.downsamplers[.local] = nil }
    }

    private func micFormatDescription() async -> String {
        await onStateQueue {
            self.audioEngine?.inputNode.outputFormat(forBus: 0).description ?? "no input device"
        }
    }

    // MARK: - System audio (SCStream, SPEC §4.1)

    /// Starts (or silently restarts) the system-audio stream. Never throws:
    /// failures run the SPEC §4.1 ladder (one silent restart → mic-only).
    private func startRemoteStream(generation: Int, clock: MachSessionClock) async {
        do {
            let content = try await SCShareableContent.current
            // SPEC §4.1: capture the MAIN display, never window-filtered
            // content (filtered audio capture has its own bug surface).
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first else {
                await degradeRemote(reason: .noDisplayFound)
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let streamConfig = SCStreamConfiguration()
            // There is no audio-only SCStream — video frames are unavoidable.
            // Minimize the waste (SPEC §4.1): 2×2 pixels @ 1 fps, no cursor,
            // shallow queue. Video frames are discarded on arrival.
            streamConfig.width = 2
            streamConfig.height = 2
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
            streamConfig.showsCursor = false
            streamConfig.queueDepth = 3

            // Per-session sink carries the clock + generation as immutable
            // VALUE captures — ScreenCaptureKit's callback threads touch no
            // shared mutable state (class threading doc).
            let sink = RemoteAudioRelay(engine: self, clock: clock, generation: generation)
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
            _ = try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: nil) // discard-on-arrival
            _ = try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: remoteSampleQueue)
            try await stream.startCapture()

            // stop() may have raced the awaits above — don't adopt a stream
            // into a dead session.
            let stillRunning: Bool = await onStateQueue { self.running }
            guard stillRunning else {
                try? await stream.stopCapture()
                return
            }
            await onStateQueue {
                self.scStream = stream
                self.remoteSink = sink
                self.remoteActive = true
                self.expectingTeardown = false
            }
        } catch {
            await handleRemoteFailure("SCStream start failed: \(error.localizedDescription)")
        }
    }

    /// SPEC §4.1 failure modes: one silent restart, second failure →
    /// mic-only. Shared by start failures and `didStopWithError` (a mid-
    /// session permission revocation arrives as a stream error and rides
    /// the same ladder).
    private func handleRemoteFailure(_ detail: String) async {
        let attemptRestart: Bool = await onStateQueue {
            guard self.running else { return false }
            guard self.remoteRestartsUsed == 0 else { return false }
            self.remoteRestartsUsed = 1
            return true
        }
        if attemptRestart {
            await teardownRemote()
            let clock = await onStateQueue { self.sessionClock }
            let generation = currentGeneration()
            await startRemoteStream(generation: generation, clock: clock)
        } else {
            await degradeRemote(reason: .remoteStreamFailed, detail: detail)
        }
    }

    /// Ends the remote stream gracefully and flips to mic-only
    /// (`remoteStreamActive = false`). Fires `onRemoteDegraded` at most once
    /// per session. Session stays alive; clock keeps running (SPEC §4.1).
    private func degradeRemote(reason: RemoteDegradationReason, detail: String? = nil) async {
        await teardownRemote()
        let announce: Bool = await onStateQueue {
            guard self.running, !self.remoteDegradationAnnounced else { return false }
            self.remoteDegradationAnnounced = true
            self.remoteActive = false
            return true
        }
        guard announce else { return }
        let message = detail.map { "\(reason.rawValue): \($0)" } ?? reason.rawValue
        onRemoteDegraded?(message)
    }

    private func teardownRemote() async {
        let tornDown: (SCStream?, RemoteAudioRelay?) = await onStateQueue {
            let pair = (self.scStream, self.remoteSink)
            self.scStream = nil
            self.remoteSink = nil
            self.remoteActive = false
            return pair
        }
        guard let stream = tornDown.0, let sink = tornDown.1 else { return }
        try? await stream.stopCapture()
        _ = try? stream.removeStreamOutput(sink, type: .audio)
        _ = try? stream.removeStreamOutput(sink, type: .screen)
    }

    // MARK: - Sample ingestion (processingQueue only)

    /// Converts one captured buffer (either channel) to 16 kHz mono Float32
    /// and hands it up via `onAudio`. Rebuilds the per-channel downsampler if
    /// the source format changed mid-session (device switch).
    private func ingest(_ buffer: AVAudioPCMBuffer, channel: Channel,
                        sessionOffset: TimeInterval, generation: Int) {
        guard generation == currentGeneration() else { return } // stale callback

        let downsampler: PCMDownsampler
        if let existing = downsamplers[channel], existing.accepts(format: buffer.format) {
            downsampler = existing
        } else {
            guard let fresh = try? PCMDownsampler(sourceFormat: buffer.format) else { return }
            downsamplers[channel] = fresh
            downsampler = fresh
        }

        let samples = downsampler.convert(buffer)
        guard !samples.isEmpty else { return }
        onAudio?(CapturedSample(channel: channel,
                                sessionOffset: sessionOffset,
                                sampleRate: PCMDownsampler.targetSampleRate,
                                samples: samples))
    }

    /// Called by `RemoteAudioRelay` on `processingQueue`.
    fileprivate func ingestRemote(_ sampleBuffer: CMSampleBuffer,
                                  sessionOffset: TimeInterval, generation: Int) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        ingest(pcm, channel: .remote, sessionOffset: sessionOffset, generation: generation)
    }

    /// CMSampleBuffer (SCK audio) → AVAudioPCMBuffer at the stream's own
    /// format (SPEC §4.1: convert at the stream's format, then downsample).
    /// Pure function — testable-by-inspection, exercised only on hardware.
    ///
    /// `AVAudioPCMBuffer(cmSampleBuffer:)` does not exist on macOS (verified
    /// against the macOS 26 SDK — iOS-only initializer), so this extracts the
    /// PCM via `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` and
    /// copies channel data into a buffer built from the sample buffer's ASBD.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        // ScreenCaptureKit delivers linear PCM Float32; guard rather than
        // assume so a format surprise degrades to a dropped buffer, not a
        // misread memory block.
        guard asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.pointee.mBitsPerChannel == 32 else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        guard channels > 0, let format = AVAudioFormat(streamDescription: asbd),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let outChannels = out.floatChannelData else { return nil }

        // AudioBufferList sized for `channels` non-interleaved buffers.
        let ablByteSize = MemoryLayout<AudioBufferList>.size
            + (channels - 1) * MemoryLayout<AudioBuffer>.size
        var ablStorage = [UInt8](repeating: 0, count: ablByteSize)
        var retainedBlockBuffer: CMBlockBuffer?

        let extracted: Bool = ablStorage.withUnsafeMutableBytes { raw in
            guard let list = raw.baseAddress?.assumingMemoryBound(to: AudioBufferList.self) else {
                return false
            }
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: list,
                bufferListSize: ablByteSize,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &retainedBlockBuffer)
            guard status == noErr, Int(list.pointee.mNumberBuffers) >= (format.isInterleaved ? 1 : channels) else {
                return false
            }
            // The C flexible-array member `mBuffers[1]` imports as a tuple,
            // so buffer access goes through byte-offset arithmetic on the
            // array's real layout (works for the interleaved single-buffer
            // and the per-channel non-interleaved cases alike).
            let buffersBase = UnsafeRawPointer(list)
                + MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers)!
            if format.isInterleaved {
                // Single buffer: L R L R … — contiguous Float frames.
                let buffer = buffersBase.load(as: AudioBuffer.self)
                guard let data = buffer.mData else { return false }
                let byteCount = min(Int(buffer.mDataByteSize), Int(frameCount) * channels * MemoryLayout<Float>.size)
                memcpy(outChannels[0], data, byteCount)
            } else {
                // One buffer per channel.
                for channel in 0..<channels {
                    let audioBuffer = buffersBase.load(
                        fromByteOffset: channel * MemoryLayout<AudioBuffer>.stride, as: AudioBuffer.self)
                    guard let data = audioBuffer.mData else { continue }
                    let byteCount = min(Int(audioBuffer.mDataByteSize), Int(frameCount) * MemoryLayout<Float>.size)
                    memcpy(outChannels[channel], data, byteCount)
                }
            }
            out.frameLength = frameCount
            return true
        }
        guard extracted else { return nil }
        return out
    }

    // MARK: - Device switching (SPEC §4.1)

    /// StateQueue-confined. Registers the config-change observer.
    private func registerObserversLocked() {
        let center = NotificationCenter.default
        // SPEC §4.1: "subscribe to AVAudioEngineConfigurationChange +
        // route-change notifications." On macOS the two collapse: input-device
        // route changes surface AS `.AVAudioEngineConfigurationChange`
        // (`AVAudioSession.routeChangeNotification` does not exist on macOS —
        // verified against the macOS SDK headers). `object: nil` so the
        // observation survives engine rebuilds.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async { self.rebuildMicLocked() }
        })
    }

    private func removeObserversLocked() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// StateQueue-confined. SPEC §4.1 device switching: pause → rebuild the
    /// engine graph → resume, session and clock untouched (the clock keeps
    /// running; the `deviceChanged` event explains the gap).
    private func rebuildMicLocked() {
        guard running, audioEngine != nil else { return }
        let generation = currentGeneration()
        let clock = sessionClock
        _ = startMicLocked(generation: generation, clock: clock)
        // Fire even if the rebuild failed: the coordinator logs the event
        // (T2 `onRelayDeviceChange` seam); a failed rebuild manifests as local
        // samples pausing — dogfood hardening (T10) owns retry polish.
        onDeviceChange?()
    }

    // MARK: - Generation

    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    // MARK: - Queue hop helper

    /// Runs `body` on `stateQueue` and resumes with its result.
    private func onStateQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            stateQueue.async { cont.resume(returning: body()) }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

// MARK: - SCStream delegate (engine itself; hops to stateQueue)

extension SCKCaptureEngine: SCStreamDelegate {

    /// Unexpected stream stop (error, stall, or mid-session Screen Recording
    /// revocation — revocation arrives here as an error, SPEC §4.1).
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateQueue.async { [weak self] in
            guard let self, self.running, !self.expectingTeardown else { return }
            let detail = "SCStream stopped: \(error.localizedDescription)"
            Task { await self.handleRemoteFailure(detail) }
        }
    }
}

// MARK: - SCStream audio sink (per session)

/// Per-session `SCStreamOutput`. Receives BOTH frame types: `.screen` frames
/// are the unavoidable video waste (SPEC §4.1) and are discarded on arrival;
/// `.audio` buffers are stamped and hopped to the engine's processing queue.
///
/// Exists as a separate object so the session clock and generation travel as
/// immutable value captures into ScreenCaptureKit's callback threads — those
/// threads read no shared mutable engine state.
private final class RemoteAudioRelay: NSObject, SCStreamOutput {
    // Weak: the engine stops/removes the stream before deallocating, but a
    // mid-flight sample after teardown must not resurrect a dead engine.
    private weak var engine: SCKCaptureEngine?
    private let clock: MachSessionClock
    private let generation: Int

    init(engine: SCKCaptureEngine, clock: MachSessionClock, generation: Int) {
        self.engine = engine
        self.clock = clock
        self.generation = generation
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Video frames are discarded on arrival (SPEC §4.1) — 2×2 @ 1 fps.
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        // Stamp before the hop so queue delay never skews the offset
        // (engine class doc: arrival-time convention, both channels).
        let offset = clock.nowOffset()
        let generation = self.generation
        engine?.processingQueue.async { [weak engine] in
            guard let engine else { return }
            engine.ingestRemote(sampleBuffer, sessionOffset: offset, generation: generation)
        }
    }
}
