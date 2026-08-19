import AppKit
import CaptureKit
import Combine
import os
import SessionKit

/// Menu bar surface (SPEC §5; design/README "Menu bar item", designs 1a/2c).
///
/// Renders the DERIVED UI states (SPEC §5 — storage states stay on session
/// rows, never in the schema) from `CoordinatorEvent`s:
/// - `idle`: template waveform glyph
/// - `recording`: capsule with pulsing 7 pt red dot + SF Mono tabular
///   wall-clock elapsed (`coordinator.elapsed()`, SPEC §4.1 two-clocks rule)
/// - `processing`: small NSProgressIndicator spinner
/// - `done`: transient 4 s green-check badge, clickable → History (T7)
/// - `failed`: persistent ⚠ until the menu is opened; menu gains Retry Fusion
///
/// The recording indicator is ALWAYS visible while capturing — non-negotiable
/// consent posture (SPEC §5), including when the scratchpad panel is closed.
@MainActor
final class MenuBarController: NSObject {

    /// Recording-dot pulse period (design 1a: 1.6 s opacity cycle 100%→35%).
    private static let pulsePeriod: TimeInterval = 1.6
    /// How long the done badge holds before reverting to idle (SPEC §5).
    private static let doneHoldInterval: TimeInterval = 4
    /// Pulse redraw rate (30 fps smooths the cosine fade; dropped to 1 Hz and
    /// a static dot when Reduce Motion is on).
    private static let pulseTickInterval: TimeInterval = 1.0 / 30.0
    /// Processing spinner side (design 1a: 13 × 13 pt).
    private static let spinnerSide: CGFloat = 13

    private let logger = Logger(subsystem: "com.example.scribe", category: "menubar")
    private let coordinator: SessionCoordinator

    /// Open Settings… ⌘, — set by ScribeApp.
    var onOpenSettings: (() -> Void)?
    /// Open the scratchpad panel — set by ScribeApp once the panel exists
    /// (T6); setting it enables the menu item (disabled until wired).
    var onOpenScratchpad: (() -> Void)? {
        didSet { scratchpadItem?.isEnabled = onOpenScratchpad != nil }
    }
    /// Open the History window's list view — set by ScribeApp once the
    /// window exists (T7); setting it enables the menu item (disabled until
    /// wired).
    var onShowHistory: (() -> Void)? {
        didSet { historyItem?.isEnabled = onShowHistory != nil }
    }
    /// Open the History window AT a session — menu-bar done-badge click
    /// (SPEC §5: the done transient is clickable → opens the session in
    /// History); the done event carries the sessionId. Set by ScribeApp.
    var onOpenHistory: ((UUID) -> Void)?

    /// Start-flow permission guard (T8): when true and Start Meeting is
    /// clicked while mic or Screen Recording TCC is missing,
    /// `onPermissionsMissing` fires instead of starting — ScribeApp opens
    /// the setup wizard at the relevant step rather than letting the start
    /// fail silently (mic) or degrade quietly (screen, SPEC §4.1). Disabled
    /// when the debug stub engine is active (no TCC involved).
    var permissionGuardEnabled = false
    /// Fired by the start guard above — ScribeApp routes it to the wizard.
    var onPermissionsMissing: (() -> Void)?

    private let statusItem: NSStatusItem
    private let spinner = NSProgressIndicator()
    private var menu: NSMenu!
    private var startStopItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var notesItem: NSMenuItem!
    private var scratchpadItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var checkForUpdatesItem: NSMenuItem!
    private var updatesCancellable: AnyCancellable?

    private var displayState: SessionDisplayState
    private var eventTask: Task<Void, Never>?
    private var pulseTimer: Timer?
    private var doneRevert: DispatchWorkItem?
    private var isMenuOpen = false
    private var lastRenderedElapsed = ""
    private var lastMenuElapsed = ""
    /// Last elapsed string pushed into the accessibility label. The capsule
    /// redraws at 30 Hz; the label must only change (and so only notify
    /// assistive clients) when the displayed second actually flips.
    private var lastAccessibleElapsed = ""

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        self.displayState = coordinator.displayState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        buildMenu()
        statusItem.menu = menu

