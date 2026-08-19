import Accelerate
import Foundation

/// VAD gate at the CAPTURE end of the pipeline (SPEC §4.1/§4.2).
///
/// WHY THIS EXISTS — what was actually being wasted.
/// TranscribeKit's `ChannelWorker` already VADs: a window only opens on a
/// frame above its speech threshold, so **inference never ran on silence**
/// even before this type existed. The waste was entirely UPSTREAM of the
/// decoder and ran for every buffer of every silent minute, on both channels:
///
///   AVAudioEngine / SCStream buffer (48 kHz stereo Float32, ~10–100 ms)
///     → mono mixdown at 48 kHz
///     → `AVAudioConverter` polyphase resample 48 kHz → 16 kHz   ← the cost
///     → `[Float]` allocation + `CapturedSample` + `AudioChunk`
///     → AsyncStream yield → actor hop into `ChannelWorker`
///     → 30 ms RMS frames → discarded
///
/// The resample is the expensive stage and it ran 100 % of the time while
/// merely listening. This gate moves the speech/silence decision AHEAD of it:
/// silent buffers are dropped after the (cheap, already-required) mixdown and
/// never reach the converter, the allocator, the stream or the actor.
///
/// SAFETY — why this cannot drop audio that would have been transcribed:
/// - **Threshold is strictly more permissive.** `defaultThresholdRMS` is HALF
///   of TranscribeKit's `speechThresholdRMS` (0.005), and the decision uses
///   the PEAK of 30 ms sub-frames rather than the whole-buffer average, so a
///   short onset inside a mostly-silent buffer still opens the gate. Any
///   frame the downstream VAD would call speech clears this gate first.
///   (The downstream constants are fixed — tuned against real meeting audio;
///   see `ChannelWorker`. This gate only ever admits MORE than they need.)
/// - **Pre-roll.** The last `prerollSeconds` of skipped audio is retained and
///   prepended when the gate opens, so the attack of the first word is never
///   the thing that got dropped. The emitted sample's `sessionOffset` is
///   moved back by exactly the pre-roll duration, so offsets stay honest.
/// - **Hangover longer than the downstream one.** The gate keeps admitting
///   for `hangoverSeconds` (1.5 s) after the last speech, which EXCEEDS
///   `ChannelWorker.hangoverSeconds` (1.2 s). That is load-bearing: the
///   worker closes a window on 1.2 s of trailing silence, so it must still
///   receive that silence. `SilenceGateTests` pins that relationship.
///
/// Skipped stretches produce a jump in `sessionOffset`, which the worker
/// already treats as an honest gap (SPEC §4.1) — it closes the window instead
/// of stitching. By construction no window is open when a skip starts.
///
/// Not thread-safe: one instance per channel, confined to the engine's serial
/// processing queue (like `PCMDownsampler`).
public final class SilenceGate {

    /// Half of TranscribeKit's 0.005 speech threshold — see class docs.
    public static let defaultThresholdRMS: Float = 0.0025
    /// Must stay > `ChannelWorker.hangoverSeconds` (1.2 s).
    public static let defaultHangoverSeconds: Double = 1.5
    public static let defaultPrerollSeconds: Double = 0.25
    /// Same 30 ms decision frame the downstream VAD uses.
    public static let decisionFrameMilliseconds: Int = 30

    /// What to hand the converter: `samples` (pre-roll + this buffer) and how
    /// many leading samples came from the pre-roll, so the caller can move the
    /// arrival-stamped session offset back by exactly that much.
    public struct Admission: Sendable, Equatable {
        public let samples: [Float]
        public let prerollSamples: Int
    }

    public let sampleRate: Double
    public let thresholdRMS: Float
    private let hangoverSamples: Int
    private let prerollCapacity: Int
    private let frameSamples: Int

    /// Samples of below-threshold audio since the last speech buffer. Starts
    /// "closed" so a session that begins in silence converts nothing.
    private var silenceSamples: Int

    /// Fixed-capacity pre-roll ring. A plain array + `removeFirst` was
    /// measurably WORSE than the resample it was meant to save (an O(n)
    /// memmove per silent buffer, ~47 times a second, forever); the whole
    /// point of this type is to be cheaper than the work it skips.
    private var ring: [Float]
    private var ringWrite = 0
    private var ringFilled = 0

    // Diagnostics: a gate that silently ate a meeting must be visible in one
    // line, the same way `ChannelWorker`'s capture summary is (T10 dogfood).
    public private(set) var admittedSamples = 0
    public private(set) var skippedSamples = 0
    public private(set) var openings = 0

    public init(
        sampleRate: Double,
        thresholdRMS: Float = SilenceGate.defaultThresholdRMS,
        hangoverSeconds: Double = SilenceGate.defaultHangoverSeconds,
        prerollSeconds: Double = SilenceGate.defaultPrerollSeconds
    ) {
        self.sampleRate = sampleRate
        self.thresholdRMS = thresholdRMS
        self.hangoverSamples = Int(hangoverSeconds * sampleRate)
        self.prerollCapacity = Int(prerollSeconds * sampleRate)
        self.frameSamples = max(1, Int(sampleRate * Double(Self.decisionFrameMilliseconds) / 1000))
        self.silenceSamples = self.hangoverSamples
        self.ring = [Float](repeating: 0, count: max(0, self.prerollCapacity))
    }

