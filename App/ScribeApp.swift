import AppKit
import CaptureKit
import FusionKit
import Persistence
import SessionKit
import TranscribeKit
import os

/// Scribe — menu bar app shell (SPEC §3.1: thin App target; all domain logic
/// lives in Packages/MeetingKitCore).
///
/// App wiring lives in exactly one place (here): store, coordinator
/// (SessionKit — the composition root), menu bar, Settings, and the global
/// hotkey. Components communicate ONLY through the store (SPEC §3.1
/// load-bearing rule); nothing here routes module-to-module.
@main
final class ScribeApp: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.example.scribe", category: "app")

    private var coordinator: SessionCoordinator!
    private var menuBarController: MenuBarController!
    private var settingsWindowController: SettingsWindowController!
    private var hotkey: GlobalHotkey?
    private var eventTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MARK: Store — on-disk by default, in-memory fallback.
        // A locked/corrupt store must not take the whole menu bar app down;
        // an in-memory store keeps the app usable for this launch at the cost
        // of nothing surviving a quit. The fallback is logged loudly because
        // it silently sacrifices SPEC §4.4's persistence guarantees.
        let store: MeetingStore
        do {
            store = try MeetingStore.openDefault()
        } catch {
            logger.fault("""
            Default store failed to open (\(String(describing: error), privacy: .public)); \
            falling back to an in-memory store — sessions will NOT persist this launch.
            """)
            do {
                store = try MeetingStore.inMemory()
            } catch {
                logger.fault("""
                In-memory store also failed (\(String(describing: error), privacy: .public)); \
                nothing can run. Terminating.
                """)
                NSApp.terminate(nil)
                return
            }
        }

        // MARK: Coordinator (SPEC §4.4).
        // TODO(T8): replace StubCaptureEngine with SCKCaptureEngine and
        // UnimplementedTranscriber with the WhisperKit transcriber during
        // setup-wizard wiring. The stubs keep the full lifecycle — start,
        // stop, fusion, retry, crash recovery — exercisable meanwhile.
        let keychain = KeychainStore()
        let provider = AnthropicFusionProvider(keychain: keychain)
        let lookback = SettingsKeys.lookback // launch-time read; see SettingsKeys docs
        let fusionRunner = SessionCoordinator.defaultFusionRunner(
            store: store,
            provider: provider,
            lookback: lookback
        )
        coordinator = SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: UnimplementedTranscriber(),
            lookback: lookback,
            fusionRunner: fusionRunner
        )

        // MARK: Surfaces.
        settingsWindowController = SettingsWindowController()
        menuBarController = MenuBarController(coordinator: coordinator)
        menuBarController.onOpenSettings = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }
        // History is T7; until then done-state clicks no-op (the closure
        // stays nil by design — MenuBarController treats nil as a no-op).
        // menuBarController.onOpenHistory = { sessionId in … }

        // MARK: Global hotkey ⌥⌘N (SPEC §5: Carbon RegisterEventHotKey; no
        // NSEvent global monitors, no Accessibility permission).
        hotkey = GlobalHotkey()
        // TODO(T6): hotkey?.onSummon = { [weak scratchpadPanel] in … toggle … }

        // MARK: Coordinator events (app-level log; menu bar renders states,
        // History T7 will surface findings/failures/recovery in UI).
        let coordinator: SessionCoordinator = coordinator
        eventTask = Task { [coordinator] in
            for await event in coordinator.events() {
                switch event {
                case .stateChanged:
                    break // rendered by MenuBarController
                case .recoveredSessions(let sessions):
                    logger.warning("""
                    Crash recovery (SPEC §4.4): \(sessions.count) session(s) found interrupted \
                    and marked recovered — fusion retry from History once T7 lands.
                    """)
                case .deviceEventLogged(let event):
                    logger.info("Device event logged: \(event.kind, privacy: .public) @ \(event.offset, privacy: .public)s")
                case .fusionFindings(let sessionId, let findings):
                    logger.warning("""
                    Validator findings (SPEC §4.5) on \(sessionId.uuidString, privacy: .public): \
                    \(findings.count) citation(s) flagged.
                    """)
                case .fusionFailed(let sessionId, let message):
                    logger.error("""
                    Fusion failed on \(sessionId.uuidString, privacy: .public): \
                    \(message, privacy: .public) — Retry available.
                    """)
                }
            }
        }

        // MARK: Interruptions → coordinator (SPEC §4.4: sleep/wake pauses and
        // resumes capture; the session clock keeps running through sleep).
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak coordinator] _ in
                coordinator?.handleSleep()
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak coordinator] _ in
                coordinator?.handleWake()
            },
        ]
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