        // Spinner lives inside the status button for the whole app lifetime;
        // `isDisplayedWhenStopped` hides it outside the processing state.
        if let button = statusItem.button {
            spinner.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                spinner.widthAnchor.constraint(equalToConstant: Self.spinnerSide),
                spinner.heightAnchor.constraint(equalToConstant: Self.spinnerSide),
            ])
        }

        applyVisual(for: displayState)
        subscribeToEvents()

        // Sparkle (SPEC §6): flip "Check for Updates…" on once the updater
        // is started and idle. `canCheckForUpdates` bridges from Sparkle's
        // KVO; `.receive(on: main)` because the sink touches AppKit.
        updatesCancellable = UpdaterManager.shared.$canCheckForUpdates
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                MainActor.assumeIsolated {
                    self?.checkForUpdatesItem.isEnabled = canCheck
                }
            }

        if UserDefaults.standard.bool(forKey: "a11yProbe") {
            runAccessibilityProbe()
        }
    }

    // MARK: - Gallery test seam (dev tooling — App/UIGallery.swift)

    /// Screen frame of the status item's button window. The status item is
    /// not an app window, so the screenshot harness cannot capture it by
    /// window number — it region-captures this rect instead.
    var galleryStatusItemFrame: NSRect? { statusItem.button?.window?.frame }

    /// Every derived state's status-item artwork, in design 1a order, drawn
    /// straight into images.
    ///
    /// `galleryStatusItemFrame` above is ground truth but only while the
    /// menu bar is actually on screen: with System Settings › Control Center
    /// › "Automatically hide and show the menu bar" on, that region shot
    /// comes back black. This seam hands the gallery the very artwork
    /// `applyVisual(for:)` installs on the status button, so the
    /// `menubar-states` scene can be composed into a PNG with no screen
    /// capture at all — and so all five states are visible at once, which a
    /// region shot of the live item never is.
    ///
    /// `elapsedText` fixes the recording capsule's clock (the gallery never
    /// starts a session) and `dark` picks the dark-menu-bar colors. The
    /// idle glyph comes back as a template image (`isTemplate`) exactly as
    /// the system receives it — the caller tints it.
    func galleryStateImages(elapsedText: String, dark: Bool) -> [(state: String, image: NSImage)] {
        var images: [(state: String, image: NSImage)] = [
            ("idle", StatusGlyphs.waveform),
            (
                "recording",
                StatusGlyphs.recordingCapsule(elapsedText: elapsedText, opacity: 1, dark: dark)
            ),
        ]
        if let spinner = galleryProcessingSnapshot(dark: dark) {
            images.append(("processing", spinner))
        }
        images.append(("done", StatusGlyphs.doneBadge(dark: dark)))
        images.append(("failed", StatusGlyphs.warningBadge))
        return images
    }

    /// One frame of the REAL processing spinner (the `NSProgressIndicator`
    /// that lives in the status button), snapshotted so it can be composed
    /// into a still. AppKit caches the indeterminate spinner as a dim
    /// monochrome mask — on screen the menu bar's appearance lightens it —
    /// so on a dark strip the snapshot is re-tinted to the design's
    /// `white 90%` leading-arc color.
    private func galleryProcessingSnapshot(dark: Bool) -> NSImage? {
        let bounds = NSRect(x: 0, y: 0, width: Self.spinnerSide, height: Self.spinnerSide)
        spinner.superview?.layoutSubtreeIfNeeded()
        spinner.startAnimation(nil)
        defer { spinner.stopAnimation(nil) }
        guard let rep = spinner.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        spinner.cacheDisplay(in: bounds, to: rep)
        let snapshot = NSImage(size: bounds.size)
        snapshot.addRepresentation(rep)
        guard dark else { return snapshot }
        let tinted = NSImage(size: bounds.size)
        tinted.lockFocus()
        snapshot.draw(in: bounds)
        NSColor.white.withAlphaComponent(0.9).setFill()
        bounds.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }

    // MARK: - Accessibility readback seam (dev tooling)

    /// `-a11yProbe YES` on the command line: walk the status item through
    /// every derived state and print what an assistive client would read off
    /// it (`A11Y` lines), the menu as it stands in each state (`MENU` lines)
    /// and the done-badge click routing (`CLICK` lines), then exit. Sibling
    /// of the `gallery*` seams above — dev tooling, never touched by a
    /// normal launch.
    ///
    /// Why it exists: the status item is not a window and the menu bar
    /// auto-hides, so it cannot be screenshotted, and driving VoiceOver from
    /// a script needs Accessibility trust this machine does not grant. The
    /// labels are therefore read back through the very `NSAccessibility`
    /// properties an AT client queries, on the live button, after the REAL
    /// state path has run: a stub-capture session for idle → recording →
    /// processing, then the rest forced through `transition(to:)` — which is
    /// exactly what a `CoordinatorEvent` does. Pair with
    /// `-debugUseStubCapture YES` so no microphone opens:
    ///
    ///     Scribe.app/Contents/MacOS/Scribe -a11yProbe YES \
    ///         -debugUseStubCapture YES -setupPhase 5
    private func runAccessibilityProbe() {
        Task { @MainActor in
            probeReport("launch")
            probeMenuDump("idle")
            for seconds in [0, 1, 59, 61, 1_456, 3_661] {
                print("SPOKEN\t\(seconds)s\t\(Self.spokenElapsed(TimeInterval(seconds)))")
            }

            toggleMeeting() // real start, through the real menu action
            var seen: Set<String> = []
            var stopIssued = false
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let key = Self.probeKey(displayState)
                if seen.insert(key).inserted { probeReport("live-\(key)") }
                if key == "recording", !stopIssued, coordinator.elapsed() >= 3 {
                    probeReport("live-recording-3s")
                    probeMenuDump("recording")
                    stopIssued = true
                    toggleMeeting() // real stop
                }
                if key == "done" || key == "failed" { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            for forced in [SessionDisplayState.processing, .failed(sessionId: UUID()), .done(sessionId: UUID())] {
                transition(to: forced)
                probeReport("forced-\(Self.probeKey(forced))")
                probeMenuDump(Self.probeKey(forced))
            }

            // Done-badge click routing (finding 9): which button gets the
            // menu and which gets the notes.
            for (tag, event) in Self.probeClickEvents() {
                print("CLICK\t\(tag)\twantsMenu=\(Self.clickWantsMenu(event))")
            }
            // Failed badge: opening the menu acknowledges the ⚠, so the
            // label has to follow the artwork back to idle. Driven through
            // the delegate callback an opening menu invokes.
            transition(to: .failed(sessionId: UUID()))
            menuWillOpen(menu)
            probeReport("failed-menu-opened")
            menuDidClose(menu)
            print("PROBE\tcomplete")
            exit(0)
        }
    }

    private func probeReport(_ tag: String) {
        let button = statusItem.button
        let actions = (button?.accessibilityCustomActions() ?? []).map(\.name).joined(separator: "|")
        print("""
        A11Y\t\(tag)\tlabel=\(button?.accessibilityLabel() ?? "nil")\
        \tvalue=\((button?.accessibilityValue() as? String) ?? "nil")\
        \thelp=\(button?.accessibilityHelp() ?? "nil")\
        \tactions=\(actions.isEmpty ? "none" : actions)\
        \tmenuAttached=\(statusItem.menu != nil)\tbuttonAction=\(button?.action != nil)
        """)
    }

    private func probeMenuDump(_ tag: String) {
        updateMenuContent()
        for item in menu.items where !item.isHidden {
            let title = item.isSeparatorItem
                ? "———"
                : (item.attributedTitle?.string ?? item.title).replacingOccurrences(of: "\t", with: " ⇥ ")
            var shortcut = ""
            if !item.keyEquivalent.isEmpty {
                let mask = item.keyEquivalentModifierMask
                shortcut = (mask.contains(.control) ? "⌃" : "")
                    + (mask.contains(.option) ? "⌥" : "")
                    + (mask.contains(.shift) ? "⇧" : "")
                    + (mask.contains(.command) ? "⌘" : "")
                    + item.keyEquivalent.uppercased()
            }
            print("MENU\t\(tag)\t\(title)\t\(shortcut)\tenabled=\(item.isEnabled)")
        }
    }

    private static func probeClickEvents() -> [(String, NSEvent?)] {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        return [
            ("left", event(.leftMouseUp, [])),
            ("control-left", event(.leftMouseUp, .control)),
            ("right", event(.rightMouseUp, [])),
            ("keyboard-performClick", nil),
        ]
    }

    private static func probeKey(_ state: SessionDisplayState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    // MARK: - Menu (design/README "Menu")

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let startStop = NSMenuItem(title: "Start Meeting", action: #selector(toggleMeeting), keyEquivalent: "")
        startStop.target = self

        let retry = NSMenuItem(title: "Retry Fusion", action: #selector(retryFusion), keyEquivalent: "")
        retry.target = self
        retry.isHidden = true // transient item, failed state only (SPEC §5)

        let scratchpad = NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpad), keyEquivalent: "n")
        scratchpad.keyEquivalentModifierMask = [.option, .command]
        scratchpad.target = self
        scratchpad.isEnabled = false // enabled when ScribeApp wires onOpenScratchpad (T6)
        scratchpadItem = scratchpad

        // Transient (done state only), like Retry Fusion above: the 4 s
        // "Notes ready" badge is a mouse target, so the notes need a path
        // that exists INSIDE the menu too — for keyboard/VoiceOver users and
        // for anyone who opens the menu during the transient instead of
        // clicking the badge (finding 9).
        let notes = NSMenuItem(title: "Open Notes", action: #selector(openLastNotes), keyEquivalent: "")
        notes.target = self
        notes.isHidden = true
        notesItem = notes

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        history.isEnabled = false // enabled when ScribeApp wires onShowHistory (T7)
        historyItem = history

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        // Check for Updates… (Sparkle 2, SPEC §6; T9). Menu placement chosen
        // over a Settings footer — Scribe's primary surface is this menu.
        // Enabled only when the updater is running (never in DEBUG: Sparkle
        // must not run against debug builds — see UpdaterManager).
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = false
        checkForUpdatesItem = updates

        // target nil → responder chain reaches NSApplication.terminate.
        // Title is `Quit` (not the usual "Quit <App>"): design 1a item 7 and
        // SPEC §5 both spell the menu out literally.
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Order and grouping are design 1a / SPEC §5: the meeting actions
        // (Start/Stop, the transient Retry Fusion, Open Scratchpad) form the
        // first group, then History…/Settings…, then Quit. "Check for
        // Updates…" is the one addition to that list (SPEC §6, T9).
        menu.addItem(startStop)
        menu.addItem(retry)
        menu.addItem(scratchpad)
        menu.addItem(.separator())
        menu.addItem(notes)
        menu.addItem(history)
        menu.addItem(settings)
        menu.addItem(updates)
        menu.addItem(.separator())
        menu.addItem(quit)
        self.menu = menu
        startStopItem = startStop
        retryItem = retry
    }

    /// Refreshes item titles/enablement; also called on the 1 s boundary
    /// while the menu is open during recording so the elapsed stays live.
    private func updateMenuContent() {
        let isRecording = displayState == .recording

        // Retry Fusion appears in the failure state only (design 1a: "menu
        // gains Retry Fusion"; SPEC §5 failed → persistent ⚠, retry
        // available). It stays through the ⚠ being acknowledged, because
        // opening the menu clears the badge but not the failure.
        let showsRetry = MenuBarPresentation.retryFusionIsVisible(in: displayState)
        retryItem.isHidden = !showsRetry
        retryItem.isEnabled = showsRetry

        // Open Notes rides the done transient only (see buildMenu).
        if MenuBarPresentation.openNotesIsVisible(in: displayState) {
            notesItem.isHidden = false
            notesItem.isEnabled = onOpenHistory != nil
        } else {
            notesItem.isHidden = true
        }

        if isRecording {
            // Elapsed right-aligned via a right tab stop (design/README menu).
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 175)]
            let title = NSMutableAttributedString(
                string: MenuBarPresentation.startStopTitle(in: displayState),
                attributes: [.font: NSFont.menuFont(ofSize: 13), .paragraphStyle: paragraph]
            )
            title.append(NSAttributedString(
                string: "\t" + Formatting.elapsedString(coordinator.elapsed()),
                attributes: [
                    .font: Formatting.elapsedFont(ofSize: 12, weight: .regular),
                    .paragraphStyle: paragraph,
                ]
            ))
            startStopItem.attributedTitle = title
            // ⌘. = stop, the macOS stop/cancel idiom (finding 18: there was
            // no keyboard stop anywhere). A status-menu key equivalent fires
            // only while the menu is open, so it is advertised only while
            // there IS something to stop — and the scratchpad panel carries
            // the hands-on-keyboard stop (Return) for the rest of the time.
            // Deliberately not ⌘, / ⌘Q / ⌥⌘N: those belong to the main menu
            // and the global hotkey.
            startStopItem.keyEquivalent = MenuBarPresentation.startStopKeyEquivalent(in: displayState)
            startStopItem.keyEquivalentModifierMask = [.command]
        } else {
            startStopItem.attributedTitle = nil
            startStopItem.title = MenuBarPresentation.startStopTitle(in: displayState)
            startStopItem.keyEquivalent = MenuBarPresentation.startStopKeyEquivalent(in: displayState)
        }
        startStopItem.isEnabled = true // Start from idle/processing/failed; Stop while recording
    }

    // MARK: - Actions

    @objc private func toggleMeeting() {
        guard displayState != .recording else {
            Task { await coordinator.stop() } // stop → processing → fusion (SPEC §4.4)
            return
        }
        // T8 start guard: a start without TCC would throw (mic) or silently
        // degrade to mic-only (screen) — route to the wizard instead.
        if permissionGuardEnabled,
           CapturePermissions.microphone != .granted
            || CapturePermissions.screenRecording == .denied {
            onPermissionsMissing?()
            return
        }
        Task {
            do {
                try await coordinator.start()
            } catch {
                // Permission loss is preempted by the guard above; anything
                // reaching here is an engine failure worth logging.
                logger.error("Meeting start failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func retryFusion() {
        Task { await coordinator.retryFusion() } // SPEC §4.5 failure semantics
    }

    @objc private func openScratchpad() {
        onOpenScratchpad?() // panel show — same surface as the ⌥⌘N hotkey (T6)
    }

    @objc private func openHistory() {
        onShowHistory?() // History window list view (T7)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    /// Sparkle manual update check (SPEC §6). UpdaterManager temporarily
    /// switches Scribe to a regular activation policy so Sparkle's update
    /// window can take focus (accessory app, LSUIElement). No-op in DEBUG.
    @objc private func checkForUpdates() {
        UpdaterManager.shared.checkForUpdates()
    }

    /// Click on the status item while the done badge is up (the only state
    /// where the button has an action at all — see `applyDoneVisual`).
    ///
    /// Left click = the design 1a click target ("clicking opens the session
    /// in History"). Right or Control click = the menu, so design 3b's
    /// "status item is the persistent root" holds during the transient too.
    @objc private func statusItemClicked() {
        guard case .done(let sessionId) = displayState,
              let button = statusItem.button else { return }
        if Self.clickWantsMenu(NSApp.currentEvent) {
            popUpMenuDuringDone(button)
            return
        }
        openDoneSession(sessionId)
    }

    /// Right-click / Control-click → menu; anything else (including a
    /// keyboard-driven `performClick`, which carries no event) → the badge's
    /// advertised action. See `MenuBarPresentation.clickWantsMenu`.
    private static func clickWantsMenu(_ event: NSEvent?) -> Bool {
        MenuBarPresentation.clickWantsMenu(event)
    }

    /// Pops the ordinary menu while the done badge owns the button.
    ///
    /// `NSStatusItem` swallows the button's action whenever `menu` is
    /// attached, so the badge's click target and the menu cannot both be
    /// live off one attached menu — the menu is therefore attached just for
    /// the duration of this click. `performClick` blocks for the whole menu
    /// tracking loop, so the transient may well have expired by the time it
    /// returns; only re-detach if the badge is still up.
    private func popUpMenuDuringDone(_ button: NSStatusBarButton) {
        statusItem.menu = menu
        button.performClick(nil)
        if case .done = displayState {
            statusItem.menu = nil
        }
    }

    @objc private func openLastNotes() {
        guard case .done(let sessionId) = displayState else { return }
        openDoneSession(sessionId)
    }

    private func openDoneSession(_ sessionId: UUID) {
        onOpenHistory?(sessionId) // History opens at the session (T7)
        endDoneTransient()
    }

    // MARK: - Coordinator events (SPEC §5 derived states)

    private func subscribeToEvents() {
        eventTask = Task { [weak self, coordinator] in
            for await event in coordinator.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: CoordinatorEvent) {
        switch event {
        case .stateChanged(let state):
            transition(to: state)
        case .recoveredSessions(let sessions):
            // History surfaces these for retry; app-level log meanwhile.
            logger.warning("Recovered \(sessions.count) interrupted session(s) — fusion retry available from History.")
        case .fusionFindings, .fusionFailed, .deviceEventLogged, .transcriptDrainTimedOut:
            break // logged by ScribeApp; surfaced in History (T7)
        }
    }

    private func transition(to state: SessionDisplayState) {
        displayState = state
        applyVisual(for: state)
        if isMenuOpen {
            updateMenuContent()
        }
    }

    // MARK: - Visuals

    private func applyVisual(for state: SessionDisplayState) {
        doneRevert?.cancel()
        doneRevert = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        spinner.stopAnimation(nil)
        statusItem.length = NSStatusItem.variableLength

        switch state {
        case .idle:
            attachMenu()
            statusItem.button?.image = StatusGlyphs.waveform
        case .recording:
            attachMenu()
            refreshRecordingVisual()
            startPulseTimer()
        case .processing:
            applyProcessingVisual()
        case .done:
            applyDoneVisual()
        case .failed:
            attachMenu()
            statusItem.button?.image = StatusGlyphs.warningBadge
        }
        // Blocker 10: every state carries its own VoiceOver label — the
        // elapsed clock and "Notes ready" are pixels inside a bitmap, and
        // the ⚠ is colour alone (finding 21), so without this the whole
        // surface reads as an unlabeled "button".
        updateAccessibility(for: state)
    }

    private func applyProcessingVisual() {
        attachMenu()
        statusItem.button?.image = nil
        statusItem.length = NSStatusItem.squareLength // square slot for the spinner
        spinner.startAnimation(nil)
    }

    private func applyDoneVisual() {
        // The badge is clickable (SPEC §5 / design 1a: "clicking opens the
        // session in History"), which means the menu cannot stay attached —
        // an attached menu eats the button's action. Rather than leave the
        // item menu-less for 4 s (finding 9: Quit/Settings/Start unreachable,
        // and any click teleported the user to History), the button takes
        // BOTH mouse buttons: left = open the notes, right/Control = pop the
        // same menu, which also carries an "Open Notes" item for the
        // keyboard path. The status item never stops being a menu (3b).
        statusItem.menu = nil
        if let button = statusItem.button {
            button.image = StatusGlyphs.doneBadge(dark: StatusGlyphs.menuBarIsDark(button))
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            popIn(button)
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.endDoneTransient()
            }
        }
        doneRevert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doneHoldInterval, execute: work)
    }

    /// Reverts the transient done badge to idle (SPEC §5: done auto-returns
    /// to idle; storage is already `complete` — display-only transition).
    private func endDoneTransient() {
        // The revert is a 4 s timer, so by the time it lands the user may
        // already have started the NEXT meeting off the badge; only a state
        // that is STILL `.done` may be reverted.
        guard let next = MenuBarPresentation.stateAfterDoneHold(displayState) else { return }
        displayState = next
        applyVisual(for: next)
        if isMenuOpen {
            updateMenuContent()
        }
    }

    private func attachMenu() {
        // Only ever undo the done state's wiring — this runs at the pulse
        // rate while recording, and re-assigning `statusItem.menu` under an
        // open menu would close it.
        if let button = statusItem.button, button.action != nil {
            button.target = nil
            button.action = nil
            button.sendAction(on: [.leftMouseUp]) // back to the NSButton default
        }
        guard statusItem.menu !== menu else { return }
        statusItem.menu = menu
    }

    /// Redraws the recording capsule (dot opacity + elapsed). Called at the
    /// pulse rate; with Reduce Motion the dot is static and the redraw
    /// happens only when the elapsed second flips.
    private func refreshRecordingVisual() {
        attachMenu()
        statusItem.length = NSStatusItem.variableLength
        let text = Formatting.elapsedString(coordinator.elapsed())
        if text != lastAccessibleElapsed {
            updateAccessibility(for: .recording) // live elapsed, once per second
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion && text == lastRenderedElapsed {
            return
        }
        lastRenderedElapsed = text
        guard let button = statusItem.button else { return }
        let phase = reduceMotion
            ? 0
            : fmod(Date().timeIntervalSinceReferenceDate, Self.pulsePeriod) / Self.pulsePeriod
        button.image = StatusGlyphs.recordingCapsule(
            elapsedText: text,
            opacity: StatusGlyphs.pulseOpacity(phase: phase),
            dark: StatusGlyphs.menuBarIsDark(button)
        )
    }

    private func startPulseTimer() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let interval = reduceMotion ? 1.0 : Self.pulseTickInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common) // .common keeps ticking while the menu is open
        pulseTimer = timer
    }

    private func tick() {
        guard displayState == .recording else { return }
        refreshRecordingVisual()
        let current = Formatting.elapsedString(coordinator.elapsed())
        if isMenuOpen && current != lastMenuElapsed {
            lastMenuElapsed = current
            updateMenuContent()
        }
    }

    /// 400 ms spring pop for the done badge (design 2c: overshoot ~1.12);
    /// skipped entirely under Reduce Motion.
    private func popIn(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        button.wantsLayer = true
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.6, 1.12, 1.0] // checkpop: 0% .6 → 60% 1.12 → 100% 1
        pop.keyTimes = [0, 0.6, 1.0]
        pop.duration = 0.4
        pop.calculationMode = .cubic
        button.layer?.add(pop, forKey: "scribe.donePop")
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0] // checkpop fades in over the same 60%
        fade.keyTimes = [0, 0.6, 1.0]
        fade.duration = 0.4
        button.layer?.add(fade, forKey: "scribe.donePopFade")
    }

    // MARK: - Accessibility (blocker 10 / findings 9, 21)

    /// Idle label. Spelled "not recording" on purpose: SPEC §5's consent
    /// posture ("the recording indicator is ALWAYS visible") only holds for
    /// a VoiceOver user if idle and recording are told apart by ear.
    static let idleLabel = MenuBarPresentation.idleLabel

    /// Elapsed clock in speech, not digits — see
    /// `MenuBarPresentation.spokenElapsed`.
    static func spokenElapsed(_ interval: TimeInterval) -> String {
        MenuBarPresentation.spokenElapsed(interval)
    }

    /// Labels the status button for the given derived state. Called from
    /// `applyVisual(for:)` for every state and again once per second from
    /// `refreshRecordingVisual()` so the spoken elapsed stays live.
    ///
    /// The label carries state AND data, because assistive clients that
    /// ignore `AXValue` on a menu-bar element must still get the elapsed;
    /// `AXValue` repeats the clock alone so a client can poll just that.
    private func updateAccessibility(for state: SessionDisplayState) {
        guard let button = statusItem.button else { return }
        let elapsed = state == .recording ? coordinator.elapsed() : 0
        lastAccessibleElapsed = state == .recording ? Formatting.elapsedString(elapsed) : ""

        let announcement = MenuBarPresentation.announcement(for: state, elapsed: elapsed)
        button.setAccessibilityLabel(announcement.label)
        button.setAccessibilityValue(announcement.value)
        button.setAccessibilityHelp(announcement.help)

        // The done badge is a click target for 4 s, and a VoiceOver user
        // cannot right-click a status item — so the same thing is offered as
        // a custom action (VO ⌃⌥⌘-Space). Only this state carries one.
        if case .done(let sessionId) = state {
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: MenuBarPresentation.openNotesActionName) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return false }
                        self.openDoneSession(sessionId)
                        return true
                    }
                },
            ])
        } else {
            button.setAccessibilityCustomActions([])
        }
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        updateMenuContent()
        // SPEC §5: failed clears when the menu is opened (the Retry Fusion
        // item added above is the user's path forward).
        if case .failed = displayState {
            statusItem.button?.image = StatusGlyphs.waveform
            // The label follows the badge: the failure has been
            // acknowledged, and Retry Fusion — which VoiceOver reads like
            // any other menu item — is the shared path forward.
            statusItem.button?.setAccessibilityLabel(Self.idleLabel)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }
}

