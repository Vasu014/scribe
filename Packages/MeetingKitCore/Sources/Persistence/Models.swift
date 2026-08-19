import Foundation
import GRDB

// MARK: - Enums (storage vocabulary lives here — everything converges on Persistence)

public enum Channel: String, Codable, Equatable, Sendable {
    case local   // me (mic)
    case remote  // them (system audio)
}

extension Channel: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Channel? {
        guard let raw = String.fromDatabaseValue(dbValue) else { return nil }
        return Channel(rawValue: raw)
    }
}

public enum SessionState: String, Codable, Equatable, Sendable {
    case recording
    case processing
    case complete
}

extension SessionState: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> SessionState? {
        guard let raw = String.fromDatabaseValue(dbValue) else { return nil }
        return SessionState(rawValue: raw)
    }
}

/// A device-interruption event logged on the session timeline (SPEC §4.1).
/// Stored as a JSON array in `sessions.device_events`.
public struct DeviceEvent: Codable, Equatable, Sendable {
    public let kind: String        // e.g. "deviceChanged", "sleep", "wake", "scStreamRestart"
    public let offset: TimeInterval // session-clock offset
    public let at: Date

    public init(kind: String, offset: TimeInterval, at: Date = Date()) {
        self.kind = kind
        self.offset = offset
        self.at = at
    }
}

// MARK: - Records (schema v1, SPEC §4.6)

public struct SessionRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sessions"

    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var state: SessionState
    public var recovered: Bool
    public var title: String?
    /// JSON-encoded [DeviceEvent]; opaque to the store, owned by CaptureKit/SessionKit.
    public var deviceEvents: String
    /// Why the LAST fusion attempt failed (SPEC §4.5: failures leave the
    /// session in `processing` with Retry), or `nil` when the last attempt
    /// stored a note.
    ///
    /// Persisted (schema v2) because `processing` alone cannot tell a session
    /// that is still fusing apart from one that failed permanently. Held only
    /// in memory, the reason died with the process: after a relaunch a
    /// failed session rendered as "fusing" with a live spinner forever, with
    /// no error text and nothing to act on. Written by `SessionCoordinator`
    /// when it applies a fusion outcome; cleared when a later attempt
    /// succeeds, so a fixed session never shows a stale error.
    public var fusionErrorMessage: String?
    /// When `fusionErrorMessage` was recorded; `nil` whenever it is `nil`.
    public var fusionFailedAt: Date?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        state: SessionState = .recording,
        recovered: Bool = false,
        title: String? = nil,
        deviceEvents: String = "[]",
        fusionErrorMessage: String? = nil,
        fusionFailedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.recovered = recovered
        self.title = title
        self.deviceEvents = deviceEvents
        self.fusionErrorMessage = fusionErrorMessage
        self.fusionFailedAt = fusionFailedAt
    }

    public var deviceEventList: [DeviceEvent] {
        (try? JSONDecoder().decode([DeviceEvent].self, from: Data(deviceEvents.utf8))) ?? []
    }
}

/// Transcript segment. UPSERT on `id` is a hard rule (SPEC §4.2):
/// the UUID is assigned at first hypothesis and is stable across revisions —
/// a revised hypothesis replaces the row, never appends.
public struct SegmentRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "segments"

    public var id: UUID
    public var sessionId: UUID
    public var channel: Channel
    public var text: String
    public var startOffset: TimeInterval
    public var endOffset: TimeInterval
    public var isFinal: Bool
    public var inferredAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        channel: Channel,
        text: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isFinal: Bool = false,
        inferredAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.channel = channel
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.isFinal = isFinal
        self.inferredAt = inferredAt
        self.createdAt = createdAt
    }
}

/// Scratchpad fragment. The pending-row pattern (SPEC §4.3) means an
/// in-progress fragment exists as a mutable row upserted on ~1 s debounce;
/// the burst boundary freezes it (from then on it is treated as immutable).
public struct FragmentRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "fragments"

    public var id: UUID
    public var sessionId: UUID
    public var text: String
    /// Session clock at burst START (not the effective anchor —
    /// the lookback subtraction is fusion-time only, SPEC §4.3).
    public var anchorOffset: TimeInterval
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        anchorOffset: TimeInterval,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.anchorOffset = anchorOffset
        self.createdAt = createdAt
    }
}

/// Fused notes. Multiple notes per session are intentional: every fusion
/// attempt is kept, latest is canonical (SPEC §4.6).
public struct NoteRecord: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "notes"

    public var id: UUID
    public var sessionId: UUID
    public var markdown: String
    public var model: String
    /// Covers prompt text AND canonical rendering format (SPEC §4.5) —
    /// do not change the formatter without bumping this.
    public var promptVersion: String
    public var isCanonical: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        markdown: String,
        model: String,
        promptVersion: String,
        isCanonical: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.markdown = markdown
        self.model = model
        self.promptVersion = promptVersion
        self.isCanonical = isCanonical
        self.createdAt = createdAt
    }
}
