import AppKit
import CaptureKit
import FusionKit
import Persistence
import ScratchpadKit
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
@MainActor
@main
final class ScribeApp: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "com.example.scribe", category: "app")

    private var coordinator: SessionCoordinator!
    private var composer: FragmentComposer!
    private var menuBarController: MenuBarController!
    private var scratchpadPanel: ScratchpadPanelController!
    private var settingsWindowController: SettingsWindowController!
    private var historyWindowController: HistoryWindowController!
    private var setupWizardController: SetupWizardController?
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

        // MARK: Coordinator (SPEC §4.4) + real engines (T8).
        // SCKCaptureEngine is the production capture path (voice processing
        // on by default, SPEC §4.1); the stub stays available behind the
        // `debugUseStubCapture` UserDefaults flag for UI development
        // without TCC prompts. Transcription is real too —
        // LazyWhisperKitTranscriber loads the persisted model LAZILY at the
        // first session start (model load is slow; the menu bar must not
        // wait for it) and falls back to UnimplementedTranscriber + a log
        // when the model folder is missing (the wizard normally prevents
        // that).
        let useStubCapture = UserDefaults.standard.bool(forKey: SettingsKeys.debugUseStubCapture)
        let captureEngine: any CaptureEngine
        if useStubCapture {
            logger.info("debugUseStubCapture = true — StubCaptureEngine active (UI development, no TCC).")
            captureEngine = StubCaptureEngine()
        } else {
            captureEngine = SCKCaptureEngine()
        }
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
            captureEngine: captureEngine,
            transcriber: LazyWhisperKitTranscriber(),
            lookback: lookback,
            fusionRunner: fusionRunner
        )

        // MARK: Engine callbacks (SPEC §4.1).
        // Device switches are rebuilt INSIDE the engine; the coordinator's
        // handleDeviceChange() logs the `deviceChanged` timeline event.
        // Remote degradation (permission revoked / SCStream double failure)
        // degrades to mic-only — logged here.
        // TODO(T9+): surface degradation in UI (menu-bar notice / History row meta).
        if let sckEngine = captureEngine as? SCKCaptureEngine {
            sckEngine.onDeviceChange = { [weak coordinator] in
                coordinator?.handleDeviceChange()
            }
            sckEngine.onRemoteDegraded = { [weak self] reason in
                self?.logger.warning("System audio degraded to mic-only: \(reason, privacy: .public)")
            }
        }

        // MARK: Surfaces.
        settingsWindowController = SettingsWindowController()
        menuBarController = MenuBarController(coordinator: coordinator)
        menuBarController.onOpenSettings = { [weak settingsWindowController] in
            settingsWindowController?.show()
        }
        // Start-flow permission guard (T8): clicking Start with mic or
        // screen TCC missing opens the wizard at the relevant step instead
        // of failing silently. The stub path skips TCC entirely.
        menuBarController.permissionGuardEnabled = !useStubCapture
        menuBarController.onPermissionsMissing = { [weak self] in
            guard let self, let step = SetupWizardPhase.firstMissingPermission else { return }
            self.showSetupWizard(at: step)
        }
        // MARK: Scratchpad panel (SPEC §4.3 + §5).
        // The composer is APP-OWNED; `attach` installs its persist/freeze
        // callbacks on the coordinator (pending-row persistence lives there —
        // the callbacks are coordinator-owned from here on). The panel only
        // drives edit/newline/heartbeat and never touches the callbacks.
        composer = FragmentComposer()
        coordinator.attach(composer)
        scratchpadPanel = ScratchpadPanelController(coordinator: coordinator, composer: composer)
        menuBarController.onOpenScratchpad = { [weak scratchpadPanel] in
            scratchpadPanel?.show()
        }

        // MARK: History window (SPEC §5; T7).
        historyWindowController = HistoryWindowController(store: store, coordinator: coordinator)
        menuBarController.onShowHistory = { [weak historyWindowController] in
            historyWindowController?.show()
        }
        // Menu-bar done-badge click opens that session in History (SPEC §5)
        // — the done event carries the sessionId.
        menuBarController.onOpenHistory = { [weak historyWindowController] sessionId in
            historyWindowController?.show(sessionId: sessionId)
        }

        // MARK: Global hotkey ⌥⌘N (SPEC §5: Carbon RegisterEventHotKey; no
        // NSEvent global monitors, no Accessibility permission).
        hotkey = GlobalHotkey()
        hotkey?.onSummon = { [weak scratchpadPanel] in
            scratchpadPanel?.toggle()
        }

        // MARK: Coordinator events (app-level log; menu bar and History
        // render states — History surfaces findings/failures/recovery as
        // inline warning cards and row meta).
        let coordinator: SessionCoordinator = coordinator
        eventTask = Task { [coordinator] in
            for await event in coordinator.events() {
                switch event {
                case .stateChanged:
                    break // rendered by MenuBarController + History
                case .recoveredSessions(let sessions):
                    logger.warning("""
                    Crash recovery (SPEC §4.4): \(sessions.count) session(s) found interrupted \
                    and marked recovered — fusion retry available from History.
                    """)
                case .deviceEventLogged(let event):
                    logger.info("Device event logged: \(event.kind, privacy: .public) @ \(event.offset, privacy: .public)s")
                case .fusionFindings(let sessionId, let findings):
                    logger.warning("""
                    Validator findings (SPEC §4.5) on \(sessionId.uuidString, privacy: .public): \
                    \(findings.count) citation(s) flagged — surfaced in History notes.
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

        // MARK: First-run setup wizard (T8; SPEC §4.1/§5) — shown after the
        // menu bar is ready. Resumes at the persisted phase (the Screen
        // Recording TCC grant forces a quit-and-reopen, SPEC §4.1); once
        // completed (phase 5) it never shows on launch again.
        if SetupWizardPhase.persisted != .completed {
            showSetupWizard(at: SetupWizardPhase.persisted)
        }
    }

    /// Lazily creates and shows the setup wizard at a step.
    private func showSetupWizard(at step: SetupWizardPhase) {
        if setupWizardController == nil {
            setupWizardController = SetupWizardController()
        }
        setupWizardController?.show(at: step)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
