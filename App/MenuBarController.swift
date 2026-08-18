import AppKit
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

    private let statusItem: NSStatusItem
    private let spinner = NSProgressIndicator()
    private var menu: NSMenu!
    private var startStopItem: NSMenuItem!
    private var retryItem: NSMenuItem!
    private var scratchpadItem: NSMenuItem!
    private var historyItem: NSMenuItem!

    private var displayState: SessionDisplayState
    private var eventTask: Task<Void, Never>?
    private var pulseTimer: Timer?
    private var doneRevert: DispatchWorkItem?
    private var isMenuOpen = false
    private var lastRenderedElapsed = ""
    private var lastMenuElapsed = ""

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
                spinner.widthAnchor.constraint(equalToConstant: 16),
                spinner.heightAnchor.constraint(equalToConstant: 16),
            ])
        }

        applyVisual(for: displayState)
        subscribeToEvents()
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

        let history = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        history.isEnabled = false // enabled when ScribeApp wires onShowHistory (T7)
        historyItem = history

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self

        // target nil → responder chain reaches NSApplication.terminate.
        let quit = NSMenuItem(title: "Quit Scribe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.addItem(startStop)
        menu.addItem(retry)
        menu.addItem(.separator())
        menu.addItem(scratchpad)
        menu.addItem(history)
        menu.addItem(settings)
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

        // Retry Fusion appears while a fusion error is outstanding (SPEC §5
        // failed → persistent ⚠, retry available).
        retryItem.isHidden = coordinator.lastFusionError == nil
        retryItem.isEnabled = isFailedState

        if isRecording {
            // Elapsed right-aligned via a right tab stop (design/README menu).
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 175)]
            let title = NSMutableAttributedString(
                string: "Stop Meeting",
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
        } else {
            startStopItem.attributedTitle = nil
            startStopItem.title = "Start Meeting"
        }
        startStopItem.isEnabled = true // Start from idle/processing/failed; Stop while recording
    }

    // MARK: - Actions

    @objc private func toggleMeeting() {
        guard displayState != .recording else {
            Task { await coordinator.stop() } // stop → processing → fusion (SPEC §4.4)
            return
        }
        Task {
            do {
                try await coordinator.start()
            } catch {
                // Stub engine can't fail today; real permission failures are
                // the T8 setup wizard's job.
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

    @objc private func statusItemClicked() {
        guard case .done(let sessionId) = displayState else { return }
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
        case .fusionFindings, .fusionFailed, .deviceEventLogged:
            break // logged by ScribeApp; surfaced in History (T7)
        }
    }

    private var isFailedState: Bool {
        if case .failed = displayState { return true }
        return false
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
    }

    private func applyProcessingVisual() {
        attachMenu()
        statusItem.button?.image = nil
        statusItem.length = NSStatusItem.squareLength // square slot for the spinner
        spinner.startAnimation(nil)
    }

    private func applyDoneVisual() {
        statusItem.menu = nil // detach so the badge is clickable (SPEC §5)
        if let button = statusItem.button {
            button.image = StatusGlyphs.doneBadge(dark: StatusGlyphs.menuBarIsDark(button))
            button.target = self
            button.action = #selector(statusItemClicked)
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
        guard case .done = displayState else { return }
        displayState = .idle
        applyVisual(for: .idle)
        if isMenuOpen {
            updateMenuContent()
        }
    }

    private func attachMenu() {
        if statusItem.menu == nil {
            if let button = statusItem.button {
                button.target = nil
                button.action = nil
            }
            statusItem.menu = menu
        }
    }

    /// Redraws the recording capsule (dot opacity + elapsed). Called at the
    /// pulse rate; with Reduce Motion the dot is static and the redraw
    /// happens only when the elapsed second flips.
    private func refreshRecordingVisual() {
        attachMenu()
        statusItem.length = NSStatusItem.variableLength
        let text = Formatting.elapsedString(coordinator.elapsed())
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
        pop.values = [0.55, 1.12, 1.0]
        pop.keyTimes = [0, 0.7, 1.0]
        pop.duration = 0.4
        pop.calculationMode = .cubic
        button.layer?.add(pop, forKey: "scribe.donePop")
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
        let heights: [CGFloat] = [6, 10, 7.5, 4.5]
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
        tintedSymbol("exclamationmark.triangle.fill", color: .systemRed, pointSize: 14)
        ?? exclamationFallback

    /// Done badge: green check-in-circle + "Notes ready" (design 2c).
    static func doneBadge(dark: Bool) -> NSImage {
        let text = "Notes ready"
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let symbolSide: CGFloat = 12
        let gap: CGFloat = 4
        let size = NSSize(width: symbolSide + gap + ceil(textSize.width), height: 16)
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
        let hPadding: CGFloat = 6
        let gap: CGFloat = 4
        let height: CGFloat = 16
        let width = hPadding + dot + gap + ceil(textSize.width) + hPadding
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        let capsule = NSBezierPath(
            roundedRect: NSRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1),
            xRadius: 5,
            yRadius: 5
        )
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.08)).setFill()
        capsule.fill()
        NSColor.systemRed.withAlphaComponent(opacity).setFill()
        NSBezierPath(ovalIn: NSRect(x: hPadding, y: (height - dot) / 2, width: dot, height: dot)).fill()
        (elapsedText as NSString).draw(
            at: NSPoint(x: hPadding + dot + gap, y: (height - textSize.height) / 2),
            withAttributes: [
                .font: font,
                .foregroundColor: dark ? NSColor.white.withAlphaComponent(0.92) : NSColor.labelColor,
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
