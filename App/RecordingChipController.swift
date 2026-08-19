import AppKit
import SessionKit
import os

// MARK: - Palette

/// Chip colours (design 4a). Native materials win over the artboard's literal
/// rgba values (`design/README.md`), so the chip body is `NSVisualEffectView`
/// `.hudWindow` rather than `rgba(30,30,34,.85)`; the alpha steps the artboard
/// spells out for resting → hover survive as the border/opacity deltas below.
private enum ChipPalette {
    /// Elapsed clock — design 4a white 90 % (≈9.9:1 on the HUD material).
    static let elapsedText = NSColor.white.withAlphaComponent(0.90)
    /// Hairline, resting (white 16 %) and hover (white 20 %).
    static let border = NSColor.white.withAlphaComponent(0.16)
    static let borderHover = NSColor.white.withAlphaComponent(0.20)
    /// Rec dot — `#ff453a` is `NSColor.systemRed` in dark appearance, and the
    /// same 7 pt dot the status item draws.
    static let recDot = NSColor.systemRed
    /// Stop pill fill: systemRed 22 % / 32 % (design 4a — the scratchpad's
    /// own Stop uses 16 % / 26 %; two distinct affordances, not a conflict).
    static let stopFill = NSColor.systemRed.withAlphaComponent(0.22)
    static let stopFillHover = NSColor.systemRed.withAlphaComponent(0.32)
    /// Stop label `#ff8a82` — design 4a's lighter red-on-dark. Measured
    /// ≈6.9:1 over the HUD material, so unlike the small greys corrected in
    /// `HUDPalette` this one passes AA as drawn and is kept verbatim.
    static let stopText = NSColor(
        srgbRed: 0xFF / 255, green: 0x8A / 255, blue: 0x82 / 255, alpha: 1
    )
}

// MARK: - Panel

/// Borderless, non-activating chip window.
///
/// `becomesKeyOnlyIfNeeded` is ON here — the opposite of the scratchpad. The
/// scratchpad exists to receive typing, so it takes key on summon; the chip is
/// a passive indicator whose two controls (Stop, and the body's show-scratchpad
/// press) need no keyboard input, and taking key away from a fullscreen meeting
/// app mid-sentence to click a 24 pt chip would be a worse bug than the one
/// this window fixes.
private final class ChipPanel: NSPanel {
    override var canBecomeKey: Bool { true } // reachable, but never taken automatically
    override var canBecomeMain: Bool { false }
}

// MARK: - Stop pill

/// The hover-revealed Stop pill (design 4a: 18 pt tall, radius 9, padding
/// 0 × 9, `500 11px` SF Pro, `#ff8a82` on systemRed 22 % / 32 % hover).
///
/// A real `NSButton` rather than a drawn shape, so it is one AX element with a
/// label, a press action and a focus ring — the review's "the stop affordance
/// must be a real control" bar.
private final class StopPillButton: NSButton {

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .exterior
        wantsLayer = true
        layer?.cornerRadius = RecordingChipController.Metrics.stopRadius
        layer?.backgroundColor = ChipPalette.stopFill.cgColor
        attributedTitle = NSAttributedString(string: "Stop", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ChipPalette.stopText,
        ])
        setAccessibilityLabel("Stop recording")
        setAccessibilityHelp("Stops the meeting and starts writing the notes.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StopPillButton is created in code")
    }

    /// Design 4a: `0 9px` padding around an 11 pt "Stop".
    var fittingPillWidth: CGFloat {
        ceil(attributedTitle.size().width) + 2 * RecordingChipController.Metrics.stopPadding
    }

    /// The chip never activates Scribe, so every click on it is a "first
    /// mouse" — which `NSButton` drops by default (the bug already fixed once
    /// on the scratchpad's header buttons, UX review finding 8).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: RecordingChipController.Metrics.stopRadius,
            yRadius: RecordingChipController.Metrics.stopRadius
        ).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshFill()
    }

    private func refreshFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = (isHovering ? ChipPalette.stopFillHover : ChipPalette.stopFill).cgColor
        CATransaction.commit()
    }
}

// MARK: - Chip body

/// The chip's background: hairline + corner radius, the drag handle, and the
/// press target that shows the scratchpad.
///
/// DELIBERATE DEVIATION FROM DESIGN 4a (owner-approved, 2026-08-19). The
/// artboard's contract says "Ignores clicks except the Stop pill". That is
/// overridden: a click anywhere on the chip body shows/fronts the scratchpad.
/// The dogfood report this whole surface answers had two halves — "no visible
/// feedback that recording started" AND "I could never find the scratchpad" —
/// and a floating indicator that returns you to your notes on click (the
/// Granola pattern) closes the second half with the affordance already on
/// screen for the first. Do not "fix" this back to spec.
///
/// Click and drag are told apart by distance, not timing: a press that never
/// travels more than `dragSlop` is a click; anything further is a reposition
/// and suppresses the click on mouse-up.
private final class ChipBodyView: NSView {

    /// Press (not drag) on the body — show the scratchpad.
    var onPress: (() -> Void)?
    /// New right edge (screen coordinates) while dragging.
    var onDragTo: ((CGFloat) -> Void)?
    /// Any mouse activity over the chip — resets the 4 s idle fade.
    var onActivity: (() -> Void)?