// MARK: - Glyph drawing

/// Status-item image builders. All drawn once-per-state (recording redraws at
/// the pulse rate); template where the system should re-color, explicit
/// colors (resolved against the button's effective appearance) otherwise.
private enum StatusGlyphs {

    /// Idle waveform: 4 rounded bars, 15×13 pt, template (design 1a).
    static let waveform: NSImage = {
        let size = NSSize(width: 15, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill() // template — the system re-colors for light/dark
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2
        // design 1a rects: x 0.5/4.5/8.5/12.5 (originX 0.5 + 4 pt pitch),
        // y 4.5/1.5/3.5/5 (each bar vertically centered in the 13 pt box),
        // w 2, h 4/10/6/3, rx 1.
        let heights: [CGFloat] = [4, 10, 6, 3]
        let originX = (size.width - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap)) / 2
        for (index, height) in heights.enumerated() {
            let bar = NSRect(
                x: originX + CGFloat(index) * (barWidth + gap),
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    /// Failed ⚠ (SPEC §5: persistent until the menu opens).
    static let warningBadge: NSImage =
        tintedSymbol("exclamationmark.triangle", color: .systemRed, pointSize: 14)
        ?? exclamationFallback

    /// Done badge: green check-in-circle + "Notes ready" (design 2c).
    static func doneBadge(dark: Bool) -> NSImage {
        let text = "Notes ready"
        // design 2c: `400 12px` SF Pro label, 5 pt gap after the 12 pt check.
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let symbolSide: CGFloat = 12
        let gap: CGFloat = 5
        let height = max(16, ceil(textSize.height))
        let size = NSSize(width: symbolSide + gap + ceil(textSize.width), height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        let symbolRect = NSRect(x: 0, y: (size.height - symbolSide) / 2, width: symbolSide, height: symbolSide)
        if let check = tintedSymbol("checkmark.circle.fill", color: .systemGreen, pointSize: symbolSide) {
            check.draw(in: symbolRect)
        } else {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: symbolRect).fill()
        }
        (text as NSString).draw(
            at: NSPoint(x: symbolSide + gap, y: (size.height - textSize.height) / 2),
            withAttributes: [
                .font: font,
                .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.labelColor,
            ]
        )
        image.unlockFocus()
        return image
    }

    /// Recording capsule: radius 5, 7 pt pulsing systemRed dot, SF Mono
    /// tabular elapsed (design 1a). Capsule fill white 14% on dark menu bars;
    /// the light equivalent is black 8% (native materials win over hex).
    static func recordingCapsule(elapsedText: String, opacity: CGFloat, dark: Bool) -> NSImage {
        let font = Formatting.elapsedFont(ofSize: 11.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (elapsedText as NSString).size(withAttributes: attributes)
        let dot: CGFloat = 7
        // design 1a: padding `2px 7px 2px 6px`, 5 pt dot→time gap.
        let leadingPadding: CGFloat = 6
        let trailingPadding: CGFloat = 7
        let vPadding: CGFloat = 2
        let gap: CGFloat = 5
        let height = ceil(max(dot, textSize.height)) + vPadding * 2
        let width = leadingPadding + dot + gap + ceil(textSize.width) + trailingPadding
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        let capsule = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
            xRadius: 5,
            yRadius: 5
        )
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).setFill()
        capsule.fill()
        NSColor.systemRed.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: leadingPadding, y: (height - dot) / 2, width: dot, height: dot)).fill()
        (elapsedText as NSString).draw(
            at: NSPoint(x: leadingPadding + dot + gap, y: (height - textSize.height) / 2),
            withAttributes: [
                .font: font,
                .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.95) : NSColor.labelColor,
            ]
        )
        image.unlockFocus()
        return image
    }

    /// Cosine ease-in-out over the 1.6 s cycle: 1.0 at phase 0 → 0.35 at 0.5.
    static func pulseOpacity(phase: Double) -> CGFloat {
        CGFloat(0.675 - 0.325 * cos(2 * Double.pi * phase))
    }

    static func menuBarIsDark(_ button: NSStatusBarButton) -> Bool {
        button.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }

    /// SF Symbol tinted via source-atop compositing (aspect-preserving).
    private static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size)
        image.lockFocus()
        let symbolSize = symbol.size
        let scale = min(size.width / symbolSize.width, size.height / symbolSize.height)
        let rect = NSRect(
            x: (size.width - symbolSize.width * scale) / 2,
            y: (size.height - symbolSize.height * scale) / 2,
            width: symbolSize.width * scale,
            height: symbolSize.height * scale
        )
        symbol.draw(in: rect)
        color.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }

    /// Unreachable on macOS 14 (symbol exists); keeps declarations force-free.
    private static let exclamationFallback: NSImage = {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 14, height: 14)).fill()
        ("!" as NSString).draw(
            at: NSPoint(x: 5, y: 3.5),
            withAttributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        )
        image.unlockFocus()
        return image
    }()
}

