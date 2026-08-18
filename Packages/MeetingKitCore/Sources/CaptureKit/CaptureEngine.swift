import Foundation
import Persistence

/// Downsampled PCM handed up by CaptureKit. SessionKit converts these into
/// TranscribeKit.AudioChunk — CaptureKit does not depend on TranscribeKit;
/// data flows through the composition root and the store, never sideways (SPEC §3.1).
public struct CapturedSample: Sendable {
    public let channel: Channel
    /// Offset from session start on the monotonic session clock
    /// (`mach_continuous_time`-based, SPEC §4.1).
    public let sessionOffset: TimeInterval
    public let sampleRate: Double
    public let samples: [Float]

    public init(channel: Channel, sessionOffset: TimeInterval, sampleRate: Double = 16_000, samples: [Float]) {
        self.channel = channel
        self.sessionOffset = sessionOffset
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

/// Capture engine seam. The real implementation is the Spike 1 deliverable:
/// SCStream (system audio, main display, 2×2 @ 1 fps video discarded) +
/// AVAudioEngine input (voice processing per spike outcome), with a start
/// order constant documented with tested macOS build numbers (SPEC §4.1, §7).
public protocol CaptureEngine: AnyObject, Sendable {
    /// Audio callback. Called on an internal queue; handlers must not block.
    var onAudio: ((CapturedSample) -> Void)? { get set }

    /// Starts both streams. Throws on unrecoverable permission loss.
    func start() async throws

    /// Stops both streams and releases resources. Safe to call when stopped.
    func stop() async

    /// True when the system-audio (remote) stream is live; false when
    /// degraded to mic-only (permission revoked / SCStream double-failure).
    var remoteStreamActive: Bool { get }
}

/// Emits silence on both channels on a timer. Used for UI development and
/// SessionKit wiring tests until Spike 1 lands the real engine.
public final class StubCaptureEngine: CaptureEngine, @unchecked Sendable {
    public var onAudio: ((CapturedSample) -> Void)?
    public private(set) var remoteStreamActive = true

    private let queue = DispatchQueue(label: "scribe.capture.stub")
    private var timer: DispatchSourceTimer?
    private let sessionStart = ContinuousClock.now

    public init() {}

    public func start() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(); return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let elapsed = ContinuousClock.now - self.sessionStart
                    let sample = CapturedSample(
                        channel: Channel.local,
                        sessionOffset: TimeInterval(elapsed.components.seconds),
                        samples: [Float](repeating: 0, count: 1_600)
                    )
                    self.onAudio?(sample)
                }
                timer.resume()
                self.timer = timer
                cont.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.timer?.cancel()
                self?.timer = nil
                cont.resume()
            }
        }
    }
}
