import CoreML
import Foundation
import os
import WhisperKit

/// One hypothesis line from a Whisper decode of a single VAD window.
/// Offsets are in seconds RELATIVE to the window buffer (SPEC §4.2: the
/// `Transcriber` layer converts them to session offsets).
public struct WhisperHypothesis: Sendable, Equatable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(text: String, startSeconds: Double, endSeconds: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Narrow seam over WhisperKit so the rest of the module — and every test —
/// never imports WhisperKit directly (SPEC §4.2). Inputs are 16 kHz mono
/// Float32 PCM (SPEC §4.1 format contract from CaptureKit).
public protocol WhisperEngine: Sendable {
    /// Batch-transcribes one VAD window. Returns the hypothesis lines for
    /// that buffer (possibly empty when nothing intelligible was found).
    func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis]
}

/// Resolved Core ML compute-unit preference, per Whisper model stage.
///
/// ITEM 24 (ANE preference). WhisperKit takes `MLComputeUnits` per stage via
/// `ModelComputeOptions`; `WhisperKitConfig.computeOptions == nil` means
/// `WhisperKit` builds a default one (`WhisperKit.swift`:
/// `modelCompute = config.computeOptions ?? ModelComputeOptions()`).
///
/// What that default actually resolves to on this app's floor (macOS 14+,
/// Apple Silicon, non-simulator) — read from the pinned checkout,
/// `Sources/WhisperKit/Core/Models.swift:100-123`:
///
/// | stage           | default              | on the ANE? |
/// |-----------------|----------------------|-------------|
/// | melSpectrogram  | `.cpuAndGPU`         | no          |
/// | audioEncoder    | `.cpuAndNeuralEngine`| YES (macOS 14+ branch) |
/// | textDecoder     | `.cpuAndNeuralEngine`| YES         |
/// | prefill         | `.cpuOnly`           | no (a tiny cache fill) |
///
/// So the two stages that hold ~all the FLOPs — the encoder and the
/// per-token decoder — ALREADY prefer the Neural Engine, which is what the
/// "ANE dispatch 99.86 %" figure from the conversion run reflects. There was
/// nothing to fix; forcing `.cpuAndNeuralEngine` on top would be a no-op, and
/// forcing it on the mel stage would fight an Argmax default chosen because
/// the mel model's ops are GPU-friendlier — for a stage worth a few ms of a
/// multi-second decode.
///
/// This type exists so that stays TRUE rather than assumed: the engine
/// resolves the options explicitly, logs them, and a unit test pins the two
/// heavy stages to the ANE. A WhisperKit upgrade that quietly flips a default
/// (the macOS 14 branch above is exactly that kind of code) then fails a test
/// instead of silently costing battery for a release cycle.
public struct WhisperComputeProfile: Sendable, Equatable {
    public enum Unit: String, Sendable, Equatable {
        case cpuOnly, cpuAndGPU, cpuAndNeuralEngine, all, unknown

        /// True when Core ML is allowed to dispatch this stage to the ANE.
        public var allowsNeuralEngine: Bool {
            self == .cpuAndNeuralEngine || self == .all
        }
    }

    public let melSpectrogram: Unit
    public let audioEncoder: Unit
    public let textDecoder: Unit
    public let prefill: Unit

    public init(melSpectrogram: Unit, audioEncoder: Unit, textDecoder: Unit, prefill: Unit) {
        self.melSpectrogram = melSpectrogram
        self.audioEncoder = audioEncoder
        self.textDecoder = textDecoder
        self.prefill = prefill
    }

    /// The stages that dominate energy use: the encoder runs once per window
    /// over the full mel, the decoder runs once per emitted token.
    public var heavyStagesPreferNeuralEngine: Bool {
        audioEncoder.allowsNeuralEngine && textDecoder.allowsNeuralEngine
    }

    public var summary: String {
        "mel=\(melSpectrogram.rawValue) encoder=\(audioEncoder.rawValue) "
            + "decoder=\(textDecoder.rawValue) prefill=\(prefill.rawValue)"
    }

    /// What `WhisperKitEngine` actually hands to WhisperKit — resolved from
    /// WhisperKit's own defaults, on this machine, without loading a model.
    public static var resolved: WhisperComputeProfile {
        WhisperComputeProfile(WhisperKitEngine.computeOptions)
    }

    init(_ options: ModelComputeOptions) {
        melSpectrogram = Unit(options.melCompute)
        audioEncoder = Unit(options.audioEncoderCompute)
        textDecoder = Unit(options.textDecoderCompute)
        prefill = Unit(options.prefillCompute)
    }
}