// MARK: - Derived presentation (pure)

/// Everything the menu bar shows, derived from `SessionDisplayState` alone
/// (SPEC §5) with no AppKit state involved.
///
/// Split out of `MenuBarController` because that controller cannot be built
/// without a live `NSStatusItem` and a real `SessionCoordinator`: the status
/// item is not a window, the menu bar auto-hides, and driving VoiceOver from
/// a script needs Accessibility trust CI does not have. That is exactly why
/// this mapping has only ever been checked by eye — see the `-a11yProbe`
/// harness above, which was built because nothing else could see it.
///
/// Everything here is a pure function of the derived state, so it IS
/// checkable, and `MenuBarController` calls into it rather than restating
/// any of it.
enum MenuBarPresentation {

    // MARK: Menu items

    /// SPEC §5 / design 1a: the failure state — and only the failure state —
    /// "gains Retry Fusion". It must not linger into `idle` after the ⚠ has
    /// been acknowledged, and it must not be offered while a fusion the user
    /// cannot yet judge is still in flight.
    static func retryFusionIsVisible(in state: SessionDisplayState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// "Open Notes" rides the 4 s done transient only — it is the keyboard
    /// and VoiceOver path to the badge's click target (finding 9), and it
    /// points at a specific session id, so it is meaningless in every other
    /// state.
    static func openNotesIsVisible(in state: SessionDisplayState) -> Bool {
        if case .done = state { return true }
        return false
    }

    static let openNotesActionName = "Open notes in History"

    /// The one meeting action: Stop while recording, Start otherwise —
    /// including from `processing` and `failed`, where a previous meeting is
    /// still being fused but a new one may begin.
    static func startStopTitle(in state: SessionDisplayState) -> String {
        state == .recording ? "Stop Meeting" : "Start Meeting"
    }

    /// ⌘. (the macOS stop/cancel idiom) is advertised only while there is
    /// something to stop; a status-menu key equivalent fires only while the
    /// menu is tracking, so leaving it attached to "Start Meeting" would put
    /// a dead shortcut on screen.
    static func startStopKeyEquivalent(in state: SessionDisplayState) -> String {
        state == .recording ? "." : ""
    }

    // MARK: Done transient

    /// The state the 4 s done badge reverts to, or `nil` when it must not
    /// revert at all.
    ///
    /// The revert is a timer, and 4 s is long enough for the user to have
    /// clicked the badge (which ends the transient early) or started the next
    /// meeting off it. A revert that fired unconditionally would drop a live
    /// `recording` capsule back to the idle waveform while the mic was open —
    /// which is the one thing SPEC §5's consent posture forbids.
    static func stateAfterDoneHold(_ current: SessionDisplayState) -> SessionDisplayState? {
        if case .done = current { return .idle }
        return nil
    }

    /// Right-click / Control-click on the done badge → the menu; anything
    /// else — including a keyboard-driven `performClick`, which carries no
    /// event at all — → the badge's advertised action (open the notes).
    static func clickWantsMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return true
        case .leftMouseDown, .leftMouseUp:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    // MARK: Accessibility

    /// Idle label. Spelled "not recording" on purpose: SPEC §5's consent
    /// posture ("the recording indicator is ALWAYS visible") only holds for
    /// a VoiceOver user if idle and recording are told apart by ear.
    static let idleLabel = "Scribe — idle, not recording"

    /// What an assistive client reads off the status button.
    struct Announcement: Equatable {
        /// `AXLabel` — carries state AND data, because clients that ignore
        /// `AXValue` on a menu-bar element must still get the elapsed.
        let label: String
        /// `AXValue` — the clock alone, so a client can poll just that.
        let value: String?
        /// `AXHelp` — only where there is something non-obvious to do.
        let help: String?
    }

    /// Elapsed clock in speech, not digits: the capsule's "24:16" is read
    /// "twenty-four sixteen" (or worse) by speech synthesis, so the label
    /// carries "24 minutes 16 seconds". Zero-valued components are dropped,
    /// except that a zero total still has to say something.
    static func spokenElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        func unit(_ value: Int, _ name: String) -> String {
            "\(value) \(name)\(value == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if seconds > 0 || parts.isEmpty { parts.append(unit(seconds, "second")) }
        return parts.joined(separator: " ")
    }

    /// Every derived state carries its OWN label: the elapsed clock and
    /// "Notes ready" are pixels inside a bitmap, and the ⚠ is colour alone
    /// (finding 21), so without this the whole surface reads as an unlabeled
    /// "button" (blocker 10).
    static func announcement(for state: SessionDisplayState, elapsed: TimeInterval) -> Announcement {
        switch state {
        case .idle:
            return Announcement(label: idleLabel, value: nil, help: nil)
        case .recording:
            let spoken = spokenElapsed(elapsed)
            return Announcement(label: "Scribe — recording, \(spoken)", value: spoken, help: nil)
        case .processing:
            return Announcement(label: "Scribe — processing notes", value: nil, help: nil)
        case .done:
            return Announcement(
                label: "Scribe — notes ready",
                value: nil,
                help: "Opens these notes in History. Right-click or Control-click for the Scribe menu."
            )
        case .failed:
            return Announcement(
                label: "Scribe — fusion failed",
                value: nil,
                help: "Open the Scribe menu and choose Retry Fusion."
            )
        }
    }
}
