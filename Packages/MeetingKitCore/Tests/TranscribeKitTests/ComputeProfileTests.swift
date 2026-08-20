import Persistence
import XCTest
@testable import TranscribeKit

/// Item 24: which Core ML compute units WhisperKit actually gets.
///
/// The point of these is that the answer stays checked. `WhisperKitConfig`
/// used to pass `computeOptions: nil`, which means "whatever WhisperKit's
/// default resolves to on this OS version" — a value that lives in a
/// dependency, behind an `#available(macOS 14.0, ...)` branch, and can change
/// under a version bump without a single line of this repo moving. The engine
/// now resolves it explicitly and these tests pin the two stages that matter.
final class WhisperComputeProfileTests: XCTestCase {

    /// The heavy stages — the audio encoder (once per VAD window over the
    /// full mel) and the text decoder (once per token) — must be allowed on
    /// the Neural Engine. GPU inference for this workload is the expensive
    /// option on battery; the ANE is what makes a long meeting cheap.
    func testEncoderAndDecoderPreferTheNeuralEngine() {
        let profile = WhisperComputeProfile.resolved
        XCTAssertEqual(profile.audioEncoder, .cpuAndNeuralEngine,
                       "audio encoder must be ANE-eligible: \(profile.summary)")
        XCTAssertEqual(profile.textDecoder, .cpuAndNeuralEngine,
                       "text decoder must be ANE-eligible: \(profile.summary)")
        XCTAssertTrue(profile.heavyStagesPreferNeuralEngine)
    }

    /// Documents the two stages that are deliberately NOT on the ANE, so a
    /// future change to them is a decision rather than a surprise: the mel
    /// spectrogram is Argmax's GPU default (a few ms of a multi-second
    /// decode) and prefill is a tiny CPU cache fill.
    func testTheRemainingStagesAreTheKnownNonANEDefaults() {
        let profile = WhisperComputeProfile.resolved
        XCTAssertEqual(profile.melSpectrogram, .cpuAndGPU, profile.summary)
        XCTAssertEqual(profile.prefill, .cpuOnly, profile.summary)
    }

    func testUnitsThatAllowTheNeuralEngineAreClassifiedCorrectly() {
        XCTAssertTrue(WhisperComputeProfile.Unit.cpuAndNeuralEngine.allowsNeuralEngine)
        XCTAssertTrue(WhisperComputeProfile.Unit.all.allowsNeuralEngine)
        XCTAssertFalse(WhisperComputeProfile.Unit.cpuAndGPU.allowsNeuralEngine)
        XCTAssertFalse(WhisperComputeProfile.Unit.cpuOnly.allowsNeuralEngine)
    }
}

final class WhisperEngineConfigurationTests: XCTestCase {
    func testDefaultModelAndConfigurationNeverDownloadImplicitly() {
        XCTAssertEqual(WhisperKitEngine.defaultModelName, "large-v3-v20240930_turbo")

        let config = WhisperKitEngine.configuration(
            modelName: WhisperKitEngine.defaultModelName,
            modelFolder: "/tmp/existing-model"
        )
        XCTAssertEqual(config.model, "large-v3-v20240930_turbo")
        XCTAssertEqual(config.modelFolder, "/tmp/existing-model")
        XCTAssertFalse(config.download)
        XCTAssertFalse(config.useBackgroundDownloadSession)
    }

    func testDecodingDetectsLanguagePerWindowWhileRemainingTranscription() {
        let options = WhisperKitEngine.decodingOptions

        XCTAssertEqual(options.task, .transcribe)
        XCTAssertNil(options.language, "no fixed language may prefill multilingual decoding")
        XCTAssertTrue(options.detectLanguage)
        XCTAssertTrue(options.skipSpecialTokens)
    }
}

/// Item 20, downstream half: what the transcription side costs while nobody
/// is speaking. This is the work the capture-side `SilenceGate` removes —
/// with the gate in place these chunks never arrive at all.
///
/// Measured, not asserted: the number is printed so the compute claim can be
/// argued from data. The assertion is only that silence emits nothing, which
/// is the pre-existing VAD guarantee this must not break.
final class IdleChannelCostTests: XCTestCase {

    func testCostOfPushingSilenceThroughAChannelWorker() async {
        let engine = FakeEngine()
        engine.respond = { _ in [WhisperHypothesis(text: "unexpected", startSeconds: 0, endSeconds: 1)] }
        let transcriber = WhisperKitTranscriber(engine: engine)
        let (continuation, collector, task) = makePipeline(transcriber)

        let seconds = 60.0
        let start = Date()
        Samples.feed(Samples.silenceChunk, seconds: seconds, startingAt: 0,
                     channel: .local, into: continuation)
        continuation.finish()
        await task.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(collector.count, 0, "silence must still emit nothing")
        print("""
        ITEM 20 — TranscribeKit idle cost: \(String(format: "%.1f", elapsed * 1000)) ms to push \
        \(Int(seconds))s of silence (600 chunks) through one ChannelWorker \
        = \(String(format: "%.4f", elapsed / seconds * 100))% of one core, real time. \
        With the capture-side gate this work does not happen at all.
        """)
    }
}
