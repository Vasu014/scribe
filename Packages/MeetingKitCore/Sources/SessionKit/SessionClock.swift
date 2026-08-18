import Darwin
import Foundation

/// The session clock (SPEC §4.1, pinned): monotonic, `mach_continuous_time`-
/// based, started at session begin. `mach_continuous_time` is chosen
/// deliberately — unlike `mach_absolute_time` it ADVANCES ACROSS SLEEP,
/// matching the stated model: "the clock keeps running, gaps are honest."
/// Device-switch and sleep/wake interruptions never pause it; the
/// `device_events` timeline explains the gaps (SPEC §4.1 pause/clock
/// semantics: exactly one timeline, no inactive-time exclusion).
///
/// TWO CLOCKS, TWO JOBS (SPEC §4.1): this clock stamps AUDIO OFFSETS —
/// segment start/end, fragment anchors, device-event offsets. Elapsed
/// displays (menu-bar timer) and session durations derive from the WALL
/// CLOCK — `SessionRecord.startedAt`/`endedAt` — never from this clock.
/// See `SessionCoordinator.elapsed()` for the wall-clock side.
///
/// Epoch convention: offset 0 = session begin. The capture engine stamps
/// audio buffers on its own instance of this same clock basis (started when
/// the engine starts, at session begin); the coordinator's instance stamps
/// device events and fragment anchors. Both share the epoch convention and
/// the `mach_continuous_time` basis, so their offsets are comparable at the
/// granularities that matter (fragments anchor via a 20 s lookback;
/// device events explain second-level gaps).
///
/// Value type: copies carry the same origin ticks, so handing one out never
/// restarts the timeline.
public struct SessionClock: Sendable {

    /// Ticks since session begin on the continuous monotonic clock.
    private let startTicks: UInt64
    /// Seconds per tick: `mach_timebase_info` gives NANOseconds per tick
    /// (numer/denom — e.g. 125/3 on Apple Silicon), hence the 1e9 divisor.
    private let secondsPerTick: Double

    /// Starts the clock NOW (call at session begin).
    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / (Double(info.denom) * 1_000_000_000)
        startTicks = mach_continuous_time()
    }

    /// Seconds elapsed on the session clock since session begin.
    /// Monotonic non-decreasing; keeps advancing across system sleep.
    public func nowOffset() -> TimeInterval {
        let now = mach_continuous_time()
        return Double(now - startTicks) * secondsPerTick
    }
}
