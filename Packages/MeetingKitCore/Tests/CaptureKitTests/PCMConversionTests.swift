import AVFAudio
import CoreAudio
import XCTest
@testable import CaptureKit

/// PCMConversion unit tests (T4): pure math, no engine, no hardware, no TCC —
/// the SCK/AVAE classes themselves get NO unit tests by design (SPEC §4.1
/// hardware dependence); the conversion layer is where correctness is testable.
final class PCMConversionTests: XCTestCase {

    // MARK: Helpers

    private func makeMonoBuffer(sampleRate: Double, frameCount: AVAudioFrameCount,
                                fill: (Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        for frame in 0..<Int(frameCount) {
            buffer.floatChannelData![0][frame] = fill(frame)
        }
        buffer.frameLength = frameCount
        return buffer
    }

    private func makeStereoBuffer(sampleRate: Double, frameCount: AVAudioFrameCount,
                                  interleaved: Bool,
                                  fill: (_ frame: Int, _ channel: Int) -> Float) -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if interleaved {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            format = withUnsafePointer(to: &asbd) { AVAudioFormat(streamDescription: $0)! }
        } else {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        for frame in 0..<Int(frameCount) {
            for channel in 0..<2 {
                let value = fill(frame, channel)
                if interleaved {
                    buffer.floatChannelData![0][frame * 2 + channel] = value
                } else {
                    buffer.floatChannelData![channel][frame] = value
                }
            }
        }
        buffer.frameLength = frameCount
        return buffer
    }

    // MARK: monoSamples — mixdown math

    func testMonoInputPassesThrough() {
        let buffer = makeMonoBuffer(sampleRate: 16_000, frameCount: 64) { Float($0) / 64 }
        let mono = PCMConversion.monoSamples(from: buffer)
        XCTAssertEqual(mono.count, 64)
        for frame in 0..<64 {
            XCTAssertEqual(mono[frame], Float(frame) / 64, accuracy: 1e-7)
        }
    }

    func testNonInterleavedStereoMixdown() {
        // SPEC §4.1's "me vs. them" premise: L/R differ, mixdown must average.
        let buffer = makeStereoBuffer(sampleRate: 48_000, frameCount: 32, interleaved: false) { _, channel in
            channel == 0 ? 0.25 : 0.75
        }
        let mono = PCMConversion.monoSamples(from: buffer)
        XCTAssertEqual(mono.count, 32)
        XCTAssertFalse(mono.isEmpty)
        for (index, value) in mono.enumerated() {
            XCTAssertEqual(value, 0.5, accuracy: 1e-6, "frame \(index)")
        }
    }

    func testNonInterleavedStereoMixdownCancels() {
        // R = -L proves channels are summed, not just copied from one side.
        let buffer = makeStereoBuffer(sampleRate: 48_000, frameCount: 16, interleaved: false) { frame, channel in
            channel == 0 ? Float(frame) / 16 : -Float(frame) / 16
        }
        let mono = PCMConversion.monoSamples(from: buffer)
        XCTAssertEqual(mono.count, 16)
        for value in mono { XCTAssertEqual(value, 0, accuracy: 1e-6) }
    }

    func testInterleavedStereoMixdown() {
        let buffer = makeStereoBuffer(sampleRate: 48_000, frameCount: 24, interleaved: true) { _, channel in
            channel == 0 ? -0.5 : 0.5
        }
        XCTAssertTrue(buffer.format.isInterleaved)
        let mono = PCMConversion.monoSamples(from: buffer)
        XCTAssertEqual(mono.count, 24)
        for value in mono { XCTAssertEqual(value, 0, accuracy: 1e-6) }
    }

    func testEmptyBufferYieldsNoSamples() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 0
        XCTAssertTrue(PCMConversion.monoSamples(from: buffer).isEmpty)
    }

    // MARK: PCMDownsampler — 16 kHz target

    func testTargetFormatIs16kMonoFloat32() throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let downsampler = try PCMDownsampler(sourceFormat: source)
        XCTAssertEqual(PCMDownsampler.targetSampleRate, 16_000)
        XCTAssertEqual(downsampler.outputFormat.sampleRate, 16_000)
        XCTAssertEqual(downsampler.outputFormat.channelCount, 1)
        XCTAssertEqual(downsampler.outputFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertTrue(downsampler.accepts(format: source))
        let differentRate = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        XCTAssertFalse(downsampler.accepts(format: differentRate))
    }

