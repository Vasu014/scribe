import AVFAudio
import Foundation

/// Pure PCM conversion helpers (SPEC §4.1: both capture streams land at
/// 16 kHz mono Float32 before anything downstream sees them).
///
/// Everything in this file is engine-free and hardware-free: it operates on
/// `AVAudioPCMBuffer` values alone, so it is unit-testable headless
/// (`Tests/CaptureKitTests/PCMConversionTests.swift`). The SCK/AVAE classes
/// (`SCKCaptureEngine`) deliberately get NO unit tests — hardware + TCC —
/// and stay thin behind the `CaptureEngine` protocol.
public enum PCMConversion {

    /// Mono mixdown of a Float32 `AVAudioPCMBuffer`: averages all channels.
    ///
    /// Handles both channel layouts real capture produces:
    /// - non-interleaved (AVAudioEngine taps and ScreenCaptureKit audio both
    ///   typically deliver non-interleaved Float32, often 48 kHz stereo),
    /// - interleaved (some HAL paths).
    ///
    /// Mono input passes through unchanged. Returns `[]` for empty buffers
    /// or non-Float32 formats — the caller drops the buffer (a skipped
    /// ~21 ms slice beats poisoning the transcript stream with garbage).
    public static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return [] }

        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return [] }

        // Mono fast path (also the layout of every buffer this module emits).
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        }

        var mixed = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)

        if buffer.format.isInterleaved {
            // One buffer, frames laid out L R L R … — pointer math, no copies.
            let interleaved = UnsafeBufferPointer(start: channelData[0], count: frames * channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += interleaved[frame * channels + channel]
                }
                mixed[frame] = sum * scale
            }
        } else {
            // One pointer per channel; accumulate channel-wise (cache-friendly).
            for channel in 0..<channels {
                let src = UnsafeBufferPointer(start: channelData[channel], count: frames)
                for frame in 0..<frames { mixed[frame] += src[frame] }
            }
            for frame in 0..<frames { mixed[frame] *= scale }
        }
        return mixed
    }
}

/// Error thrown when a source format cannot be wrapped in an `AVAudioConverter`
/// (e.g. compressed formats — SCK/AVAE PCM capture never produces these).
public enum PCMConversionError: Error, Equatable, Sendable {
    case unsupportedSourceFormat(String)
}

/// Streaming resampler to the fixed capture output format: **16 kHz mono
/// Float32** (SPEC §4.1). One instance per source stream (mic HW format,
/// SCK stream format) — `AVAudioConverter` is not thread-safe, so each
/// instance must be confined to a single queue (the engine confines them to
/// its serial processing queue).
///
/// Channel reduction happens HERE, explicitly: `AVAudioConverter`'s default
/// stereo→mono behavior is to select channel 0 (verified empirically against
/// the macOS 26 SDK), which would silently drop the right channel of system
/// audio. We pre-mix to mono by averaging (`PCMConversion.monoSamples`) and
/// then rate-convert mono→mono — deterministic on every OS.
public final class PCMDownsampler: @unchecked Sendable {

    /// The capture output sample rate every downstream consumer
    /// (`CapturedSample`, TranscribeKit input) is pinned to (SPEC §4.1).
    public static let targetSampleRate: Double = 16_000

    /// Format this instance was built from (used to detect mid-session
    /// source-format changes and rebuild).
    public let sourceFormat: AVAudioFormat

    /// The fixed 16 kHz mono Float32 output format.
    public let outputFormat: AVAudioFormat

    private let converter: AVAudioConverter

    /// Mono sibling of `sourceFormat` (same rate, 1 channel) — the stage the
    /// explicit mixdown feeds into before rate conversion.
    private let monoSourceFormat: AVAudioFormat

    /// Reusable mono scratch buffer at the source rate (grown on demand).
    /// Queue-confined like the rest of this object's mutable state.
    private var scratch: AVAudioPCMBuffer?

    /// - Throws: `PCMConversionError.unsupportedSourceFormat` if no converter
    ///   exists for the source format.
    public init(sourceFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: Self.targetSampleRate, channels: 1),
              let monoSource = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: monoSource, to: target) else {
            throw PCMConversionError.unsupportedSourceFormat(sourceFormat.description)
        }
        self.sourceFormat = sourceFormat
        self.outputFormat = target
        self.monoSourceFormat = monoSource
        self.converter = converter
    }

    /// True when this instance can process buffers in `format` — i.e. the
    /// sample rate / channel count / interleaving match what it was built
    /// from. The engine rebuilds its per-channel downsampler when this fails
    /// (device switch changed the mic's HW format, SCK renegotiated).
    public func accepts(format: AVAudioFormat) -> Bool {
        sourceFormat.sampleRate == format.sampleRate
            && sourceFormat.channelCount == format.channelCount
            && sourceFormat.isInterleaved == format.isInterleaved
    }

    /// Converts one input buffer to target-rate mono `[Float]`.
    ///
    /// Pipeline: average-mixdown to mono at the source rate (see class doc)
    /// → rate conversion to 16 kHz. Streaming semantics: rate converters keep
    /// a short history, so a call may return slightly fewer samples than
    /// `frames × ratio`; the tail surfaces in subsequent calls (or via
    /// `flush()` at end of stream).
    public func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        guard input.frameLength > 0 else { return [] }

        // Stage 1: explicit mono mixdown at the source rate.
        let mono = PCMConversion.monoSamples(from: input)
        guard !mono.isEmpty,
              let scratch = scratchBuffer(frameCount: mono.count) else { return [] }
        _ = mono.withUnsafeBufferPointer { source in
            memcpy(scratch.floatChannelData![0], source.baseAddress!, mono.count * MemoryLayout<Float>.size)
        }
        scratch.frameLength = AVAudioFrameCount(mono.count)

        // Stage 2: mono → 16 kHz mono rate conversion.
        let ratio = Self.targetSampleRate / scratch.format.sampleRate
        let capacity = AVAudioFrameCount((Double(scratch.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return scratch
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return PCMConversion.monoSamples(from: out)
        default: // .noDataNow (nothing produced) or .error — drop the slice
            return []
        }
    }

    /// Returns the mono scratch buffer, growing it if this input is longer
    /// than anything seen before.
    private func scratchBuffer(frameCount: Int) -> AVAudioPCMBuffer? {
        if let scratch, Int(scratch.frameCapacity) >= frameCount { return scratch }
        guard let grown = AVAudioPCMBuffer(
            pcmFormat: monoSourceFormat,
            frameCapacity: AVAudioFrameCount(max(4096, frameCount))) else { return nil }
        scratch = grown
        return grown
    }

    /// Drains the converter's held-back tail at end of stream. The engine
    /// does not call this per buffer; it exists so the streaming contract is
    /// complete (and testable) — 16 kHz Whisper chunks tolerate a few held
    /// frames between calls without it.
    public func flush() -> [Float] {
        var collected: [Float] = []
        while let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) {
            let status = converter.convert(to: out, error: nil) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            collected.append(contentsOf: PCMConversion.monoSamples(from: out))
            // Drain until the converter yields nothing more / errors.
            if out.frameLength == 0 || status == .error { return collected }
        }
        return collected
    }
}