    private var pressOrigin: NSPoint?
    private var pressWindowMaxX: CGFloat = 0
    private var didDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        pressWindowMaxX = window?.frame.maxX ?? 0
        didDrag = false
        onActivity?()
    }

    /// Design 4a: "draggable along the top edge" — horizontal only, so the
    /// chip cannot be parked somewhere it stops being an indicator.
    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin else { return }
        let delta = NSEvent.mouseLocation.x - pressOrigin.x
        if abs(delta) > RecordingChipController.Metrics.dragSlop {
            didDrag = true
        }
        guard didDrag else { return }
        onActivity?()
        onDragTo?(pressWindowMaxX + delta)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressOrigin = nil
            didDrag = false
        }
        onActivity?()
        guard !didDrag else { return } // a reposition is not a click
        onPress?()
    }

    // MARK: Accessibility

    /// The body is a real AX button (see the deviation note above): its press
    /// shows the scratchpad, and Stop is offered as a custom action so a
    /// VoiceOver user can stop WITHOUT first producing the hover that reveals
    /// the pill (VoiceOver navigation moves no pointer).
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

// MARK: - Controller

/// Recording chip — the fullscreen-safe indicator and stop affordance
/// (design 4a; design 3b invariant: "the recording indicator cannot be
/// dismissed while capture is live — when fullscreen hides the menu bar, the
/// recording chip (4a) takes over as indicator and stop affordance").
///
/// WHY IT EXISTS (UX review finding 5, blocker). The status item is the
/// consent surface, and SPEC §5 makes it non-negotiable while capturing — but
/// a fullscreen space or "automatically hide and show the menu bar" takes it
/// off screen entirely. Dogfooding found exactly that: a meeting started from
/// the menu bar produced NO visible feedback, and there was then no indicator
/// and no way to stop. This window is the design's own answer.
///
/// Shown only while `capturing && the status item is off screen` — never both
/// this and a visible menu-bar capsule (see `statusItemIsOffScreen(on:)` for how
/// reliable that detection is, and what it cannot see).
///
/// DOGFOODED 2026-08-19 (macOS 26.2, 14" notched display) against a REAL
/// fullscreen space, with a real stub-capture session driven through
/// `-chipProbe YES -chipLive <s>`: the chip appears in the fullscreen space and
/// not on the desktop Space, follows a Space switch in both directions within
/// one tick, reveals the Stop pill on a real hover, fades to 60 % after 4 s and
/// holds there, and goes away on stop. NOT yet exercised by a human hand: a
/// real click (deviation D1), a real drag, and the transient menu-bar reveal —
/// synthetic clicks and drags need the Accessibility permission the automation
/// host does not have, and a warped cursor does not trigger the reveal.
@MainActor
final class RecordingChipController: NSObject {

    /// Design 4a metrics. `internal` because `StopPillButton` above reads the
    /// pill's own numbers out of it.
    enum Metrics {
        static let height: CGFloat = 24
        static let cornerRadius: CGFloat = 12 // full pill (height ÷ 2)
        static let dotSide: CGFloat = 7
        static let padLeading: CGFloat = 10
        /// Resting `0 10px`; hover tightens the right side to 4 for the pill.
        static let padTrailingResting: CGFloat = 10
        static let padTrailingHover: CGFloat = 4
        static let gapResting: CGFloat = 6
        static let gapHover: CGFloat = 8
        static let stopHeight: CGFloat = 18
        static let stopRadius: CGFloat = 9
        static let stopPadding: CGFloat = 9
        static let elapsedFontSize: CGFloat = 11 // 0.5 pt under the menu-bar capsule
        /// 1.6 s opacity cycle 100 % → 35 %, same as the status item.
        static let pulsePeriod: CFTimeInterval = 1.6
        static let pulseFloor: Float = 0.35
        /// "Appears/dismisses with the same 180 ms fade as the scratchpad."
        static let fadeDuration: CFTimeInterval = 0.18
        /// "Fades to 60 % opacity after 4 s idle; never fully hides."
        static let idleDelay: TimeInterval = 4
        static let idleAlpha: CGFloat = 0.6
        /// Gap between the (hidden) menu-bar band and the chip, so a
        /// transient auto-hide reveal draws ABOVE the chip, never over it.
        static let belowMenuBarGap: CGFloat = 6
        /// Default distance from the screen's right edge (design 4a: the
        /// specimen row is right-aligned with 18 px of padding).
        static let rightInset: CGFloat = 18
        /// Travel before a press becomes a drag rather than a click.
        static let dragSlop: CGFloat = 3
        /// Extra margin around the chip in which the window stops being
        /// click-through, so a fast click that outruns the pointer poll still
        /// lands on the chip instead of the app underneath.
        static let hitMargin: CGFloat = 6
        /// Pointer poll (hover + click-through gating). 30 Hz matches the
        /// menu bar's own recording-pulse cadence.
        static let pointerPoll: TimeInterval = 1.0 / 30.0
        /// Elapsed clock + visibility re-evaluation.
        static let tickInterval: TimeInterval = 1
        /// A screen whose visible frame reaches within this many points of
        /// its full frame has no menu bar drawn on it.
        static let menuBarInsetThreshold: CGFloat = 4
    }