    func testDownsample48kTo16kRatioSanity() throws {
        // 1.0 s of 48 kHz mono → ≈ 16_000 samples at 16 kHz (3:1). The
        // converter may hold a short history tail; flush() drains it. Tolerant
        // bounds assert the RATIO, not sample-exact SRC behavior.
        let frames: AVAudioFrameCount = 48_000
        let buffer = makeMonoBuffer(sampleRate: 48_000, frameCount: frames) { frame in
            let t = Double(frame) / 48_000
            return Float(Darwin.sin(2 * .pi * 440 * t)) * 0.8
        }
        let downsampler = try PCMDownsampler(sourceFormat: buffer.format)
        let streamed = downsampler.convert(buffer)
        let tail = downsampler.flush()
        let total = streamed.count + tail.count
        XCTAssertGreaterThan(total, 15_000, "downsampling produced too few samples")
        XCTAssertLessThan(total, 17_000, "downsampling produced too many samples")
    }

    func testDownsampleStreamingContinuity() throws {
        // Two consecutive 0.5 s slices must net ≈ 16_000 total: the converter's
        // held-back history from slice 1 surfaces in slice 2 (streaming, not
        // per-buffer stateless).
        let downsampler = try PCMDownsampler(
            sourceFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        var total = 0
        for _ in 0..<2 {
            let slice = makeMonoBuffer(sampleRate: 48_000, frameCount: 24_000) { _ in 0.5 }
            total += downsampler.convert(slice).count
        }
        total += downsampler.flush().count
        XCTAssertGreaterThan(total, 15_000)
        XCTAssertLessThan(total, 17_000)
    }

    func testDownsamplePreservesDCLevel() throws {
        // A constant (DC) signal must survive rate conversion at the same
        // level — catches accidental scaling/gain bugs. A band-limited SRC
        // filter rings briefly where the DC "steps" out of silence (first
        // samples) and back in at the flush tail, so assert the converged
        // interior: the invariant is steady-state level, not filter ringing.
        let buffer = makeMonoBuffer(sampleRate: 48_000, frameCount: 24_000) { _ in 0.5 }
        let downsampler = try PCMDownsampler(sourceFormat: buffer.format)
        let samples = downsampler.convert(buffer) + downsampler.flush()
        XCTAssertGreaterThan(samples.count, 1_000)
        let margin = 64
        let interior = samples.dropFirst(margin).dropLast(margin)
        XCTAssertGreaterThan(interior.count, 1_000)
        for (index, value) in interior.enumerated() {
            XCTAssertEqual(value, 0.5, accuracy: 0.005, "interior sample \(index)")
        }
    }

    func testSilencePassthrough() throws {
        // Silence in → silence out (both mixdown and downsampler); a single
        // non-zero would poison a "quiet meeting" transcript stream.
        let silent = makeStereoBuffer(sampleRate: 48_000, frameCount: 64, interleaved: false) { _, _ in 0 }
        XCTAssertEqual(PCMConversion.monoSamples(from: silent).count, 64)
        XCTAssertTrue(PCMConversion.monoSamples(from: silent).allSatisfy { $0 == 0 })

        let downsampler = try PCMDownsampler(sourceFormat: silent.format)
        let out = downsampler.convert(silent) + downsampler.flush()
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testStereoSourceDownmixedDuringConversion() throws {
        // The full remote pipeline in miniature: 48 kHz stereo → 16 kHz mono.
        // A signal on ONE channel only lands at half amplitude (channels are
        // averaged, not dropped). Same SRC ring-in/ring-out margins as the DC
        // test — assert the converged interior.
        let buffer = makeStereoBuffer(sampleRate: 48_000, frameCount: 24_000, interleaved: false) { _, channel in
            channel == 0 ? 0.5 : 0
        }
        let downsampler = try PCMDownsampler(sourceFormat: buffer.format)
        let samples = downsampler.convert(buffer) + downsampler.flush()
        XCTAssertGreaterThan(samples.count, 1_000)
        let margin = 64
        let interior = samples.dropFirst(margin).dropLast(margin)
        XCTAssertGreaterThan(interior.count, 1_000)
        for (index, value) in interior.enumerated() {
            XCTAssertEqual(value, 0.25, accuracy: 0.005, "interior sample \(index)")
        }
    }
}
