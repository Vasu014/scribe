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

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "app")

    private var coordinator: SessionCoordinator!
    private var composer: FragmentComposer!
    private var menuBarController: MenuBarController!
    private var scratchpadPanel: ScratchpadPanelController!
    /// Fullscreen-safe recording indicator (design 4a) — shows itself only
    /// while capturing with the status item off screen.
    private var recordingChipController: RecordingChipController!
    private var settingsWindowController: SettingsWindowController!
    private var historyWindowController: HistoryWindowController!
    private var setupWizardController: SetupWizardController?
    /// Sparkle updater (SPEC §6; T9). Held as a property so the
    /// SPUStandardUpdaterController exists before applicationDidFinishLaunching
    /// returns (Sparkle's requirement); started at the end of launch.
    private let updaterManager = UpdaterManager.shared
    private var hotkey: GlobalHotkey?
    private var eventTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Pass-through capture engine that timestamps buffers per channel — the
    /// app's only window onto whether capture is actually alive (SPEC §4.1/§4.4).
    private var captureMonitor: CaptureLivenessMonitor!
    /// Meeting-time warning surface (SPEC §4.1 "surface a warning").
    private var warningBanner: SessionWarningBanner!
    /// Runs only while recording; see `checkCaptureHealth()`.
    private var captureWatchdog: Timer?
    /// When the Mac last woke, so a mic stall that follows a wake can say so.
    private var lastWakeAt: Date?
    /// Cross-process "show yourself" from a surrendering second launch.
    private var summonObserver: NSObjectProtocol?

    /// Cross-process summon (see the single-instance guard). Named off the
    /// bundle id so two different apps never collide on it.
    private static let summonNotification = Notification.Name("io.github.vasu014.scribe.summonScratchpad")

    /// Another live instance of this app, if any. Matches on BUNDLE ID, not
    /// path: the whole point is catching a DerivedData build and an
    /// /Applications copy at the same time.
    private static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // MARK: UI gallery (dev tooling; App/UIGallery.swift).
        // `-uiGallery YES` runs the screenshot gallery INSTEAD of the app:
        // fixture store, every surface opened as its own window, window
        // numbers on stdout for scripts/ui-gallery.sh. Nothing below runs —
        // no wizard, no Sparkle, no capture engine, no TCC prompts.
        if UIGallery.isEnabled {
            UIGallery.run()
            return
        }

        // MARK: Single instance (SPEC §3.1 — one store, one capture session).
        // Nothing about a menu bar app makes a second copy obvious: it is
        // LSUIElement, so a second launch shows no window and no Dock
        // bounce, just a SECOND status item — and two Scribes then share one
        // SQLite store and one microphone while each believes it owns the
        // session. Dogfooding produced exactly that (a build from
        // DerivedData alongside /Applications/Scribe.app).
        //
        // The NEWCOMER surrenders: the older instance may be holding a live
        // recording, and killing it to make room would destroy a meeting. It
        // is asked to show its scratchpad first, so the double launch has
        // visible feedback instead of silently doing nothing.
        if let running = Self.otherRunningInstance() {
            logger.fault("""
            Another Scribe instance is already running (pid \(running.processIdentifier, privacy: .public), \
            \(running.bundleURL?.path ?? "unknown bundle", privacy: .public)) — this launch is surrendering \
            so the two do not share the store and the microphone.
            """)
            DistributedNotificationCenter.default().postNotificationName(
                Self.summonNotification, object: nil, userInfo: nil, deliverImmediately: true
            )
            NSApp.terminate(nil)
            return
        }

        // MARK: Store — on disk, or not at all (SPEC §4.4).
        //
        // There used to be a `MeetingStore.inMemory()` fallback here, taken
        // whenever the on-disk store failed to open or migrate, announced by
        // one `os_log` fault and nothing else. It is the worst defect this
        // app has carried: every surface then behaved NORMALLY — the menu bar
        // counted up, the scratchpad ticked "Saved", History listed the row
        // and the fused notes — and the entire meeting evaporated at quit,
        // with History empty on the next launch. SPEC §4.4 is explicit
        // ("segments and fragments hit SQLite within 5 s of finalization —
        // NEVER memory-only"), and a persistence guarantee that silently
        // downgrades itself is worse than no app at all, because the user
        // cannot detect the loss until the data is already gone.
        //
        // So there is no degraded mode. If the store cannot be opened the
        // user is told in a blocking alert BEFORE any recording UI exists,
        // and is offered the one recovery that fixes the common cause (a
        // corrupt or half-migrated database) without destroying anything:
        // rename the file aside and start fresh.
        //
        // "Refuse to run" beat "run with recording disabled" because with the
        // store shut there is nothing left to run FOR: History, notes,
        // fragments and the crash-recovery scan all read through this one
        // handle, so a Scribe that cannot open it has no working surface —
        // only a menu bar item that lies about being ready.
        guard let store = openStoreOrExplain() else { return }

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
        let baseCaptureEngine: any CaptureEngine
        if useStubCapture {
            logger.info("debugUseStubCapture = true — StubCaptureEngine active (UI development, no TCC).")
            baseCaptureEngine = StubCaptureEngine()
        } else {
            baseCaptureEngine = SCKCaptureEngine()
        }
        // The coordinator is handed a MONITORED engine, not the raw one: the
        // monitor timestamps every buffer per channel on its way through, which
        // is the only liveness signal the app can get out of `CaptureEngine`
        // (the protocol has no health, pause or resume surface — see
        // `checkCaptureHealth()`). It is a pass-through decorator: `onAudio`,
        // `start`, `stop` and `remoteStreamActive` all belong to the wrapped
        // engine.
        let captureMonitor = CaptureLivenessMonitor(wrapping: baseCaptureEngine)
        self.captureMonitor = captureMonitor
        warningBanner = SessionWarningBanner()
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
            captureEngine: captureMonitor,
            transcriber: LazyWhisperKitTranscriber(),
            lookback: lookback,
            fusionRunner: fusionRunner
        )

        // MARK: Engine callbacks (SPEC §4.1).
        // Device switches are rebuilt INSIDE the engine; the coordinator's
        // handleDeviceChange() logs the `deviceChanged` timeline event.
        //
        // Remote degradation (Screen Recording revoked, SCStream failed
        // twice, no display) continues mic-only — SPEC §4.1's failure modes
        // require that this "surface a warning", and until now it resolved to
        // a `logger.warning` and nothing else. Two dogfood runs logged
        // "SCStream stopped: The user stopped the stream → degraded to
        // mic-only", i.e. two meetings were recorded with the other
        // participants' audio entirely missing and the UI never said a word.
        // It now raises a warning on the meeting-time banner, WHILE the
        // meeting is still running and can still be restarted.
        if let sckEngine = baseCaptureEngine as? SCKCaptureEngine {
            sckEngine.onDeviceChange = { [weak coordinator] in
                coordinator?.handleDeviceChange()
            }
            // Called on one of the engine's internal queues (documented on
            // `onRemoteDegraded`) — hop to the main actor before touching UI.
            sckEngine.onRemoteDegraded = { [weak self] reason in
                Task { @MainActor in self?.systemAudioDegraded(reason: reason) }
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
        // The panel's "Start Meeting" runs the same TCC guard as the menu bar
        // and History paths; route it at the app-owned wizard so all three
        // share one instance (see the History wiring below for why).
        scratchpadPanel.permissionGuardEnabled = !useStubCapture
        scratchpadPanel.onPermissionsMissing = { [weak self] in
            guard let self, let step = SetupWizardPhase.firstMissingPermission else { return }
            self.showSetupWizard(at: step)
        }
        menuBarController.onOpenScratchpad = { [weak scratchpadPanel] in
            scratchpadPanel?.show()
        }

        // MARK: Recording chip (design 4a; design 3b invariant, UX review
        // blocker 5). The status item is the consent surface, but a fullscreen
        // space or an auto-hidden menu bar takes it off screen — which is how
        // dogfooding produced "I started a meeting and NOTHING happened".
        // The chip is the indicator + stop affordance for exactly that case;
        // it shows itself only while capturing AND the status item is off
        // screen, so it and the menu-bar capsule are never both on screen.
        recordingChipController = RecordingChipController(coordinator: coordinator)
        // Owner-approved deviation from 4a ("ignores clicks except the Stop
        // pill"): pressing the chip body shows the scratchpad, so the one
        // surface that is guaranteed to be visible while recording is also
        // the way back to the notes (see RecordingChipController.ChipBodyView).
        recordingChipController.onShowScratchpad = { [weak scratchpadPanel] in
            scratchpadPanel?.show()
        }

        // MARK: History window (SPEC §5; T7).
        historyWindowController = HistoryWindowController(store: store, coordinator: coordinator)
        // Empty-state "Start Meeting" runs the same TCC guard as the menu bar
        // path. Wiring it to the APP-OWNED wizard matters: unwired, History
        // falls back to constructing its own SetupWizardController, and two
        // wizard instances would race on the persisted `setupPhase`.
        historyWindowController.permissionGuardEnabled = !useStubCapture
        historyWindowController.onPermissionsMissing = { [weak self] in
            guard let self, let step = SetupWizardPhase.firstMissingPermission else { return }
            self.showSetupWizard(at: step)
        }
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
        // A second launch surrenders (see the single-instance guard) and asks
        // us to show ourselves on its way out.
        summonObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.summonNotification, object: nil, queue: .main
        ) { [weak scratchpadPanel] _ in
            MainActor.assumeIsolated { scratchpadPanel?.show() }
        }

        // MARK: Coordinator events (app-level log; menu bar and History
        // render states — History surfaces findings/failures/recovery as
        // inline warning cards and row meta).
        let coordinator: SessionCoordinator = coordinator
        eventTask = Task { [coordinator] in
            for await event in coordinator.events() {
                switch event {
                case .stateChanged(let state):
                    // DELIBERATE DEVIATION from journey J1 (design 3a:
                    // "Menu bar · idle → Start Meeting → Recording → ⌥⌘N →
                    // Scratchpad"), owner-approved 2026-08-19. As specced,
                    // `start()` produced NO visible surface: with the menu bar
                    // auto-hidden the owner clicked Start Meeting and saw
                    // nothing at all, could not tell recording had begun and
                    // could not find the scratchpad. Starting a meeting now
                    // brings the scratchpad up by itself. Do not "fix" this
                    // back to J1.
                    //
                    // It lives HERE, on the coordinator's event stream, rather
                    // than in any one button's handler, so it fires for every
                    // start path — the status menu, the History empty state,
                    // the panel's own Start, and anything added later.
                    //
                    // Idempotent and focus-safe by construction:
                    // `ScratchpadPanelController.show()` returns immediately
                    // when the panel is already on screen (journey J2 — the
                    // user started the meeting FROM the panel — therefore
                    // re-runs no animation and re-takes no focus), and it
                    // presents with `orderFrontRegardless()` on a
                    // `.nonactivatingPanel`: Scribe never becomes the active
                    // app and the meeting app keeps its activation.
                    if state == .recording {
                        scratchpadPanel?.show()
                    }
                    // Capture health is only meaningful inside a meeting, and
                    // the warnings it raises are only actionable inside one —
                    // so the watchdog and the banner live and die with the
                    // recording state. Warnings are cleared on the way OUT of
                    // recording, never on the way in: `onRemoteDegraded` fires
                    // during `coordinator.start()`, i.e. before this event.
                    self.recordingStateChanged(isRecording: state == .recording)
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
                case .transcriptDrainTimedOut(let sessionId):
                    logger.warning("""
                    Transcript drain timed out on \(sessionId.uuidString, privacy: .public) — \
                    the transcriber did not finish within the stop budget; fusion ran on the \
                    segments already persisted. The session stopped cleanly.
                    """)
                case .fusionFailed(let sessionId, let message):
                    logger.error("""
                    Fusion failed on \(sessionId.uuidString, privacy: .public): \
                    \(message, privacy: .public) — Retry available.
                    """)
                }
            }
        }

        // MARK: Interruptions (SPEC §4.4: sleep/wake → pause/resume capture;
        // the session clock keeps running through sleep, SPEC §4.1).
        //
        // PARTIAL against the spec, deliberately and visibly. The coordinator
        // still logs the `sleep`/`wake` device events, and the app now watches
        // whether capture actually came back (`checkCaptureHealth()`) and
        // warns the user in the meeting if it did not. What it CANNOT do is
        // the resume itself: `CaptureEngine` (CaptureKit) exposes only
        // `start()`, `stop()` and `remoteStreamActive`, and calling `start()`
        // again mid-session would reset `SCKCaptureEngine`'s `mach_continuous_time`
        // session clock and re-stamp every subsequent buffer from zero,
        // corrupting the transcript timeline. A real resume needs a
        // clock-preserving `pause()`/`resume()` (or `rebuildGraph()`) on
        // `CaptureEngine`, driven from the coordinator's `handleSleep()`/
        // `handleWake()`. Until that lands, the microphone can stay dead after
        // a wake — but the user is now TOLD, which is the half of the spec the
        // app can honour from here.
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self, weak coordinator] _ in
                coordinator?.handleSleep()
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self, weak coordinator] _ in
                coordinator?.handleWake()
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
        ]

        // MARK: Sparkle updates (SPEC §6; T9) — starts the automatic
        // update schedule; no-op in DEBUG builds.
        updaterManager.start()

        // MARK: Main menu (design 3b invariants; UX review finding 4).
        // Installed once the surfaces exist, because the App menu's
        // Settings… routes through the SAME handler the status menu uses.
        installMainMenu()

        // MARK: First-run setup wizard (T8; SPEC §4.1/§5) — shown after the
        // menu bar is ready. Resumes at the persisted phase (the Screen
        // Recording TCC grant forces a quit-and-reopen, SPEC §4.1); once
        // completed (phase 5) it never shows on launch again.
        if SetupWizardPhase.persisted != .completed {
            showSetupWizard(at: SetupWizardPhase.persisted)
        }

        scheduleDebugAutoStart() // dev tooling; no-op on a normal launch
    }

    /// Lazily creates and shows the setup wizard at a step.
    private func showSetupWizard(at step: SetupWizardPhase) {
        if setupWizardController == nil {
            setupWizardController = SetupWizardController()
        }
        setupWizardController?.show(at: step)
    }

    // MARK: - Store: persisted, or refuse to run (SPEC §4.4)

    /// Where this launch's store lives.
    ///
    /// `-debugStorePath <path>` (dev tooling; sibling of `-debugUseStubCapture`,
    /// `-uiGallery` and `-chipProbe`) points a build at a throwaway store, so
    /// the failure paths below can be driven without going anywhere near the
    /// real one. Absent, it is the SPEC §4.6 default:
    /// `~/Library/Application Support/Scribe/store.sqlite`.
    private static func storeURL() -> URL {
        let override = UserDefaults.standard.string(forKey: "debugStorePath") ?? ""
        guard !override.isEmpty else { return MeetingStore.defaultStorePath() }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }

    /// What the user chose in the store-failure alert.
    private enum StoreFailureChoice {
        case quit
        case moveAside
        case revealInFinder
    }

    /// A recovery step that could not be taken; its message is fed back into
    /// the next alert so the user learns why the button did nothing.
    private struct StoreRecoveryError: LocalizedError {
        let errorDescription: String?
    }

    /// Opens the on-disk store, or explains the failure and terminates.
    ///
    /// Returns `nil` only after asking AppKit to terminate — the caller must
    /// return immediately. It NEVER returns an in-memory store: see the long
    /// note at the call site for why silent degradation was removed.
    private func openStoreOrExplain() -> MeetingStore? {
        var note: String?
        var attempt = 0
        while true {
            let url = Self.storeURL()
            do {
                let store = try MeetingStore(path: url.path)
                if note != nil {
                    logger.notice("Store opened after recovery at \(url.path, privacy: .public).")
                }
                return store
            } catch {
                logger.fault("""
                Store failed to open at \(url.path, privacy: .public) \
                (\(String(describing: error), privacy: .public)) — refusing to run without \
                persistence (SPEC §4.4); asking the user.
                """)
                let choice = presentStoreFailure(url: url, error: error, note: note, attempt: attempt)
                attempt += 1
                switch choice {
                case .quit:
                    NSApp.terminate(nil)
                    return nil
                case .revealInFinder:
                    // The file may not exist (that can BE the failure), so
                    // select it if it does and open its folder otherwise.
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent())
                    }
                    note = nil
                case .moveAside:
                    do {
                        let moved = try moveStoreAside(at: url)
                        logger.notice("Moved unreadable store to \(moved.path, privacy: .public).")
                        note = "The previous database was saved as “\(moved.lastPathComponent)”."
                    } catch {
                        note = "The database could not be moved aside: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// The blocking store-failure alert. Modal on purpose: this runs before
    /// any surface exists, and the whole point is that the user cannot start
    /// a meeting they would lose.
    private func presentStoreFailure(
        url: URL, error: Error, note: String?, attempt: Int
    ) -> StoreFailureChoice {
        // DEV TOOLING — `-debugStoreFailureChoice <quit|moveAside|reveal>`
        // answers the alert without showing it, so both recovery branches can
        // be driven headlessly (a modal alert cannot be clicked without
        // Accessibility permission). Honoured on the FIRST failure only, so a
        // recovery that does not help cannot spin this loop. Never set on a
        // normal launch.
        if attempt == 0 {
            switch UserDefaults.standard.string(forKey: "debugStoreFailureChoice") ?? "" {
            case "moveAside": return .moveAside
            case "reveal": return .revealInFinder
            case "quit": return .quit
            default: break
            }
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Scribe can’t open its meeting database."
        var body = """
        Every meeting — transcript, scratchpad notes and fused notes — is stored in:

        \(url.path)

        That file could not be opened, so nothing recorded now would be saved. Scribe will \
        not record until this is fixed.

        Moving the database aside renames it (nothing is deleted) and starts an empty one: \
        recording works again immediately, but past meetings stay out of History until the \
        old file is repaired or restored.

        Details: \(error.localizedDescription)
        """
        if let note { body += "\n\n\(note)" }
        alert.informativeText = body
        alert.addButton(withTitle: "Quit Scribe") // default: ⏎
        alert.addButton(withTitle: "Move Database Aside and Retry")
        alert.addButton(withTitle: "Reveal in Finder")
        // An `.accessory` app has no Dock icon and does not activate itself at
        // launch: without this the alert can open behind every other window and
        // the user just sees a Scribe that never appears.
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .moveAside
        case .alertThirdButtonReturn: return .revealInFinder
        default: return .quit
        }
    }

    /// Renames a failed store — and its WAL/SHM siblings — out of the way so a
    /// fresh one can be created in its place.
    ///
    /// NOTHING is deleted. That is what makes this safe to offer for a database
    /// we cannot even read: the bytes keep existing under a dated name, so a
    /// user (or a later repair tool) can still get the old meetings back.
    @discardableResult
    private func moveStoreAside(at url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw StoreRecoveryError(errorDescription: """
            There is no database file to move — the problem is with the folder \
            \(url.deletingLastPathComponent().path), not the file.
            """)
        }
        let stamp = Self.storeStampFormatter.string(from: Date())
        let ext = url.pathExtension.isEmpty ? "sqlite" : url.pathExtension
        let target = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-damaged-\(stamp).\(ext)")
        try fm.moveItem(at: url, to: target)
        // Best effort on the journal siblings: GRDB recreates them, and a
        // stray -wal next to a NEW database is exactly what we do not want.
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: side.path) else { continue }
            try? fm.moveItem(at: side, to: URL(fileURLWithPath: target.path + suffix))
        }
        return target
    }

    private static let storeStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    // MARK: - Capture health (SPEC §4.1 failure modes, SPEC §4.4 interruptions)

    /// How long the mic may go without delivering a buffer before capture is
    /// called dead.
    ///
    /// An `AVAudioEngine` tap fires continuously while its graph runs — a
    /// silent ROOM still produces buffers — so a gap this long does not mean
    /// "nobody spoke", it means the graph is stopped. That is precisely what
    /// system sleep does to it. Six seconds is comfortably longer than the
    /// engine's own device-change rebuild (sub-second) so a route switch never
    /// trips it.
    private static let micSilenceThreshold: TimeInterval = 6
    private static let captureWatchdogInterval: TimeInterval = 2

    /// Starts/stops the meeting-time capture watchdog and clears the banner
    /// when the meeting ends.
    private func recordingStateChanged(isRecording: Bool) {
        if isRecording {
            startCaptureWatchdog()
            scheduleDebugCaptureFault()
        } else {
            stopCaptureWatchdog()
            warningBanner?.clear()
        }
    }

    private func startCaptureWatchdog() {
        guard captureWatchdog == nil else { return }
        let timer = Timer(timeInterval: Self.captureWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCaptureHealth() }
        }
        // `.common` so the check keeps running while a menu is being tracked
        // or a window is being resized — a stalled mic must not need an idle
        // main loop to be noticed.
        RunLoop.main.add(timer, forMode: .common)
        captureWatchdog = timer
    }

    private func stopCaptureWatchdog() {
        captureWatchdog?.invalidate()
        captureWatchdog = nil
    }

    /// Polls the two capture channels and raises/withdraws warnings.
    ///
    /// The remote (system audio) channel reports its own health
    /// (`remoteStreamActive`); the local (mic) channel has no health signal at
    /// all, so it is inferred from buffer arrival via `CaptureLivenessMonitor`.
    /// Both warnings withdraw themselves if capture comes back, so a stream
    /// that recovers does not leave a stale scare on screen.
    private func checkCaptureHealth() {
        guard coordinator?.displayState == .recording else { return }
        guard let monitor = captureMonitor, let banner = warningBanner else { return }

        if monitor.remoteStreamActive {
            banner.remove(.systemAudioMissing)
        } else {
            // No logging on this path: it runs every couple of seconds for as
            // long as the fault lasts, and `add` is idempotent per kind.
            banner.add(Self.systemAudioWarning)
        }

        if let silence = monitor.silenceDuration(on: .local), silence >= Self.micSilenceThreshold {
            banner.add(micStalledWarning(silence: silence))
        } else {
            banner.remove(.microphoneStalled)
        }
    }

    /// SPEC §4.1: "Screen Recording permission revoked mid-session → … continue
    /// mic-only, surface a warning." This is the surfacing.
    private func systemAudioDegraded(reason: String) {
        logger.warning("System audio degraded to mic-only: \(reason, privacy: .public)")
        warningBanner?.add(Self.systemAudioWarning)
    }

    private static let systemAudioWarning = SessionWarningBanner.Warning(
        kind: .systemAudioMissing,
        title: "Only your microphone is being recorded",
        detail: """
        Scribe lost the system-audio stream, so the other participants are not being \
        captured and “Them” will be empty in the notes. Check Screen Recording in \
        System Settings ▸ Privacy & Security, then stop this meeting and start a new one.
        """
    )

    private func micStalledWarning(silence: TimeInterval) -> SessionWarningBanner.Warning {
        let wokeRecently = lastWakeAt.map { Date().timeIntervalSince($0) < 120 } ?? false
        let detail: String
        if wokeRecently {
            // SPEC §4.4's resume half is not implemented (see the sleep/wake
            // wiring); say so plainly instead of pretending the meeting is fine.
            detail = """
            Your Mac woke from sleep and the microphone did not restart, so nothing has \
            reached Scribe for \(Int(silence)) seconds. Stop this meeting and start a new \
            one to resume recording.
            """
        } else {
            detail = """
            No audio has reached Scribe from the microphone for \(Int(silence)) seconds. \
            The input device may have been unplugged or taken by another app. Stop this \
            meeting and start a new one once the input is back.
            """
        }
        return SessionWarningBanner.Warning(
            kind: .microphoneStalled, title: "The microphone stopped recording", detail: detail
        )
    }

    private func systemWillSleep() {
        guard coordinator?.displayState == .recording else { return }
        logger.notice("System sleeping mid-session — capture cannot be paused (CaptureEngine has no pause API).")
    }

    private func systemDidWake() {
        lastWakeAt = Date()
        guard coordinator?.displayState == .recording else { return }
        logger.notice("""
        System woke mid-session — watching whether capture resumed \
        (\(Int(Self.micSilenceThreshold), privacy: .public) s grace).
        """)
    }

    /// DEV TOOLING — `-debugAutoStartMeeting <seconds>` starts a session that
    /// many seconds after launch, so the meeting-time surfaces can be driven
    /// without clicking a status-item menu (which needs Accessibility
    /// permission to automate). Pair with `-debugUseStubCapture YES` so no
    /// microphone is ever opened. Does nothing on a normal launch.
    private func scheduleDebugAutoStart() {
        let delay = UserDefaults.standard.double(forKey: "debugAutoStartMeeting")
        guard delay > 0 else { return }
        logger.info("debugAutoStartMeeting — starting a session in \(delay, privacy: .public) s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            Task.detached { try? await coordinator.start() }
        }
    }

    /// DEV TOOLING — `-debugCaptureFault <remoteDegraded|micStall|sleepWake>`
    /// injects a capture fault ~3 s into a recording so the warning surface can
    /// be driven without a real SCStream failure or a real system sleep.
    /// Sibling of `-debugUseStubCapture` / `-uiGallery` / `-chipProbe`; does
    /// nothing on a normal launch.
    private func scheduleDebugCaptureFault() {
        let fault = UserDefaults.standard.string(forKey: "debugCaptureFault") ?? ""
        guard !fault.isEmpty else { return }
        logger.info("debugCaptureFault = \(fault, privacy: .public) — injecting in 3 s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            switch fault {
            case "remoteDegraded":
                self.captureMonitor?.debugKillRemoteStream()
                self.systemAudioDegraded(reason: "simulated (-debugCaptureFault remoteDegraded)")
            case "micStall":
                self.captureMonitor?.debugStallAudio()
            case "sleepWake":
                let center = NSWorkspace.shared.notificationCenter
                center.post(name: NSWorkspace.willSleepNotification, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    // A real sleep stops the AVAudioEngine graph; the stub
                    // engine keeps ticking, so stall it to match reality.
                    self?.captureMonitor?.debugStallAudio()
                    center.post(name: NSWorkspace.didWakeNotification, object: nil)
                }
            default:
                self.logger.error("Unknown -debugCaptureFault value \(fault, privacy: .public).")
            }
        }
    }


    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Main menu (design 3b: "Every window closes with ⌘W")

    /// Builds and installs `NSApp.mainMenu` — App / Edit / Window.
    ///
    /// An `LSUIElement` app has no Dock icon, but it DOES become the active
    /// app whenever one of its windows is key (Settings, History, wizard),
    /// and while it is active the system draws whatever `mainMenu` holds.
    /// With no main menu at all (the state before this) every key equivalent
    /// the UI advertises was dead while a Scribe window was frontmost:
    /// no ⌘W, no ⌘Q, no ⌘, — and, worst, no Edit menu, so **⌘V could not
    /// paste an API key** into Settings or the wizard and ⌘C could not copy a
    /// transcript out of History. The status item's own key equivalents
    /// (MenuBarController) fire only while that menu is being tracked, so
    /// they never covered this.
    ///
    /// Installing a menu changes nothing about activation: the activation
    /// policy stays `.accessory` (no Dock icon, no launch-time activation) —
    /// the menu simply appears in the menu bar during the moments the app is
    /// already frontmost.
    private func installMainMenu() {
        let (mainMenu, windowMenu) = Self.makeMainMenu(
            appName: ProcessInfo.processInfo.processName,
            settingsTarget: self,
            settingsAction: #selector(openSettingsFromMainMenu)
        )
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu

        // The menu must never buy itself a Dock icon: LSUIElement is in
        // Info.plist and `main()` sets `.accessory`, but assert it here
        // because this is the code that could plausibly change it.
        if NSApp.activationPolicy() != .accessory {
            logger.fault("Activation policy is not .accessory after installing the main menu — restoring it.")
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Builds the App / Edit / Window menus, without installing them.
    ///
    /// Separated from `installMainMenu()` so the menu's CONTENTS can be
    /// checked without a running `NSApplication`: the shipped defect here was
    /// not a wrong item, it was an absent Edit menu, and "did ⌘V paste"
    /// cannot be answered by looking at a screenshot of a text field.
    /// Returns the Window submenu too — it is what `NSApp.windowsMenu` wants.
    static func makeMainMenu(
        appName: String,
        settingsTarget: AnyObject?,
        settingsAction: Selector
    ) -> (main: NSMenu, window: NSMenu) {
        let mainMenu = NSMenu()

        // App menu. Its title is ignored by AppKit (the app name is drawn),
        // but the submenu's own title is what VoiceOver announces.
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        let settings = NSMenuItem(
            title: "Settings…", action: settingsAction, keyEquivalent: ","
        )
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        // target nil → the responder chain reaches NSApplication.terminate,
        // which routes through applicationShouldTerminate (the
        // quit-while-recording confirm, design 3b).
        appMenu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Edit menu. Every item is a standard responder-chain selector with
        // `target = nil`, so AppKit's automatic menu validation enables them
        // exactly when the focused text view (or any responder) can service
        // them. These are built by string because `undo:`/`redo:` have no
        // #selector-able declaration in scope.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let editItems: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "undo:", "z", [.command]),
            ("Redo", "redo:", "z", [.command, .shift]),
            ("", "", "", []), // separator
            ("Cut", "cut:", "x", [.command]),
            ("Copy", "copy:", "c", [.command]),
            ("Paste", "paste:", "v", [.command]),
            ("Delete", "delete:", "", []),
            ("Select All", "selectAll:", "a", [.command]),
        ]
        for (title, selector, key, modifiers) in editItems {
            guard !title.isEmpty else {
                editMenu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(
                title: title, action: NSSelectorFromString(selector), keyEquivalent: key
            )
            item.keyEquivalentModifierMask = modifiers
            item.target = nil
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu. `NSApp.windowsMenu` makes every window register itself
        // here, which is also the only discovery path VoiceOver users have to
        // the app's windows and to the scratchpad panel (review finding 27).
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let close = NSMenuItem(
            title: "Close", action: NSSelectorFromString("performClose:"), keyEquivalent: "w"
        )
        close.target = nil
        windowMenu.addItem(close)
        let minimize = NSMenuItem(
            title: "Minimize", action: NSSelectorFromString("performMiniaturize:"), keyEquivalent: "m"
        )
        minimize.target = nil
        windowMenu.addItem(minimize)
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return (mainMenu, windowMenu)
    }

    /// App-menu Settings… — deliberately the same handler the status-item
    /// menu invokes, so both entry points behave identically (design 3b:
    /// "Settings · reached by Menu → Settings… · ⌘,").
    @objc private func openSettingsFromMainMenu() {
        menuBarController?.onOpenSettings?()
    }

    // MARK: - Quit (design 3b: "Quit while recording asks to stop first")

    /// Guards Quit while a meeting is being captured.
    ///
    /// Terminating mid-recording used to kill capture with no flush: the
    /// session row stayed `recording` and was only reconciled by the next
    /// launch's crash recovery, and the pending scratchpad fragment (≤ 1 s
    /// debounce) was lost with the process. Design 3b makes this one of the
    /// app's exactly two confirms (the other is session Delete).
    ///
    /// On confirm the app returns `.terminateLater` and runs the normal
    /// `SessionCoordinator.stop()` — flush fragment → stop engine → write
    /// `processing` + `endedAt` → bounded transcript drain → fusion — then
    /// replies to the pending terminate. `stop()` is bounded
    /// (`transcriptDrainTimeout`) but its final fusion step is a network
    /// call, so a watchdog replies anyway once the drain budget plus a small
    /// margin has elapsed: by then the row is durably `processing`, and an
    /// unfinished fusion is exactly the state History already offers Retry
    /// for (SPEC §4.5).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, coordinator.displayState == .recording else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop the recording before quitting?"
        alert.informativeText = """
        Scribe is recording a meeting. Quitting stops the recording, saves what has been \
        captured so far, and starts writing the notes.
        """
        alert.addButton(withTitle: "Stop & Quit") // default: ⏎
        alert.addButton(withTitle: "Cancel")
        alert.buttons.last?.keyEquivalent = "\u{1b}" // Esc
        // Quit can arrive from the status-item menu, which does not activate
        // the app — without this the alert can open behind the meeting.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        terminateReplied = false
        let budget = coordinator.transcriptDrainTimeout + 5
        // BOTH tasks are DETACHED, and both answer through
        // `scheduleTerminateReply` rather than the main queue. Driving this
        // path is how we found out why: while a `.terminateLater` reply is
        // pending, AppKit parks the main run loop in
        // `NSModalPanelRunLoopMode`, which does NOT service the main dispatch
        // queue — a `Task { @MainActor … }` here is never scheduled, so
        // `stop()` never runs, the reply never comes, and the app hangs
        // forever with the session half-stopped. `SessionCoordinator` is not
        // main-actor isolated (it is `@unchecked Sendable` behind its own
        // lock), so stopping off the main actor is safe.
        Task.detached(priority: .userInitiated) { [weak self] in
            await coordinator.stop()
            self?.scheduleTerminateReply(timedOut: false)
        }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            self?.scheduleTerminateReply(timedOut: true)
        }
        return .terminateLater
    }

    /// Whether the pending `.terminateLater` has already been answered — the
    /// stop task and its watchdog race, and `reply(toApplicationShouldTerminate:)`
    /// must be sent exactly once.
    private var terminateReplied = false

    /// Hands the reply to the main thread in whatever run-loop mode it is
    /// parked in — `NSModalPanelRunLoopMode` included (see
    /// `applicationShouldTerminate`), which is precisely the mode
    /// `DispatchQueue.main`/`MainActor` cannot reach.
    private nonisolated func scheduleTerminateReply(timedOut: Bool) {
        let runLoop = CFRunLoopGetMain()
        let modes = [
            CFRunLoopMode.commonModes.rawValue,
            CFRunLoopMode.defaultMode.rawValue,
            RunLoop.Mode.modalPanel.rawValue as CFString,
            RunLoop.Mode.eventTracking.rawValue as CFString,
        ] as CFArray
        CFRunLoopPerformBlock(runLoop, modes) {
            // The block runs ON the main thread, just not through the main
            // actor's executor.
            MainActor.assumeIsolated { self.replyToPendingTerminate(timedOut: timedOut) }
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func replyToPendingTerminate(timedOut: Bool) {
        guard !terminateReplied else { return }
        terminateReplied = true
        if timedOut {
            logger.warning("""
            Stop did not finish within the quit budget — quitting anyway. The session row is \
            already `processing` with an end time; fusion can be retried from History.
            """)
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: Entry point — explicit `main` (nib-less AppKit app).
    // The compiler-default `NSApplicationDelegate.main()` just calls
    // `NSApplicationMain`, which only finds a delegate via NSPrincipalClass
    // or a main nib/storyboard — we have neither (LSUIElement menu bar app,
    // all surfaces built in code), so the delegate was never connected and
    // `applicationDidFinishLaunching` never fired: the process idled with no
    // menu bar item and no setup wizard. Wire it by hand instead.
    static func main() {
        let app = NSApplication.shared
        let delegate = ScribeApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // belt & braces: LSUIElement in Info.plist
        app.run()
    }
}

// MARK: - Capture liveness

/// A pass-through `CaptureEngine` decorator that timestamps every buffer it
/// forwards, per channel.
///
/// It exists because `CaptureEngine` reports exactly one thing about its own
/// health — `remoteStreamActive` — and nothing at all about the microphone.
/// The mic graph is the channel that dies across system sleep (SPEC §4.4), so
/// without this the app cannot tell a silent room from a stopped
/// `AVAudioEngine`, and a meeting can run to the end recording nothing.
/// Buffer arrival is the signal: a running tap delivers continuously whether
/// or not anybody is speaking.
///
/// It is deliberately inert — it adds one dictionary write per buffer on the
/// engine's own processing queue and forwards the sample unchanged; every
/// other member is the wrapped engine's.
final class CaptureLivenessMonitor: CaptureEngine, @unchecked Sendable {

    private let wrapped: any CaptureEngine
    private let lock = NSLock()
    private var downstream: ((CapturedSample) -> Void)?
    private var lastSample: [Channel: Date] = [:]
    private var startedAt: Date?
    /// DEBUG seam (`-debugCaptureFault`): stop recording arrival times, which
    /// makes a live engine look exactly like one the HAL stopped at sleep.
    private var stalled = false
    /// DEBUG seam (`-debugCaptureFault`): report the remote stream as dead,
    /// which is what `SCKCaptureEngine` does after the SPEC §4.1 restart
    /// ladder gives up. The stub engine has no failure mode of its own.
    private var remoteForcedInactive = false

    init(wrapping engine: any CaptureEngine) {
        wrapped = engine
        engine.onAudio = { [weak self] sample in
            guard let self else { return }
            lock.lock()
            if !stalled { lastSample[sample.channel] = Date() }
            let forward = downstream
            lock.unlock()
            forward?(sample)
        }
    }

    // MARK: CaptureEngine

    var onAudio: ((CapturedSample) -> Void)? {
        get { lock.withLock { downstream } }
        set { lock.withLock { downstream = newValue } }
    }

    var remoteStreamActive: Bool {
        let forced = lock.withLock { remoteForcedInactive }
        return !forced && wrapped.remoteStreamActive
    }

    func start() async throws {
        lock.withLock {
            lastSample.removeAll()
            stalled = false
            remoteForcedInactive = false
            startedAt = Date()
        }
        try await wrapped.start()
    }

    func stop() async {
        await wrapped.stop()
        lock.withLock {
            lastSample.removeAll()
            startedAt = nil
        }
    }

    // MARK: Liveness

    /// Seconds since the last buffer on `channel`, measured from session start
    /// when none has ever arrived (a channel that never delivers is the worst
    /// case, not an exempt one). `nil` while the engine is stopped.
    func silenceDuration(on channel: Channel) -> TimeInterval? {
        lock.withLock {
            guard let startedAt else { return nil }
            return Date().timeIntervalSince(lastSample[channel] ?? startedAt)
        }
    }

    /// DEBUG seam — see `stalled`.
    func debugStallAudio() {
        lock.withLock { stalled = true }
    }

    /// DEBUG seam — see `remoteForcedInactive`.
    func debugKillRemoteStream() {
        lock.withLock { remoteForcedInactive = true }
    }
}

// MARK: - Meeting-time warning banner

/// The app's meeting-time warning surface (SPEC §4.1 failure modes: continue
/// mic-only and **surface a warning**).
///
/// Why a panel of its own rather than a line pushed into a surface that
/// already renders session state: the menu bar item, the scratchpad panel and
/// the recording chip each own their layout completely and none of them
/// exposes an entry point for an arbitrary notice, so driving one would mean
/// editing files this change does not own. This panel copies the recording
/// chip's posture exactly — borderless, `.nonactivatingPanel`, floating,
/// joins every Space including another app's fullscreen — so a warning raised
/// mid-call is visible without Scribe ever stealing focus from the meeting.
///
/// Placement is bottom-centre: the scratchpad occupies top-centre and the chip
/// and status item occupy the top-right, so this collides with nothing.
@MainActor
final class SessionWarningBanner {

    /// One warning. `kind` is the identity — raising the same kind twice does
    /// not stack, and re-raising with fresh copy updates the text in place.
    struct Warning {
        enum Kind: Hashable {
            case systemAudioMissing
            case microphoneStalled
        }
        let kind: Kind
        let title: String
        let detail: String
    }

    private enum Metrics {
        static let width: CGFloat = 380
        static let padding: CGFloat = 14
        static let corner: CGFloat = 12
        static let bottomInset: CGFloat = 28
        /// Same 180 ms fade the chip and the scratchpad use.
        static let fade: CFTimeInterval = 0.18
    }

    private final class BannerPanel: NSPanel {
        override var canBecomeKey: Bool { true } // reachable, never taken automatically
        override var canBecomeMain: Bool { false }
    }

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "warning")
    private let panel: BannerPanel
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private let dismissButton = NSButton()
    /// Insertion-ordered so the first thing that went wrong reads first.
    private var warnings: [Warning] = []
    /// Kinds the user pushed out of the way. The warning stays RAISED — the
    /// watchdog keeps re-asserting it — but the banner does not pop back into
    /// the meeting every two seconds. Cleared when the fault clears, so a
    /// second occurrence is surfaced again.
    private var dismissedKinds: Set<Warning.Kind> = []
    private var isPresented = false

    init() {
        panel = BannerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        buildContent()
        configurePanel()
    }

    // MARK: Warnings

    /// Raises a warning, showing the banner if it is hidden. Idempotent per
    /// `kind`: the watchdog calls this every couple of seconds while the fault
    /// lasts, and that must not re-animate or re-announce anything.
    func add(_ warning: Warning) {
        if let index = warnings.firstIndex(where: { $0.kind == warning.kind }) {
            let existing = warnings[index]
            guard existing.title != warning.title || existing.detail != warning.detail else { return }
            warnings[index] = warning
            if isPresented { render() }
            return
        }
        warnings.append(warning)
        logger.warning("""
        Meeting warning surfaced: \(warning.title, privacy: .public) — \
        \(warning.detail, privacy: .public)
        """)
        guard !dismissedKinds.contains(warning.kind) else { return }
        render()
        present()
        announce(warning)
    }

    /// Withdraws a warning — capture recovered, or the meeting ended.
    func remove(_ kind: Warning.Kind) {
        dismissedKinds.remove(kind) // a second occurrence gets surfaced again
        guard let index = warnings.firstIndex(where: { $0.kind == kind }) else { return }
        warnings.remove(at: index)
        if warnings.isEmpty {
            dismiss()
        } else if isPresented {
            render()
        }
    }

    /// Drops every warning and hides the banner (end of meeting).
    func clear() {
        dismissedKinds.removeAll()
        guard !warnings.isEmpty || isPresented else { return }
        warnings.removeAll()
        dismiss()
    }

    // MARK: Build

    private func buildContent() {
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Metrics.corner
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.55).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        dismissButton.title = "Dismiss"
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .small
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = effect
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: Metrics.padding),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -Metrics.padding),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: Metrics.padding),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -Metrics.padding),
        ])
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear // vibrancy needs a transparent window
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.title = "Scribe Recording Warning"
        panel.alphaValue = 0
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("Scribe recording warning")
    }

    /// Rebuilds the rows and resizes the panel to fit them.
    private func render() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let textWidth = Metrics.width - Metrics.padding * 2
        for warning in warnings {
            let title = NSTextField(labelWithString: "⚠︎  \(warning.title)")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .labelColor
            stack.addArrangedSubview(title)

            let detail = NSTextField(wrappingLabelWithString: warning.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = textWidth
            detail.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        }
        stack.addArrangedSubview(dismissButton)

        // Size the window to the constraint system's answer rather than to a
        // guess: the detail labels wrap, so the height is text-dependent.
        effect.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Metrics.width, height: effect.fittingSize.height))
        position()
    }

    private func position() {
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Metrics.bottomInset
        ))
    }

    // MARK: Present / dismiss

    private func present() {
        guard !isPresented else { return }
        isPresented = true
        position()
        // `orderFrontRegardless` on a `.nonactivatingPanel`: the warning
        // appears over the meeting app without Scribe becoming active, exactly
        // like the scratchpad and the chip.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard isPresented else { return }
        isPresented = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Re-check: an `add()` during the fade must not be ordered out
                // by this completion.
                guard let self, !self.isPresented else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    @objc private func dismissClicked() {
        // Dismiss hides the banner; it does not resolve anything. The warnings
        // stay raised (so a later `remove()` still means "capture recovered"),
        // and any warning of a NEW kind brings the banner straight back. The
        // user can push it out of the way; they cannot make a broken meeting
        // look healthy, and they cannot be told once and then forgotten about.
        dismissedKinds.formUnion(warnings.map(\.kind))
        dismiss()
    }

    /// VoiceOver equivalent of the banner appearing — a floating panel that
    /// never takes focus is otherwise invisible to a screen-reader user.
    private func announce(_ warning: Warning) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(warning.title). \(warning.detail)",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