    private static let pulseKey = "scribe.chip.pulse"

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "chip")
    private let coordinator: SessionCoordinator

    /// Click on the chip body → show the scratchpad (owner-approved deviation
    /// from 4a; see `ChipBodyView`). Wired by `ScribeApp`.
    var onShowScratchpad: (() -> Void)?

    private let panel: ChipPanel
    private let body = ChipBodyView()
    private let effectView = NSVisualEffectView()
    private let dotView = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "00:00")
    private let stopButton = StopPillButton()

    private var isRecording: Bool
    private var isHovered = false
    private var isPresented = false
    /// Distance from the target screen's right edge to the chip's right edge;
    /// the only thing dragging changes (design 4a: horizontal reposition).
    private var rightInset = Metrics.rightInset
    private var elapsedText = "00:00"
    /// Set by the gallery seam — suspends the live visibility gate.
    private var galleryFrozen = false
    /// Last elapsed string pushed into the AX label, so the label is only
    /// rewritten when the spoken value actually changes.
    private var lastAccessibleElapsed = ""

    private var eventTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var pointerTimer: Timer?
    private var idleFadeWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
        isRecording = coordinator.displayState == .recording
        panel = ChipPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: Metrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContent()
        configurePanel()
        subscribeToEvents()
        observeEnvironment()
        startTickTimer()
        evaluateVisibility()

        // Dev tooling — see `runChipProbe()`. Sibling of MenuBarController's
        // `-a11yProbe` seam; never runs on a normal launch.
        if UserDefaults.standard.bool(forKey: "chipProbe") {
            runChipProbe()
        }
    }

    // MARK: - Build

    private func buildContent() {
        body.wantsLayer = true
        body.layer?.cornerRadius = Metrics.cornerRadius
        body.layer?.masksToBounds = true
        body.layer?.borderWidth = 0.5
        body.layer?.borderColor = ChipPalette.border.cgColor

        // Native material over the artboard's rgba+blur (design/README rule).
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(radius: Metrics.cornerRadius)
        effectView.autoresizingMask = [.width, .height]
        body.addSubview(effectView)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = Metrics.dotSide / 2
        dotView.layer?.backgroundColor = ChipPalette.recDot.cgColor
        dotView.setAccessibilityElement(false) // the group carries the state
        body.addSubview(dotView)

        elapsedLabel.attributedStringValue = Self.elapsedAttributedString(elapsedText)
        elapsedLabel.setAccessibilityElement(false) // "24:16" must never be spoken as digits
        body.addSubview(elapsedLabel)

        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        // Same keyboard stop as the scratchpad header (UX review finding 18),
        // live only while the chip is key — which, by design, it only becomes
        // if something explicitly makes it so.
        stopButton.keyEquivalent = "\r"
        stopButton.keyEquivalentModifierMask = .command
        stopButton.isHidden = true // revealed on hover (design 4a)
        body.addSubview(stopButton)

        body.onPress = { [weak self] in self?.showScratchpad() }
        body.onDragTo = { [weak self] maxX in self?.dragChip(toRightEdge: maxX) }
        body.onActivity = { [weak self] in self?.noteActivity() }
        body.setAccessibilityHelp(
            "Shows the Scribe scratchpad. Point at the chip to reveal Stop."
        )

        panel.contentView = body
        applyGeometry()
        updateAccessibility(force: true)
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear // vibrancy needs a transparent window
        panel.hasShadow = true // system shadow ≈ design's 0 4 14 black 40%
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces, // follows the user into every Space…
            .fullScreenAuxiliary, // …including another app's fullscreen space
            .stationary, // Exposé/Mission Control must not drag it around
        ]
        panel.becomesKeyOnlyIfNeeded = true // see ChipPanel
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true // click-through until the pointer arrives
        panel.title = "Scribe Recording"
        panel.alphaValue = 0
    }

    /// Nine-part rounded mask for the behind-window blur (the same technique
    /// the scratchpad uses — a fixed-size mask stops covering the view the
    /// moment the chip changes width, which it does on every hover).
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private static func elapsedAttributedString(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            // SF Mono, tabular figures (design tokens) — the clock must not
            // reflow as the digits change.
            .font: Formatting.elapsedFont(ofSize: Metrics.elapsedFontSize, weight: .medium),
            .foregroundColor: ChipPalette.elapsedText,
        ])
    }

    // MARK: - Geometry

    /// Size the elapsed label needs. Taken from the LABEL, not from
    /// `NSAttributedString.size()`: the attributed-string measurement came out
    /// ~2 pt narrower than what `NSTextField` actually draws, and the chip —
    /// sized from it — clipped the clock's last digit ("00:0"). Caught by
    /// looking at a live screenshot, which is the only place it showed.
    private var clockSize: NSSize {
        let fitting = elapsedLabel.fittingSize
        return NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
    }

    /// Chip width for a state. The elapsed clock is measured, not guessed, so
    /// an hour-long meeting (`1:02:03`) widens the chip instead of clipping.
    func chipSize(hovered: Bool) -> NSSize {
        let clock = clockSize.width
        let width: CGFloat = hovered
            ? Metrics.padLeading + Metrics.dotSide + Metrics.gapHover + clock
                + Metrics.gapHover + stopButton.fittingPillWidth + Metrics.padTrailingHover
            : Metrics.padLeading + Metrics.dotSide + Metrics.gapResting + clock
                + Metrics.padTrailingResting
        return NSSize(width: ceil(width), height: Metrics.height)
    }

    /// The screen the chip lives on: the one the user is working on (which,
    /// for a background accessory app, is the screen holding the active app's
    /// key window), falling back to the menu-bar screen.
    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    /// Sizes the chip for the current state and pins it to the top-right of
    /// the target screen (design 4a), honouring any horizontal drag.
    private func applyGeometry() {
        let size = chipSize(hovered: isHovered)
        guard let screen = targetScreen() else {
            panel.setContentSize(size)
            layoutChipContents()
            return
        }
        let band = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        let y = screen.frame.maxY - band - Metrics.belowMenuBarGap - size.height
        let inset = min(max(rightInset, 4), max(screen.frame.width - size.width - 4, 4))
        rightInset = inset
        let origin = NSPoint(x: screen.frame.maxX - inset - size.width, y: y)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        layoutChipContents()
    }

    private func layoutChipContents() {
        let bounds = body.bounds
        effectView.frame = bounds
        dotView.frame = NSRect(
            x: Metrics.padLeading,
            y: (bounds.height - Metrics.dotSide) / 2,
            width: Metrics.dotSide,
            height: Metrics.dotSide
        )
        let gap = isHovered ? Metrics.gapHover : Metrics.gapResting
        let clock = clockSize
        elapsedLabel.frame = NSRect(
            x: dotView.frame.maxX + gap,
            y: (bounds.height - clock.height) / 2,
            width: clock.width,
            height: clock.height
        )
        let pillWidth = stopButton.fittingPillWidth
        stopButton.frame = NSRect(
            x: bounds.maxX - Metrics.padTrailingHover - pillWidth,
            y: (bounds.height - Metrics.stopHeight) / 2,
            width: pillWidth,
            height: Metrics.stopHeight
        )
    }

    /// Horizontal reposition (design 4a). The y stays on the top edge and the
    /// chip is clamped inside the screen, so it can never be dragged out of
    /// sight — it is a consent surface.
    private func dragChip(toRightEdge maxX: CGFloat) {
        guard let screen = targetScreen() else { return }
        rightInset = screen.frame.maxX - maxX
        applyGeometry()
    }

    // MARK: - Visibility gating

    /// Whether the status item is off screen right now — the second half of
    /// design 4a's visibility condition.
    ///
    /// HOW THIS IS DECIDED, AND HOW RELIABLE IT IS (measured, not assumed —
    /// 2026-08-19, macOS 26.2, 14" notched display).
    ///
    /// PRIMARY SIGNAL: is any window at the status window level on screen.
    /// Status items — Control Centre's, the clock's, every app's, ours — are
    /// windows at `kCGStatusWindowLevel` (25), and `CGWindowListCopyWindowInfo`
    /// with `.optionOnScreenOnly` lists only what is on the CURRENT Space.
    /// Measured: on the desktop Space that list contains status-level windows;
    /// inside another app's fullscreen Space it contains none. The menu bar is
    /// showing iff its status items are. No permission is required for this
    /// query (window bounds, level and owner are unprivileged; only window
    /// TITLES need Screen Recording, and this reads no titles), no private API
    /// is involved, and it costs one array walk a second while recording.
    ///
    /// WHY NOT THE OBVIOUS GEOMETRIC TEST. The first implementation compared
    /// `NSScreen.visibleFrame` with `frame`, on the assumption that a hidden
    /// menu bar gives back its 33 pt. Driving a REAL fullscreen space proved
    /// that false on macOS 26: the inset stayed at 33 pt throughout, measured
    /// both from a background app and from inside the fullscreen app itself,
    /// so the chip never appeared. It survives only as the fallback for the
    /// (never yet observed) case where the window list cannot be read, since
    /// on older systems it is the documented behaviour.
    ///
    /// SIGNALS DELIBERATELY NOT USED. `NSApplication.presentationOptions` only
    /// describes what THIS app asked for — Scribe asks for nothing — so it
    /// says nothing about the app that went fullscreen. The `_HIHideMenuBar`
    /// global preference only says the user turned auto-hide ON, not whether
    /// the bar is hidden at this instant. `NSMenu.menuBarVisible()` measured
    /// `true` in a fullscreen space, so it is a fallback corroborator only.
    ///
    /// THE TRANSIENT REVEAL should come out right for free — when the pointer
    /// goes to the top edge and the menu bar slides down, its status items
    /// rejoin the on-screen list, this returns `false` within one tick and the
    /// chip dismisses, which is what design 3b means by the indicator never
    /// being duplicated — but that is REASONING, NOT A MEASUREMENT: the reveal
    /// is driven by real pointer movement and a warped cursor does not trigger
    /// it, so it could not be driven from a script. Belt and braces either
    /// way: the chip sits a full menu-bar band below the top edge and below
    /// `.mainMenu` in the window levels, so a revealed menu bar draws above it
    /// rather than through it, and the worst case is two indicators for a few
    /// seconds instead of none.
    static func statusItemIsOffScreen(on screen: NSScreen?) -> Bool {
        if let onScreen = statusLevelWindowIsOnScreen() {
            return !onScreen
        }
        guard let screen else { return false }
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        if inset < Metrics.menuBarInsetThreshold { return true }
        return !NSMenu.menuBarVisible()
    }

    /// `nil` when the window list cannot be read at all (never observed).
    private static func statusLevelWindowIsOnScreen() -> Bool? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == statusLevel }
    }

    /// The 4a gate: capturing AND the status item off screen.
    func shouldBeVisible() -> Bool {
        isRecording && Self.statusItemIsOffScreen(on: targetScreen())
    }

    private func evaluateVisibility() {
        // The gallery pins the chip in a fixed state at a fixed place; the
        // live gate would move or hide it mid-screenshot.
        guard !galleryFrozen else { return }
        applyVisibility(shouldBeVisible())
    }

    private func applyVisibility(_ shouldShow: Bool) {
        shouldShow ? present() : dismiss()
    }

    /// 180 ms fade in (design 4a: "the same 180 ms fade as the scratchpad").
    /// Motion-free by construction — opacity only — so Reduce Motion changes
    /// nothing here except the dot's pulse.
    private func present() {
        guard !isPresented else { return }
        isPresented = true
        refreshElapsed()
        applyGeometry()
        applyPulse()
        panel.alphaValue = 0
        panel.orderFrontRegardless() // never activates Scribe
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        startPointerTimer()
        scheduleIdleFade()
        announceArrival()
        logger.info("Recording chip shown — capturing with the status item off screen (design 4a).")
    }

    private func dismiss() {
        guard isPresented else { return }
        isPresented = false
        stopPointerTimer()
        idleFadeWork?.cancel()
        idleFadeWork = nil
        setHovered(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isPresented else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// VoiceOver has no way to discover a window that never takes focus, and
    /// this one appears precisely when the status item — the surface a
    /// VoiceOver user would otherwise poll — has gone off screen. The
    /// announcement carries the state AND the keyboard route to Stop, since
    /// the chip's own pill is a pointer affordance.
    private func announceArrival() {
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: """
                Scribe is recording. The menu bar is hidden, so the recording chip is showing. \
                Press Option-Command-N for the scratchpad, then Command-Return to stop.
                """,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: - Hover / click-through

    /// Hover reveal + the click-through gate (design 4a).
    ///
    /// AppKit has no per-region click-through: `ignoresMouseEvents` is a
    /// property of the WHOLE window, and a view whose `hitTest` returns nil
    /// still leaves the click swallowed by the window rather than passed to
    /// the app underneath. So the gate is the pointer's position, sampled at
    /// 30 Hz from `NSEvent.mouseLocation` (no event monitor, no CGEventTap and
    /// therefore no Accessibility permission — SPEC §5): outside the chip the
    /// window is transparent to every click, inside it the chip is live.
    /// `hitMargin` widens the live region slightly so a fast click that beats
    /// the next sample still lands on the chip.
    private func pollPointer() {
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let live = frame.insetBy(dx: -Metrics.hitMargin, dy: -Metrics.hitMargin).contains(mouse)
        panel.ignoresMouseEvents = !live
        let hovering = frame.contains(mouse)
        if hovering != isHovered {
            setHovered(hovering)
        }
        if live {
            noteActivity()
        }
    }

    /// Resting ⇄ hover (design 4a: gap 6→8, right padding 10→4, border 16%→20%,
    /// Stop pill revealed). The chip grows LEFTWARD — its right edge is
    /// pinned — so the pointer never falls out of the chip it just entered.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        stopButton.isHidden = !hovered
        body.layer?.borderColor = (hovered ? ChipPalette.borderHover : ChipPalette.border).cgColor
        applyGeometry()
        updateAccessibility(force: true)
    }

    private func startPointerTimer() {
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: Metrics.pointerPoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func stopPointerTimer() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel.ignoresMouseEvents = true
    }

    // MARK: - Idle fade

    /// Design 4a: 60 % after 4 s idle, and it NEVER fully hides — the floor is
    /// the consent guarantee, so this only ever animates between 1 and 0.6.
    private func scheduleIdleFade() {
        idleFadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeToIdle() }
        }
        idleFadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.idleDelay, execute: work)
    }

    private func fadeToIdle() {
        guard isPresented, !isHovered else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = Metrics.idleAlpha
        }
    }

    /// Pointer activity over the chip — back to full opacity, re-arm the idle
    /// timer.
    private func noteActivity() {
        guard isPresented else { return }
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Metrics.fadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        scheduleIdleFade()
    }

    // MARK: - State

    private func subscribeToEvents() {
        eventTask = Task { [weak self, coordinator] in
            for await event in coordinator.events() {
                guard let self else { return }
                if case .stateChanged(let state) = event {
                    apply(state)
                }
            }
        }
    }

    private func apply(_ state: SessionDisplayState) {
        let recording = state == .recording
        guard recording != isRecording else { return }
        isRecording = recording
        applyPulse()
        evaluateVisibility()
    }

    /// Re-evaluates on the events that can move the status item off (or back
    /// on) screen without any coordinator state change: entering/leaving a
    /// fullscreen space, display reconfiguration, another app coming forward
    /// with its own menu-bar posture.
    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        observers = [
            workspace.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            },
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            },
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            },
        ]
    }

    /// A display or Space change can move the status item off (or back on)
    /// screen with no coordinator state change at all.
    private func environmentChanged() {
        evaluateVisibility()
        applyGeometry()
    }

    private func startTickTimer() {
        let timer = Timer(timeInterval: Metrics.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// One second: re-check the gate (fullscreen/auto-hide changes that post
    /// no notification land here) and advance the clock.
    private func tick() {
        evaluateVisibility()
        guard isPresented else { return }
        refreshElapsed()
    }

    /// SPEC §4.1 two-clocks rule: elapsed comes from the coordinator's WALL
    /// clock, exactly like the menu-bar capsule and the scratchpad header —
    /// never from a counter this window keeps.
    private func refreshElapsed() {
        let text = Formatting.elapsedString(coordinator.elapsed())
        guard text != elapsedText else {
            updateAccessibility(force: false)
            return
        }
        let widthChanged = text.count != elapsedText.count
        elapsedText = text
        elapsedLabel.attributedStringValue = Self.elapsedAttributedString(text)
        if widthChanged {
            applyGeometry() // an hour rolled over — the chip grows
        } else {
            layoutChipContents()
        }
        updateAccessibility(force: false)
    }

    /// 1.6 s pulse, 100 % → 35 % (design 4a: "never hidden while capturing").
    /// Reduce Motion gets a static, fully opaque dot — the indicator itself is
    /// never the thing that disappears.
    private func applyPulse() {
        dotView.layer?.removeAnimation(forKey: Self.pulseKey)
        dotView.layer?.opacity = 1
        guard isRecording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = Metrics.pulseFloor
        pulse.duration = Metrics.pulsePeriod / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotView.layer?.add(pulse, forKey: Self.pulseKey)
    }

    // MARK: - Actions

    @objc private func stopTapped() {
        logger.info("Stop pressed on the recording chip.")
        Task { await coordinator.stop() } // → processing → fusion (SPEC §4.4)
    }

    private func showScratchpad() {
        guard let onShowScratchpad else {
            logger.error("Recording chip pressed but no scratchpad handler is wired.")
            return
        }
        onShowScratchpad()
    }

    // MARK: - Accessibility

    /// The chip reads as ONE control: state + spoken elapsed as its label, a
    /// press that shows the scratchpad, and Stop as a custom action.
    ///
    /// The elapsed clock is spoken in units — `MenuBarController.spokenElapsed`
    /// is reused verbatim so "24:16" is announced as "24 minutes 16 seconds"
    /// in both places rather than as two numbers. The dot and the clock label
    /// are marked non-elements so nothing announces the digits raw.
    ///
    /// The Stop pill is only in the AX tree while the chip is hovered (it is
    /// `isHidden` otherwise, which removes it), and VoiceOver navigation moves
    /// no pointer — hence the custom action, which is available in both
    /// states and is the VoiceOver user's stop path.
    private func updateAccessibility(force: Bool) {
        let elapsed = coordinator.elapsed()
        let spoken = MenuBarController.spokenElapsed(elapsed)
        guard force || spoken != lastAccessibleElapsed else { return }
        lastAccessibleElapsed = spoken
        body.setAccessibilityLabel("Scribe — recording, \(spoken)")
        body.setAccessibilityValue(spoken)
        body.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Stop recording") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.stopTapped()
                    return true
                }
            },
            NSAccessibilityCustomAction(name: "Show scratchpad") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.showScratchpad()
                    return true
                }
            },
        ])
    }

    // MARK: - Gallery test seam (dev tooling — App/UIGallery.swift)

    /// The chip window, for placement + `windowNumber` in the gallery.
    var galleryWindow: NSWindow { panel }

    /// Presents the chip in a FIXED state for a screenshot. The real chip only
    /// exists while a session is live AND the menu bar is hidden — neither of
    /// which a capture harness can arrange — so this sets the two state inputs
    /// (elapsed, hover) and runs the production layout, deliberately bypassing
    /// `present()` so no timer overwrites the clock and no gate hides it.
    func galleryPresent(elapsed: TimeInterval, hovered: Bool) {
        galleryFrozen = true
        isRecording = true
        elapsedText = Formatting.elapsedString(elapsed)
        elapsedLabel.attributedStringValue = Self.elapsedAttributedString(elapsedText)
        setHovered(hovered)
        applyGeometry()
        applyPulse()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    // MARK: - Probe seam (dev tooling)

    /// `-chipProbe YES` on the command line: exercise every decision this
    /// window makes and print it, then exit. Sibling of MenuBarController's
    /// `-a11yProbe` seam, and it exists for the same reason — plus one more:
    /// the chip's whole contract is about geometry and hit-testing that a
    /// screenshot cannot show and that a locked screen cannot be driven
    /// through at all. Pair with the stub capture engine so no microphone
    /// opens:
    ///
    ///     Scribe.app/Contents/MacOS/Scribe -chipProbe YES \
    ///         -debugUseStubCapture YES -setupPhase 5
    ///
    /// What it does NOT prove: that a real pointer hovering a real chip over a
    /// real fullscreen app reveals the pill, that a drag reads as a drag, or
    /// that the click-through gate lets a click reach the app underneath.
    /// Those need an unlocked screen.
    private func runChipProbe() {
        Task { @MainActor in
            let screen = targetScreen()
            print("PROBE\tstart")
            if let screen {
                let inset = screen.frame.maxY - screen.visibleFrame.maxY
                print("""
                SCREEN\tframe=\(Self.rect(screen.frame))\tvisible=\(Self.rect(screen.visibleFrame))\
                \ttopInset=\(String(format: "%.1f", inset))\tsafeAreaTop=\(screen.safeAreaInsets.top)\
                \tstatusBarThickness=\(NSStatusBar.system.thickness)
                """)
            }
            print("""
            DETECT\tstatusItemIsOffScreen=\(Self.statusItemIsOffScreen(on: screen))\
            \tNSMenu.menuBarVisible=\(NSMenu.menuBarVisible())\
            \tpresentationOptions=\(NSApp.presentationOptions.rawValue)
            """)

            // Gate matrix — the 4a rule, both inputs forced.
            for recording in [false, true] {
                for hidden in [false, true] {
                    isRecording = recording
                    let gate = recording && hidden
                    print("GATE\trecording=\(recording)\tstatusItemOffScreen=\(hidden)\tshow=\(gate)")
                }
            }
            isRecording = true

            // Geometry: both specimens, and the top-right placement.
            for hovered in [false, true] {
                setHovered(hovered)
                applyGeometry()
                let tag = hovered ? "hover" : "resting"
                print("""
                GEOMETRY\t\(tag)\tsize=\(Self.size(chipSize(hovered: hovered)))\
                \tframe=\(Self.rect(panel.frame))\tstopHidden=\(stopButton.isHidden)\
                \tstopFrame=\(Self.rect(stopButton.frame))\tdotFrame=\(Self.rect(dotView.frame))\
                \tclockFrame=\(Self.rect(elapsedLabel.frame))
                """)
                if let screen {
                    let band = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
                    print("""
                    PLACEMENT\t\(tag)\trightGap=\(String(format: "%.1f", screen.frame.maxX - panel.frame.maxX))\
                    \ttopGap=\(String(format: "%.1f", screen.frame.maxY - panel.frame.maxY))\
                    \tmenuBarBand=\(band)\tclearsBand=\(panel.frame.maxY <= screen.frame.maxY - band)\
                    \tonScreen=\(screen.frame.contains(panel.frame))
                    """)
                }
            }

            // Click-through gate at four pointer positions (the poll's own
            // arithmetic, fed synthetic locations).
            setHovered(false)
            applyGeometry()
            let frame = panel.frame
            let probes: [(String, NSPoint)] = [
                ("centre", NSPoint(x: frame.midX, y: frame.midY)),
                ("edge+2", NSPoint(x: frame.maxX + 2, y: frame.midY)),
                ("edge+40", NSPoint(x: frame.maxX + 40, y: frame.midY)),
                ("below", NSPoint(x: frame.midX, y: frame.minY - 40)),
            ]
            for (tag, point) in probes {
                let live = frame.insetBy(dx: -Metrics.hitMargin, dy: -Metrics.hitMargin).contains(point)
                print("HITTEST\t\(tag)\tpoint=\(Self.point(point))\tclickThrough=\(!live)\thover=\(frame.contains(point))")
            }

            // Drag clamping — horizontal only, never off screen.
            if let screen {
                let restingWidth = chipSize(hovered: false).width
                for target in [screen.frame.maxX - 400, screen.frame.minX - 200, screen.frame.maxX + 200] {
                    let beforeY = panel.frame.minY
                    dragChip(toRightEdge: target)
                    print("""
                    DRAG\ttargetMaxX=\(String(format: "%.0f", target))\tframe=\(Self.rect(panel.frame))\
                    \tyUnchanged=\(abs(panel.frame.minY - beforeY) < 0.5)\
                    \tinsideScreen=\(screen.frame.contains(panel.frame))\twidth=\(restingWidth)
                    """)
                }
                rightInset = Metrics.rightInset
                applyGeometry()
            }

            // Accessibility readback — what an AT client gets off the chip.
            for hovered in [false, true] {
                setHovered(hovered)
                updateAccessibility(force: true)
                let actions = body.accessibilityCustomActions()?.map(\.name).joined(separator: "|") ?? "none"
                print("""
                A11Y\t\(hovered ? "hover" : "resting")\trole=\(body.accessibilityRole()?.rawValue ?? "nil")\
                \tlabel=\(body.accessibilityLabel() ?? "nil")\tvalue=\((body.accessibilityValue() as? String) ?? "nil")\
                \thelp=\(body.accessibilityHelp() ?? "nil")\tactions=\(actions)\
                \tstopInTree=\(!stopButton.isHidden)\tstopLabel=\(stopButton.accessibilityLabel() ?? "nil")\
                \tstopKeyEquivalent=⌘\(stopButton.keyEquivalent == "\r" ? "Return" : stopButton.keyEquivalent)\
                \tclockIsElement=\(elapsedLabel.isAccessibilityElement())\tdotIsElement=\(dotView.isAccessibilityElement())
                """)
            }
            for seconds in [0, 1, 59, 61, 1_456, 3_661] {
                print("SPOKEN\t\(seconds)s\t\(MenuBarController.spokenElapsed(TimeInterval(seconds)))")
            }

            // Fade contract: appear, idle floor, wake — through the REAL
            // present()/fade path, with the gate forced open.
            galleryFrozen = true // suspend the live gate for the fade section
            print("MOTION\treduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)\tpulseAttached=\(dotView.layer?.animation(forKey: Self.pulseKey) != nil)")
            applyVisibility(true)
            print("FADE\tpresented=\(isPresented)\tvisible=\(panel.isVisible)\tignoresMouse=\(panel.ignoresMouseEvents)")
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("FADE\tafterSummon\talpha=\(String(format: "%.2f", panel.alphaValue))")
            try? await Task.sleep(nanoseconds: UInt64((Metrics.idleDelay + 0.6) * 1_000_000_000))
            print("""
            FADE\tafterIdle\talpha=\(String(format: "%.2f", panel.alphaValue))\
            \tneverHidden=\(panel.alphaValue >= Metrics.idleAlpha && panel.isVisible)
            """)
            noteActivity()
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("FADE\tafterActivity\talpha=\(String(format: "%.2f", panel.alphaValue))")
            print("MOTION\tpulseAttachedWhileShown=\(dotView.layer?.animation(forKey: Self.pulseKey) != nil)")
            galleryFrozen = false

            // The Stop pill's REAL action, through the button (not the
            // selector directly), while nothing is recording — proves the
            // wiring reaches the coordinator.
            let actionName = stopButton.action.map { NSStringFromSelector($0) } ?? "nil"
            print("ACTION\tstopTarget=\(stopButton.target != nil)\tstopAction=\(actionName)")
            var pressed = false
            body.onPress = { pressed = true }
            _ = body.accessibilityPerformPress()
            print("ACTION\tbodyPressShowsScratchpad=\(pressed)")

            // Gate closing hides it again (stop → processing).
            isRecording = false
            evaluateVisibility()
            try? await Task.sleep(nanoseconds: 400_000_000)
            print("FADE\tafterGateClosed\tpresented=\(isPresented)\tvisible=\(panel.isVisible)")

            // Put everything the static phase forced back the way the app
            // built it, before the live phase runs on the REAL state.
            body.onPress = { [weak self] in self?.showScratchpad() }
            setHovered(false)
            rightInset = Metrics.rightInset
            isRecording = coordinator.displayState == .recording
            applyGeometry()
            evaluateVisibility()

            let liveSeconds = UserDefaults.standard.integer(forKey: "chipLive")
            guard liveSeconds > 0 else {
                print("PROBE\tcomplete")
                exit(0)
            }
            await runLivePhase(seconds: liveSeconds)
        }
    }

    /// `-chipLive <seconds>`: the second half of the probe, and the only half
    /// that proves anything about the real world. It starts a REAL session
    /// through the coordinator (pair it with `-debugUseStubCapture YES` so no
    /// microphone opens) — the same call the status menu's Start Meeting item
    /// makes — and then reports, once a second, what the live gate and the
    /// live window are actually doing, while an operator drives the pointer
    /// and takes screenshots from outside. It stops the session and exits.
    ///
    /// The point is the environment: whether the chip shows depends on
    /// `NSScreen.visibleFrame` collapsing to the full frame in a fullscreen
    /// space / with the menu bar auto-hidden, which nothing in-process can
    /// fake and no unit test can assert.
    private func runLivePhase(seconds: Int) async {
        print("LIVE\tstarting a real session (stub capture) — the Start Meeting path")
        do {
            let session = try await coordinator.start()
            print("LIVE\tstarted\tsession=\(session.id.uuidString)")
        } catch {
            print("LIVE\tstart-failed\t\(error)")
            exit(1)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < deadline {
            let screen = targetScreen()
            let visible = screen?.visibleFrame ?? .zero
            let full = screen?.frame ?? .zero
            let inset = String(format: "%.1f", full.maxY - visible.maxY)
            let alpha = String(format: "%.2f", panel.alphaValue)
            print("LIVE\t\(Int(coordinator.elapsed()))s\tstatusItemOffScreen=\(Self.statusItemIsOffScreen(on: screen))\ttopInset=\(inset)\tgate=\(shouldBeVisible())\tpresented=\(isPresented)\tonScreen=\(panel.isVisible)\talpha=\(alpha)\thovered=\(isHovered)\tclickThrough=\(panel.ignoresMouseEvents)\tframe=\(Self.rect(panel.frame))\twindowNumber=\(panel.windowNumber)\tlabel=\(body.accessibilityLabel() ?? "nil")")
            fflush(stdout)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("LIVE\tstopping")
        await coordinator.stop()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        print("LIVE\tafterStop\tpresented=\(isPresented)\tonScreen=\(panel.isVisible)\tgate=\(shouldBeVisible())")
        print("PROBE\tcomplete")
        exit(0)
    }

    private static func rect(_ rect: NSRect) -> String {
        String(format: "(%.0f,%.0f %.0f×%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func size(_ size: NSSize) -> String {
        String(format: "%.0f×%.0f", size.width, size.height)
    }

    private static func point(_ point: NSPoint) -> String {
        String(format: "(%.0f,%.0f)", point.x, point.y)
    }
}
