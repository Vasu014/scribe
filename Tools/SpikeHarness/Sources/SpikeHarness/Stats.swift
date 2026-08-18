import CaptureKit
import Foundation

// MARK: - Per-channel stats

/// Delivery stats for one channel. `onAudio` arrives on the engine's
/// processing queue while snapshots are read from the run loop — every
/// access goes through the lock.
final class ChannelStats: @unchecked Sendable {

    struct Snapshot: Sendable {
        let buffers: Int
        let samples: Int
        /// Offset (seconds, session clock) of the first delivered buffer —
        /// the stream bring-up latency.
        let firstArrival: Double?
        /// Offset of the most recent buffer (nil when nothing arrived).
        let lastArrival: Double?
        /// Largest gap between consecutive buffers WHILE the stream was
        /// delivering (post-mortem silence never inflates this — there are
        /// no arrivals after death to diff against).
        let maxGap: Double
    }

    private let lock = NSLock()
    private var buffers = 0
    private var samples = 0
    private var firstArrival: Double?
    private var lastArrival: Double?
    private var maxGap: Double = 0

    func record(_ sample: CapturedSample) {
        lock.lock()
        defer { lock.unlock() }
        buffers += 1
        samples += sample.samples.count
        if let last = lastArrival {
            let gap = sample.sessionOffset - last
            if gap > maxGap { maxGap = gap }
        } else {
            firstArrival = sample.sessionOffset
        }
        lastArrival = sample.sessionOffset
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(buffers: buffers, samples: samples,
                        firstArrival: firstArrival, lastArrival: lastArrival,
                        maxGap: maxGap)
    }
}

// MARK: - Run-wide stats

/// Everything the verdict needs, fed from the engine's callbacks (which run
/// on internal engine queues) and read from the run loop. Lock-guarded.
final class RunStats: @unchecked Sendable {

    let mic = ChannelStats()
    let remote = ChannelStats()

    private let lock = NSLock()
    /// Monotonic harness run start (just before `engine.start()`); drives
    /// elapsed/progress/degradation-time bookkeeping. Sample offsets
    /// themselves use the engine's session clock (stamp-at-arrival).
    private let startNanos: UInt64
    private var stopRequested = false
    private var degradation: (reason: String, atSec: Double)?
    private var deviceChanges = 0

    init() {
        startNanos = DispatchTime.now().uptimeNanoseconds
    }

    /// Seconds since run start (monotonic; not the session clock).
    func elapsedSec() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000_000
    }

    func ingest(_ sample: CapturedSample) {
        if sample.channel == .local { mic.record(sample) } else { remote.record(sample) }
    }

    func remoteDegraded(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard degradation == nil else { return } // engine fires it once; mirror that
        degradation = (reason, elapsedSec())
    }

    func degradationLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return degradation.map { "\($0.reason) at +\($0.atSec.rounded(to: 1)) s" }
    }

    func deviceChange() {
        lock.lock()
        defer { lock.unlock() }
        deviceChanges += 1
    }

    func deviceChangeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return deviceChanges
    }

    func requestStop() {
        lock.lock()
        defer { lock.unlock() }
        stopRequested = true
    }

    func isStopRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
