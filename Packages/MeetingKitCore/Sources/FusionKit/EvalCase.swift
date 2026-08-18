import Foundation
import Persistence

/// Eval-case export model — the PINNED schema of SPEC §4.5 with verbatim key
/// names. Self-contained and versioned so cases survive the originating
/// database being wiped or migrated; `machine_id` makes "does this failure
/// mode cluster on one person's setup?" answerable (SPEC §4.5).
public struct EvalCase: Codable, Equatable, Sendable {

    // MARK: Nested types (pinned JSON shapes)

    /// `{"channel": "me|them", "text": "…", "start_offset": 0.0, "end_offset": 0.0}`.
    public struct TranscriptEntry: Codable, Equatable, Sendable {
        /// "me" (mic) or "them" (system audio).
        public let channel: String
        public let text: String
        public let startOffset: Double
        public let endOffset: Double

        public init(channel: String, text: String, startOffset: Double, endOffset: Double) {
            self.channel = channel
            self.text = text
            self.startOffset = startOffset
            self.endOffset = endOffset
        }

        enum CodingKeys: String, CodingKey {
            case channel, text
            case startOffset = "start_offset"
            case endOffset = "end_offset"
        }
    }

    /// `{"text": "…", "anchor_offset": 0.0}`.
    public struct FragmentEntry: Codable, Equatable, Sendable {
        public let text: String
        public let anchorOffset: Double

        public init(text: String, anchorOffset: Double) {
            self.text = text
            self.anchorOffset = anchorOffset
        }

        enum CodingKeys: String, CodingKey {
            case text
            case anchorOffset = "anchor_offset"
        }
    }

    // MARK: Fields (SPEC §4.5 pinned schema, exact key names)

    /// Pinned schema version — bump only with a deliberate schema change.
    public static let schemaVersionValue = 1

    public let schemaVersion: Int
    public let promptVersion: String
    public let model: String
    public let sessionId: UUID
    /// ISO-8601.
    public let sessionStartedAt: Date
    public let title: String?
    public let transcript: [TranscriptEntry]
    public let fragments: [FragmentEntry]
    /// The fusion output under review (markdown).
    public let output: String
    /// Optional corrected output (markdown), entered at export time.
    public let correctedOutput: String?
    /// Deterministic validator result text (see `validatorResultText`).
    public let validatorResult: String
    /// ISO-8601.
    public let exportedAt: Date
    /// Stable per-install id (see `machineId(defaults:)`).
    public let machineId: String

    public init(
        schemaVersion: Int,
        promptVersion: String,
        model: String,
        sessionId: UUID,
        sessionStartedAt: Date,
        title: String?,
        transcript: [TranscriptEntry],
        fragments: [FragmentEntry],
        output: String,
        correctedOutput: String?,
        validatorResult: String,
        exportedAt: Date,
        machineId: String
    ) {
        self.schemaVersion = schemaVersion
        self.promptVersion = promptVersion
        self.model = model
        self.sessionId = sessionId
        self.sessionStartedAt = sessionStartedAt
        self.title = title
        self.transcript = transcript
        self.fragments = fragments
        self.output = output
        self.correctedOutput = correctedOutput
        self.validatorResult = validatorResult
        self.exportedAt = exportedAt
        self.machineId = machineId
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case promptVersion = "prompt_version"
        case model
        case sessionId = "session_id"
        case sessionStartedAt = "session_started_at"
        case title
        case transcript, fragments
        case output
        case correctedOutput = "corrected_output"
        case validatorResult = "validator_result"
        case exportedAt = "exported_at"
        case machineId = "machine_id"
    }

    /// Custom encode: `corrected_output` is ALWAYS present (explicit null when
    /// unset) — the synthesized path would omit the key, drifting from the
    /// pinned SPEC §4.5 JSON. Decoding accepts both null and missing.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(promptVersion, forKey: .promptVersion)
        try container.encode(model, forKey: .model)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(sessionStartedAt, forKey: .sessionStartedAt)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(fragments, forKey: .fragments)
        try container.encode(output, forKey: .output)
        if let correctedOutput {
            try container.encode(correctedOutput, forKey: .correctedOutput)
        } else {
            try container.encodeNil(forKey: .correctedOutput)
        }
        try container.encode(validatorResult, forKey: .validatorResult)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(machineId, forKey: .machineId)
    }

    // MARK: Builder (History "Export eval case" action, SPEC §4.5)

    /// Builds an eval case from store records. The output under review is the
    /// given note row (`output` / `model` / `prompt_version` all come from
    /// it); `validatorFindings` render into `validator_result`.
    public static func build(
        session: SessionRecord,
        segments: [SegmentRecord],
        fragments: [FragmentRecord],
        note: NoteRecord,
        validatorFindings: [NotesValidator.Finding] = [],
        correctedOutput: String? = nil,
        exportedAt: Date = Date(),
        machineId: String = EvalCase.machineId()
    ) -> EvalCase {
        EvalCase(
            schemaVersion: schemaVersionValue,
            promptVersion: note.promptVersion,
            model: note.model,
            sessionId: session.id,
            sessionStartedAt: session.startedAt,
            title: session.title,
            transcript: segments
                .sorted { ($0.startOffset, $0.id.uuidString) < ($1.startOffset, $1.id.uuidString) }
                .map {
                    TranscriptEntry(
                        channel: channelToken($0.channel),
                        text: $0.text,
                        startOffset: $0.startOffset,
                        endOffset: $0.endOffset
                    )
                },
            fragments: fragments
                .sorted { ($0.anchorOffset, $0.id.uuidString) < ($1.anchorOffset, $1.id.uuidString) }
                .map { FragmentEntry(text: $0.text, anchorOffset: $0.anchorOffset) },
            output: note.markdown,
            correctedOutput: correctedOutput,
            validatorResult: validatorResultText(validatorFindings),
            exportedAt: exportedAt,
            machineId: machineId
        )
    }

    /// Channel → eval-case token: `.local` → "me", `.remote` → "them".
    public static func channelToken(_ channel: Channel) -> String {
        channel == .local ? "me" : "them"
    }

    /// `validator_result` text: "pass" when clean, otherwise one line per
    /// finding. Deterministic — the shared corpus greps it (SPEC §9).
    public static func validatorResultText(_ findings: [NotesValidator.Finding]) -> String {
        findings.isEmpty
            ? "pass"
            : findings.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: "\n")
    }

    // MARK: Machine id

    private static let machineIdDefaultsKey = "com.example.scribe.machine-id"

    /// Stable per-install id: a UUID generated once and persisted to
    /// UserDefaults (SPEC §4.5 `machine_id`). `defaults` is injectable so
    /// tests never touch the real defaults domain.
    public static func machineId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: machineIdDefaultsKey) {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: machineIdDefaultsKey)
        return generated
    }

    // MARK: Coding (self-contained files for the shared evals/ folder)

    /// Canonical encoder for exported eval-case JSON: ISO-8601 dates, sorted
    /// keys, pretty-printed. The weekly merge (SPEC §9) reads this shape.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Canonical decoder (ISO-8601 dates).
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Convenience: encode via `makeEncoder` for the evals/ drop.
    public func encodedJSON() throws -> Data {
        try EvalCase.makeEncoder().encode(self)
    }
}