extension WhisperComputeProfile.Unit {
    init(_ units: MLComputeUnits) {
        switch units {
        case .cpuOnly: self = .cpuOnly
        case .cpuAndGPU: self = .cpuAndGPU
        case .cpuAndNeuralEngine: self = .cpuAndNeuralEngine
        case .all: self = .all
        @unknown default: self = .unknown
        }
    }
}

/// `WhisperEngine` backed by ONE `WhisperKit` model instance (SPEC §4.2
/// shared-model rule: two model instances ≈ 1 GB RAM + GPU contention are
/// explicitly rejected).
///
/// Being an actor does NOT by itself make concurrent `transcribeBuffer`
/// calls exclusive — actors are reentrant across suspension points, and
/// `whisper.transcribe` suspends. `WhisperKitTranscriber` therefore routes
/// every engine call through its `GatedEngine` (async semaphore, permit 1)
/// before it reaches this type. The actor here just keeps the non-Sendable
/// `WhisperKit` object confined.
public actor WhisperKitEngine: WhisperEngine {
    private let whisper: WhisperKit

    /// Compute-unit preference handed to Core ML (item 24). This is
    /// WhisperKit's own default value, constructed EXPLICITLY rather than
    /// left to `computeOptions: nil`, so the resolved units are observable
    /// (`WhisperComputeProfile.resolved`), logged at load, and pinned by a
    /// test. See `WhisperComputeProfile` for what it resolves to and why no
    /// override is warranted.
    static var computeOptions: ModelComputeOptions { ModelComputeOptions() }

    /// - Parameters:
    ///   - modelName: WhisperKit variant, e.g. `small.en` (user setting, SPEC §4.2).
    ///   - modelFolder: Local folder the model was fetched into
    ///     (`ModelDownloadManager.download` completion URL). `nil` lets
    ///     WhisperKit resolve its default search paths.
    public init(modelName: String = "small.en", modelFolder: String? = nil) async throws {
        let compute = Self.computeOptions
        Logger(subsystem: "io.github.vasu014.scribe", category: "transcriber").info("""
        WhisperKit compute units: \(WhisperComputeProfile(compute).summary, privacy: .public)
        """)
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder,
            computeOptions: compute,
            verbose: false,
            logLevel: .none,
            // WhisperKit performs these stages in order during init. Keeping
            // both explicit avoids a first-decode Core ML compile/load race.
            prewarm: true,
            load: true,
            // Never download implicitly: network fetches happen only through
            // ModelDownloadManager (first-launch setup flow, SPEC §4.2), and a
            // missing model must surface as a load error, not a silent fetch.
            download: false,
            useBackgroundDownloadSession: false
        )
        self.whisper = try await WhisperKit(config)
    }

    public func transcribeBuffer(_ samples: [Float]) async throws -> [WhisperHypothesis] {
        guard !samples.isEmpty else { return [] }
        // In-memory batch API (0.18 single-buffer form of the
        // `transcribe(audioSamples:)`-style entry point; `segmentCallback: nil`
        // disambiguates the overload that returns the sorted result array).
        // SPEC §4.2 no-temp-audio rule: this path is pure in-memory — the only
        // file-based entry points in WhisperKit are the `audioPath(s:)`
        // overloads, which we never call. No cache/temp-write options exist
        // on this API; there is nothing left to disable.
        //
        // `skipSpecialTokens: true` is the ROOT-CAUSE fix for token leakage:
        // WhisperKit's default (`false`) decodes the control tokens
        // (`<|startoftranscript|>`, `<|en|>`, `<|0.00|>`, `<|endoftext|>`…)
        // straight into `TranscriptionSegment.text`. It does not affect
        // `segment.start`/`.end`, which are computed from the timestamp
        // token IDS, so window offsets are unchanged. Everything else stays
        // at WhisperKit's defaults (what `decodeOptions: nil` used).
        let options = DecodingOptions(skipSpecialTokens: true)
        let results = try await whisper.transcribe(
            audioArray: samples,
            decodeOptions: options,
            segmentCallback: nil
        )
        guard let result = results.first else { return [] }
        return result.segments.map { segment in
            WhisperHypothesis(
                // Defensive strip as well as the option above: persisted
                // transcripts must never carry tokens even if a future model
                // or option change slips past `skipSpecialTokens`.
                text: WhisperSpecialTokens.strip(segment.text),
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end)
            )
        }
    }
}
