import Foundation

/// FragmentComposer implements the pending-row persistence pattern (SPEC §4.3):
///
/// - The in-progress fragment exists as a MUTABLE row in the store, upserted
///   on a ~1 s typing debounce — the debounce IS the persistence, so a crash
///   loses at most ~1 s of typing.
/// - A burst boundary (≥3 s pause or explicit newline) FREEZES the row into a
///   committed fragment.
/// - The UI "Saved" tick fires on actual persist callbacks, never on a schedule.
///
/// Time is injected (`at:` parameters on a session-clock timeline) so the
/// composer is unit-testable without timers. The panel drives it with:
///   NSTextViewTextDidChange → edit(_:at:)
///   newline → newline(at:)
///   100 ms heartbeat → heartbeat(at:)
///
/// All mutable state is guarded by `lock`; callbacks are set once at setup,
/// before any input arrives. `@unchecked Sendable` is deliberate.
public final class FragmentComposer: @unchecked Sendable {

    public struct Config: Sendable {
        /// Debounce for pending-row upserts (SPEC: ~1 s).
        public var persistDebounce: TimeInterval = 1.0
        /// Typing pause that ends a burst (SPEC: ≥3 s).
        public var burstPause: TimeInterval = 3.0

        public init(persistDebounce: TimeInterval = 1.0, burstPause: TimeInterval = 3.0) {
            self.persistDebounce = persistDebounce
            self.burstPause = burstPause
        }
    }

    /// Pending-row upsert. `(text, anchorOffset)` — anchorOffset is the burst
    /// start on the session clock. The caller maps this to a stable row id
    /// (same id re-upserted until freeze).
    public var onPersistPending: (@Sendable (String, TimeInterval) -> Void)?
    /// Burst frozen: committed fragment with `(text, anchorOffset)`.
    public var onFreeze: (@Sendable (String, TimeInterval) -> Void)?

    private let config: Config
    private let lock = NSLock()
    private var pendingText: String = ""
    private var anchor: TimeInterval?
    private var lastEditAt: TimeInterval = 0
    private var lastPersistAt: TimeInterval = -.greatestFiniteMagnitude
    private var hasUnpersistedEdits = false

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: Inputs

    /// Full text of the scratchpad body at this moment (the composer does not
    /// diff; the panel owns the text view and passes the current text).
    public func edit(_ text: String, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Nothing typed / user cleared: no pending row to keep.
            return
        }
        if anchor == nil {
            // First edit of a burst — burst start becomes the anchor (SPEC §4.3).
            anchor = now
        }
        pendingText = trimmed
        lastEditAt = now
        hasUnpersistedEdits = true
        tryPersist(now)
    }

    /// Explicit newline freezes the burst immediately.
    public func newline(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard anchor != nil, !pendingText.isEmpty else { return }
        tryPersist(now)
        freeze()
    }

    /// Drive from a ~100 ms heartbeat. Handles the trailing persist (debounce)
    /// and the ≥3 s pause boundary.
    public func heartbeat(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard let anchor else { return }

        if hasUnpersistedEdits, now - lastEditAt >= config.persistDebounce {
            tryPersist(now)
        }
        if !pendingText.isEmpty, now - lastEditAt >= config.burstPause {
            freeze()
        }
        _ = anchor // silence unused-var path when pendingText is empty
    }

    /// Flush at session stop: persist + freeze whatever is pending.
    public func flush(at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard anchor != nil, !pendingText.isEmpty else { return }
        tryPersist(now, force: true)
        freeze()
    }

    // MARK: Internals

    private func tryPersist(_ now: TimeInterval, force: Bool = false) {
        guard hasUnpersistedEdits else { return }
        guard force || now - lastPersistAt >= config.persistDebounce else { return }
        guard let anchor else { return }
        lastPersistAt = now
        hasUnpersistedEdits = false
        onPersistPending?(pendingText, anchor)
    }

    private func freeze() {
        guard let anchor else { return }
        let text = pendingText
        self.anchor = nil
        pendingText = ""
        hasUnpersistedEdits = false
        guard !text.isEmpty else { return }
        onFreeze?(text, anchor)
    }
}
