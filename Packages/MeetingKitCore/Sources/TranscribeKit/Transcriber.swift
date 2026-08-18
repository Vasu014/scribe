import Foundation
import Persistence

/// A chunk of 16 kHz mono Float32 PCM with a session-clock offset (SPEC §4.1).
public struct AudioChunk: Sendable {
    public let channel: Channel
    /// Offset from session start on the monotonic session clock.
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

/// Streaming-style transcription seam. WhisperKit is chunked batch over
/// rolling VAD windows, not true streaming — this protocol hides that (SPEC §4.2).
public protocol Transcriber: Sendable {
    func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment>
}

public struct TranscriptSegment: Sendable, Equatable {
    /// Assigned at FIRST hypothesis; stable across revisions. This is the
    /// upsert key — never regenerate it for a revised hypothesis (SPEC §4.2).
    public let id: UUID
    public let channel: Channel
    public let text: String
    /// Session-clock relative (audio time).
    public let startOffset: TimeInterval
    public let endOffset: TimeInterval
    /// Streaming hypotheses may revise; final = settled.
    public let isFinal: Bool
    /// Wall-clock inference completion time. Kept separate from audio offsets
    /// so Phase 2 live-notes starts with a real latency distribution (SPEC §4.2).
    public let inferredAt: Date

    public init(
        id: UUID = UUID(),
        channel: Channel,
        text: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isFinal: Bool = false,
        inferredAt: Date = Date()
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.isFinal = isFinal
        self.inferredAt = inferredAt
    }

    public func toRecord(sessionId: UUID) -> SegmentRecord {
        SegmentRecord(
            id: id,
            sessionId: sessionId,
            channel: channel,
            text: text,
            startOffset: startOffset,
            endOffset: endOffset,
            isFinal: isFinal,
            inferredAt: inferredAt
        )
    }
}

/// Placeholder engine so App/UI development proceeds before Spike 2 lands
/// the WhisperKit implementation (shared model instance, two serial queues).
public struct UnimplementedTranscriber: Transcriber {
    public init() {}

    public func transcribe(stream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptSegment> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in stream {
                    // Consume; emit nothing. WhisperKitTranscriber replaces this (Spike 2, §7).
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