    /// Fraction of captured audio that never reached the resampler.
    public var skipRatio: Double {
        let total = admittedSamples + skippedSamples
        return total > 0 ? Double(skippedSamples) / Double(total) : 0
    }

    /// Decides one mono buffer at the SOURCE sample rate.
    ///
    /// - Returns: samples to convert (pre-roll included), or `nil` when the
    ///   buffer is silence outside the hangover and can be skipped entirely.
    public func admit(_ mono: [Float]) -> Admission? {
        guard !mono.isEmpty else { return nil }

        if peakFrameRMS(mono) >= thresholdRMS {
            let lead = ringFilled
            if lead == 0 {
                // Fast path: already open, nothing withheld — no copy at all.
                if silenceSamples >= hangoverSamples { openings += 1 }
                silenceSamples = 0
                admittedSamples += mono.count
                return Admission(samples: mono, prerollSamples: 0)
            }
            var out = drainPreroll()
            out.append(contentsOf: mono)
            openings += 1
            silenceSamples = 0
            admittedSamples += out.count
            // The pre-roll samples were counted as skipped when they were
            // withheld; they are being delivered after all.
            skippedSamples = max(0, skippedSamples - lead)
            return Admission(samples: out, prerollSamples: lead)
        }

        // Below threshold. Keep feeding while inside the hangover so the
        // downstream 1.2 s window-close still sees its trailing silence.
        if silenceSamples < hangoverSamples {
            silenceSamples += mono.count
            admittedSamples += mono.count
            return Admission(samples: mono, prerollSamples: 0)
        }

        // Fully closed: retain as pre-roll, convert nothing.
        silenceSamples = min(silenceSamples &+ mono.count, Int.max / 2)
        skippedSamples += mono.count
        retainAsPreroll(mono)
        return nil
    }

    /// Drops retained pre-roll and re-closes the gate — used when the source
    /// format changes (device switch) and the downsampler is rebuilt, so
    /// stale samples at the OLD rate can never be prepended to new audio.
    public func reset() {
        ringWrite = 0
        ringFilled = 0
        silenceSamples = hangoverSamples
    }

    // MARK: Internals

    /// Copies the tail of `mono` into the fixed ring — no allocation, no
    /// shifting, bounded by the ring's own capacity.
    private func retainAsPreroll(_ mono: [Float]) {
        guard prerollCapacity > 0 else { return }
        let taken = min(mono.count, prerollCapacity)
        mono.withUnsafeBufferPointer { source in
            let base = source.baseAddress! + (mono.count - taken)
            ring.withUnsafeMutableBufferPointer { destination in
                let first = min(taken, prerollCapacity - ringWrite)
                destination.baseAddress!.advanced(by: ringWrite)
                    .update(from: base, count: first)
                if first < taken {
                    destination.baseAddress!.update(from: base + first, count: taken - first)
                }
            }
        }
        ringWrite = (ringWrite + taken) % prerollCapacity
        ringFilled = min(ringFilled + taken, prerollCapacity)
    }

    /// Oldest-first copy of the retained pre-roll; empties the ring.
    private func drainPreroll() -> [Float] {
        let count = ringFilled
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let start = (ringWrite - count + prerollCapacity) % prerollCapacity
        ring.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                let first = min(count, prerollCapacity - start)
                destination.baseAddress!.update(from: source.baseAddress! + start, count: first)
                if first < count {
                    destination.baseAddress!.advanced(by: first)
                        .update(from: source.baseAddress!, count: count - first)
                }
            }
        }
        ringWrite = 0
        ringFilled = 0
        return out
    }

    /// Peak RMS over 30 ms sub-frames — deliberately more sensitive than a
    /// whole-buffer RMS so a burst inside a long quiet buffer still opens the
    /// gate (the mic tap delivers 4096-frame / 85 ms buffers, ~3 frames each).
    /// Buffers shorter than one frame are decided whole.
    ///
    /// `vDSP_rmsqv` rather than a Swift loop: this runs on every buffer of
    /// every silent minute, so it has to be SIMD or the gate costs more than
    /// the resample it skips (measured — see `SilenceGateTests`).
    private func peakFrameRMS(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            guard buffer.count >= frameSamples else {
                return Self.rms(base, buffer.count)
            }
            var peak: Float = 0
            var index = 0
            while index + frameSamples <= buffer.count {
                peak = max(peak, Self.rms(base + index, frameSamples))
                if peak >= thresholdRMS { return peak }   // early out
                index += frameSamples
            }
            // Trailing remainder shorter than a frame: decided too, so an
            // onset at the very end of a buffer cannot be discarded.
            if index < buffer.count {
                peak = max(peak, Self.rms(base + index, buffer.count - index))
            }
            return peak
        }
    }

    private static func rms(_ pointer: UnsafePointer<Float>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(pointer, 1, &result, vDSP_Length(count))
        return result
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.withUnsafeBufferPointer { rms($0.baseAddress!, $0.count) }
    }
}
