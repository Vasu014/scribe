import AVFAudio
import XCTest
@testable import CaptureKit

/// Item 20: the capture-side VAD gate that keeps silence out of the
/// resampler. These tests exist to answer one question — *can this drop audio
/// that should have been transcribed?* — plus a benchmark for the compute
/// claim.
///
/// TranscribeKit's constants are the fixed reference points here (they were
/// tuned against real meeting audio and must not move): 30 ms decision
/// frames, `speechThresholdRMS` 0.005, `hangoverSeconds` 1.2.
final class SilenceGateTests: XCTestCase {

    // Downstream (TranscribeKit `ChannelWorker`) constants, restated so a
    // change there fails a test here rather than silently invalidating the
    // safety argument. CaptureKit must not import TranscribeKit (SPEC §3.1).
    private static let downstreamSpeechThresholdRMS: Float = 0.005
    private static let downstreamHangoverSeconds: Double = 1.2
    private static let frameMilliseconds = 30

    private let sourceRate: Double = 48_000
    /// 85 ms — the mic tap's real buffer size (`installTap(bufferSize: 4096)`).
    private let bufferFrames = 4_096

    // MARK: Signal helpers

    /// A buffer of `frames` samples of a 300 Hz tone with the given RMS.
    private func tone(rms: Float, frames: Int, phase: inout Double) -> [Float] {
        let amplitude = rms * 2.0.squareRoot().float
        let step = 2 * Double.pi * 300 / sourceRate
        var out = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            out[index] = amplitude * Float(sin(phase))
            phase += step
        }
        return out
    }

    /// Room tone: well below the gate threshold, like a real quiet mic.
    private func silence(frames: Int) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<frames).map { _ in Float.random(in: -0.0008...0.0008, using: &generator) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        SilenceGate.rms(samples)
    }

    /// Peak 30 ms-frame RMS — the downstream VAD's own decision, applied to a
    /// source-rate buffer.
    private func peakFrameRMS(_ samples: [Float], rate: Double) -> Float {
        let frame = Int(rate * Double(Self.frameMilliseconds) / 1000)
        guard samples.count >= frame else { return rms(samples[...]) }
        var peak: Float = 0
        var index = 0
        while index + frame <= samples.count {
            peak = max(peak, rms(samples[index..<(index + frame)]))
            index += frame
        }
        if index < samples.count { peak = max(peak, rms(samples[index...])) }
        return peak
    }

    // MARK: The gate itself

    func testThresholdStaysBelowTheDownstreamSpeechThreshold() {
        XCTAssertLessThan(SilenceGate.defaultThresholdRMS, Self.downstreamSpeechThresholdRMS,
                          "the gate must admit MORE than TranscribeKit needs, never less")
    }

    /// Load-bearing (see `SilenceGate` docs): the worker closes a window on
    /// 1.2 s of trailing silence, so the gate must keep delivering longer than
    /// that or a window would only close on the next honest gap — minutes
    /// later, or at stop.
    func testHangoverOutlivesTheDownstreamWindowClose() {
        XCTAssertGreaterThan(SilenceGate.defaultHangoverSeconds, Self.downstreamHangoverSeconds)
    }

    func testAnEntirelySilentSessionIsNeverResampled() {
        let gate = SilenceGate(sampleRate: sourceRate)
        var admitted = 0
        for _ in 0..<Int(30 * sourceRate) / bufferFrames {   // 30 s
            if gate.admit(silence(frames: bufferFrames)) != nil { admitted += 1 }
        }
        XCTAssertEqual(admitted, 0, "silence must not reach the converter at all")
        XCTAssertEqual(gate.openings, 0)
        XCTAssertEqual(gate.skipRatio, 1.0, accuracy: 0.0001)
    }

    func testSpeechIsAdmittedWholeWithPreRoll() throws {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        // 2 s of silence first, so the pre-roll buffer is full.
        for _ in 0..<Int(2 * sourceRate) / bufferFrames {
            XCTAssertNil(gate.admit(silence(frames: bufferFrames)))
        }
        let speech = tone(rms: 0.02, frames: bufferFrames, phase: &phase)
        let opened = try XCTUnwrap(gate.admit(speech))

        let expectedPreroll = Int(SilenceGate.defaultPrerollSeconds * sourceRate)
        XCTAssertEqual(opened.prerollSamples, expectedPreroll,
                       "the 250 ms before the first word must be delivered, not dropped")
        XCTAssertEqual(opened.samples.count, expectedPreroll + bufferFrames)
        XCTAssertEqual(Array(opened.samples.suffix(bufferFrames)), speech,
                       "the speech buffer itself must pass through byte-for-byte")
        XCTAssertEqual(gate.openings, 1)
    }

    /// The pre-roll is a hand-written fixed ring (an array + `removeFirst`
    /// cost more than the resample it saves), so its CONTENT is pinned too:
    /// the 250 ms handed over must be the most recent skipped audio, oldest
    /// sample first. A wrap-around bug here would splice the meeting.
    func testPreRollDeliversTheMostRecentSkippedAudioInOrder() throws {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        var skipped: [Float] = []

        // 3 s of quiet, every buffer uniquely marked (levels stay far below
        // the gate threshold), so any mis-ordering is visible.
        for index in 0..<Int(3 * sourceRate) / bufferFrames {
            let marked = (0..<bufferFrames).map { Float(index) * 1e-5 + Float($0) * 1e-9 }
            XCTAssertNil(gate.admit(marked))
            skipped.append(contentsOf: marked)
        }

        let opened = try XCTUnwrap(gate.admit(tone(rms: 0.02, frames: bufferFrames, phase: &phase)))
        XCTAssertEqual(Array(opened.samples.prefix(opened.prerollSamples)),
                       Array(skipped.suffix(opened.prerollSamples)),
                       "pre-roll must be the last 250 ms of skipped audio, in order")
    }

    func testTrailingSilenceKeepsFlowingForLongerThanTheDownstreamHangover() {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        _ = gate.admit(tone(rms: 0.02, frames: bufferFrames, phase: &phase))

        var trailingSamples = 0
        while let admission = gate.admit(silence(frames: bufferFrames)) {
            trailingSamples += admission.samples.count
            if trailingSamples > Int(5 * sourceRate) { break }   // runaway guard
        }
        let trailingSeconds = Double(trailingSamples) / sourceRate
        XCTAssertGreaterThan(trailingSeconds, Self.downstreamHangoverSeconds,
                             "the worker needs 1.2 s of silence to close its window")
        XCTAssertLessThan(trailingSeconds, 2.0, "…but not so much that the saving evaporates")
    }

    /// The safety margin, made concrete. A buffer whose OVERALL level is
    /// below TranscribeKit's speech threshold can still contain a 30 ms frame
    /// the downstream VAD would call speech — the first syllable after a
    /// pause, arriving in the tail of an 85 ms tap buffer. Two independent
    /// margins keep it: the halved threshold and the per-frame decision.
    ///
    /// Fails for a real reason: set the gate threshold to the downstream
    /// 0.005 and this buffer (average 0.0044) stops being admitted.
    func testABufferQuieterOnAverageThanTheDownstreamThresholdIsStillAdmitted() {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        for _ in 0..<10 { XCTAssertNil(gate.admit(silence(frames: bufferFrames))) }

        // Silent except for the last 1216 samples (25 ms) at RMS 0.008.
        var onsetBuffer = silence(frames: bufferFrames)
        let onset = tone(rms: 0.008, frames: 1_216, phase: &phase)
        onsetBuffer.replaceSubrange((bufferFrames - 1_216)..<bufferFrames, with: onset)

        XCTAssertLessThan(rms(onsetBuffer[...]), Self.downstreamSpeechThresholdRMS,
                          "precondition: the buffer AVERAGE looks like silence")
        XCTAssertGreaterThanOrEqual(peakFrameRMS(onsetBuffer, rate: sourceRate),
                                    Self.downstreamSpeechThresholdRMS,
                                    "precondition: TranscribeKit's VAD would call this speech")

        XCTAssertNotNil(gate.admit(onsetBuffer), "a word starting at the buffer edge must not be lost")
    }

    func testResetDropsPreRollSoAStaleRateIsNeverPrepended() {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        for _ in 0..<20 { _ = gate.admit(silence(frames: bufferFrames)) }
        gate.reset()
        let admission = gate.admit(tone(rms: 0.02, frames: bufferFrames, phase: &phase))
        XCTAssertEqual(admission?.prerollSamples, 0)
    }

    // MARK: The regression that matters — no transcribable audio is dropped

    /// A synthetic meeting: long silences, short interjections, and a burst
    /// sitting just above the downstream threshold (0.006 vs 0.005 — the
    /// margin a system-audio stream actually runs at; 0.0101 peak was the
    /// real measurement that forced the 0.005 constant).
    ///
    /// EVERY source buffer the downstream VAD would find speech in must be
    /// admitted. This is the exact property that makes the gate safe, and it
    /// fails for a real reason: raise `SilenceGate.defaultThresholdRMS` above
    /// 0.005, or switch the decision to a whole-buffer average, and the quiet
    /// burst stops being admitted.
    func testNoBufferContainingDownstreamSpeechIsEverSkipped() {
        let gate = SilenceGate(sampleRate: sourceRate)
        var phase = 0.0
        var droppedSpeechBuffers = 0
        var speechBuffers = 0

        for (kind, seconds) in Self.meetingScript {
            let bufferCount = Int(seconds * sourceRate) / bufferFrames
            for _ in 0..<bufferCount {
                let buffer: [Float]
                switch kind {
                case .silence: buffer = silence(frames: bufferFrames)
                case .speech(let level): buffer = tone(rms: level, frames: bufferFrames, phase: &phase)
                }
                let downstreamWouldHearSpeech =
                    peakFrameRMS(buffer, rate: sourceRate) >= Self.downstreamSpeechThresholdRMS
                let admitted = gate.admit(buffer) != nil
                if downstreamWouldHearSpeech {
                    speechBuffers += 1
                    if !admitted { droppedSpeechBuffers += 1 }
                }
            }
        }

        XCTAssertGreaterThan(speechBuffers, 0, "precondition: the script contains speech")
        XCTAssertEqual(droppedSpeechBuffers, 0,
                       "the gate dropped audio TranscribeKit's VAD would have transcribed")
        XCTAssertEqual(gate.openings, 4, "one opening per burst in the script")
    }

    /// End-to-end through the real downsampler: the 16 kHz stream the gate
    /// produces must still contain every 30 ms frame of speech that the
    /// ungated stream did.
    func testGatedStreamKeepsEveryDownstreamSpeechFrameAt16kHz() throws {
        var phase = 0.0
        let buffers = Self.meetingBuffers(rate: sourceRate, frames: bufferFrames) { kind, frames in
            switch kind {
            case .silence: return self.silence(frames: frames)
            case .speech(let level): return self.tone(rms: level, frames: frames, phase: &phase)
            }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
        let ungatedDownsampler = try PCMDownsampler(sourceFormat: format)
        let gatedDownsampler = try PCMDownsampler(sourceFormat: format)
        let gate = SilenceGate(sampleRate: sourceRate)

        var ungated: [Float] = []
        var gated: [Float] = []
        for mono in buffers {
            ungated.append(contentsOf: ungatedDownsampler.convertMono(mono))
            if let admission = gate.admit(mono) {
                gated.append(contentsOf: gatedDownsampler.convertMono(admission.samples))
            }
        }

        let ungatedSpeech = speechFrameCount(ungated, rate: PCMDownsampler.targetSampleRate)
        let gatedSpeech = speechFrameCount(gated, rate: PCMDownsampler.targetSampleRate)
        XCTAssertGreaterThan(ungatedSpeech, 0)
        // Frame alignment shifts across a gap, so a burst can lose or gain its
        // boundary frame; nothing beyond that may go missing.
        XCTAssertGreaterThanOrEqual(gatedSpeech, ungatedSpeech - gate.openings,
                                    "speech frames disappeared from the gated stream")
        XCTAssertLessThan(gated.count, ungated.count / 2,
                          "…while still converting far less audio")
    }

    private func speechFrameCount(_ samples: [Float], rate: Double) -> Int {
        let frame = Int(rate * Double(Self.frameMilliseconds) / 1000)
        var count = 0
        var index = 0
        while index + frame <= samples.count {
            if rms(samples[index..<(index + frame)]) >= Self.downstreamSpeechThresholdRMS { count += 1 }
            index += frame
        }
        return count
    }

    // MARK: The compute claim

    /// What item 20 is actually worth, MEASURED on the real ingest path:
    /// stereo 48 kHz tap buffers → `PCMConversion` mixdown → `AVAudioConverter`
    /// 48→16 kHz → `[Float]`, which is exactly what `SCKCaptureEngine.ingest`
    /// does per buffer, per channel, for the whole session.
    ///
    /// Printed rather than asserted as a ratio: the honest number depends on
    /// the machine, and the interesting part is the ABSOLUTE size — see the
    /// task notes. The assertion is only the direction, so this cannot go
    /// flaky under load.
    func testCapturePipelineCostBeforeAndAfterTheGate() throws {
        var phase = 0.0
        let buffers = try Self.meetingScript.flatMap { kind, seconds -> [AVAudioPCMBuffer] in
            try (0..<(Int(seconds * sourceRate) / bufferFrames)).map { _ in
                let mono: [Float]
                switch kind {
                case .silence: mono = self.silence(frames: self.bufferFrames)
                case .speech(let level): mono = self.tone(rms: level, frames: self.bufferFrames, phase: &phase)
                }
                return try self.stereoBuffer(mono)
            }
        }
        let audioSeconds = Double(buffers.count * bufferFrames) / sourceRate

        let gate = SilenceGate(sampleRate: sourceRate)
        let before = try measure(buffers: buffers, gate: nil)
        let after = try measure(buffers: buffers, gate: gate)

        let saved = (before - after) / before * 100
        print("""
        ITEM 20 — capture ingest cost over \(String(format: "%.1f", audioSeconds))s of synthetic \
        meeting audio, ONE channel (\(buffers.count) stereo buffers @ \(bufferFrames) frames, 48 kHz):
          before (mixdown + resample everything): \(String(format: "%.1f", before * 1000)) ms \
        = \(String(format: "%.4f", before / audioSeconds * 100))% of one core, real time
          after  (VAD-gated):                     \(String(format: "%.1f", after * 1000)) ms \
        = \(String(format: "%.4f", after / audioSeconds * 100))% of one core, real time
          saved: \(String(format: "%.1f", saved))%   audio skipped: \
        \(String(format: "%.1f", gate.skipRatio * 100))% \
        (\(String(format: "%.1f", Double(gate.skippedSamples) / sourceRate))s of \
        \(String(format: "%.1f", audioSeconds))s never resampled)
        """)
        XCTAssertLessThan(after, before, "gating must cost less than converting everything")
        XCTAssertGreaterThan(gate.skipRatio, 0.5, "a mostly-quiet meeting must mostly skip")
    }

    private func measure(buffers: [AVAudioPCMBuffer], gate: SilenceGate?) throws -> TimeInterval {
        let downsampler = try PCMDownsampler(sourceFormat: buffers[0].format)
        var sink = 0
        let start = Date()
        for buffer in buffers {
            if let gate {
                let mono = downsampler.monoAtSourceRate(buffer)
                guard let admission = gate.admit(mono) else { continue }
                sink += downsampler.convertMono(admission.samples).count
            } else {
                sink += downsampler.convert(buffer).count
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(sink, 0)
        return elapsed
    }

    /// The layout the mic tap and SCK actually deliver: non-interleaved
    /// stereo Float32 at 48 kHz.
    private func stereoBuffer(_ mono: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(mono.count)))
        for channel in 0..<2 {
            for frame in 0..<mono.count { buffer.floatChannelData![channel][frame] = mono[frame] }
        }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        return buffer
    }

    // MARK: Script

    private enum Segment {
        case silence
        case speech(rms: Float)
    }

    /// ~62 s: mostly quiet, four bursts, one of them barely above threshold.
    private static let meetingScript: [(Segment, Double)] = [
        (.silence, 12), (.speech(rms: 0.02), 3),
        (.silence, 8), (.speech(rms: 0.006), 2),      // the quiet system-audio case
        (.silence, 15), (.speech(rms: 0.05), 6),
        (.silence, 10), (.speech(rms: 0.015), 4),
        (.silence, 2),
    ]

    private static func meetingBuffers(rate: Double, frames: Int,
                                       make: (Segment, Int) -> [Float]) -> [[Float]] {
        var out: [[Float]] = []
        for (kind, seconds) in meetingScript {
            for _ in 0..<(Int(seconds * rate) / frames) {
                out.append(make(kind, frames))
            }
        }
        return out
    }
}

private extension Double {
    var float: Float { Float(self) }
}
