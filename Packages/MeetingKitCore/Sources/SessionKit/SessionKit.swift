import Foundation
import Persistence

/// SessionKit is the composition root (SPEC §3.1): it wires capture →
/// transcription → store, and drives fusion at session end. Data always flows
/// through the store — SessionKit orchestrates, it never bypasses the rule.
///
/// The SessionCoordinator implementation is a dedicated task (TASKS.md T2);
/// these are the shared vocabulary types the coordinator and App both speak.

/// Derived UI state (SPEC §5): storage states stay `recording | processing |
/// complete` (+ `recovered`); the menu bar and History DERIVE their display
/// states from them at display time. Never add UI-state columns to the schema.
public enum SessionDisplayState: Equatable, Sendable {
    case idle
    /// Core ML is being prewarmed/loaded. Capture has not started and no
    /// recording row exists yet.
    case preparing
    case recording
    /// Fusion in flight (storage `processing`, no canonical note yet).
    case processing
    /// Transient (4 s): green check + "Notes ready" — derived from
    /// `complete` + fusion succeeded. Auto-returns to `idle`.
    case done(sessionId: UUID)
    /// Persistent ⚠ until the menu is opened — derived from `processing`
    /// + last fusion error. Menu gains "Retry Fusion".
    case failed(sessionId: UUID)
}
