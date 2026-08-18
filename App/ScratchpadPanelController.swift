import AppKit
import ScratchpadKit
import SessionKit
import os

// MARK: - Panel subclass

/// Nonactivating borderless panel (SPEC §5: floats above other windows, never
/// steals key focus from the meeting app). The controller sets
/// `becomesKeyOnlyIfNeeded`, so a click on the text body (a first-responder
/// subview) makes the panel key — enabling Esc/Enter — WITHOUT activating the
/// app (design 2b: "KEY FOCUS STAYS IN MEETING APP").
private final class HUDPanel: NSPanel {
    /// Esc handler; returning `true` consumes the key event.
    var onEscape: (() -> Bool)?

    override var canBecomeKey: Bool { true } // keyboard input without app activation
    override var canBecomeMain: Bool { false } // palettes never become main

    /// Esc dismisses the panel, scoped to this window (SPEC §5 — no global
    /// NSEvent monitor). Key equivalents are matched before the responder
    /// chain, so this wins even while the text view is first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.function)
        if event.keyCode == 53 /* escape */, modifiers.isEmpty, onEscape?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Header button

/// Text-on-fill HUD button (design 1b: 12 pt medium title, radius 6, padding
/// 3×10, 16% fill with a 26% hover fill). Fill is a layer; hover via a
/// tracking area — NSButton has no native hover state.
private final class HUDButton: NSButton {

    private let normalFill: NSColor
    private let hoverFill: NSColor
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    init(title: String, titleColor: NSColor, fill: NSColor, hoverFill: NSColor) {
        self.normalFill = fill
        self.hoverFill = hoverFill
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = fill.cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: titleColor,
        ])
        // Padding 3×10 (design 1b) — the title centers in the button bounds,
        // so size the button around the title instead of default hugging.
        let titleSize = attributedTitle.size()
        widthAnchor.constraint(
            equalToConstant: ceil(titleSize.width) + 2 * 10
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: ceil(titleSize.height) + 2 * 3
        ).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HUDButton is created in code")
    }

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
        layer?.backgroundColor = (isHovering ? hoverFill : normalFill).cgColor
        CATransaction.commit()
    }
}

// MARK: - Body text view

/// Plain-text scratchpad body. Rich text OFF (SPEC §5: plain text, no
/// formatting). Enter is the BURST BOUNDARY (one fragment per line UX): the
/// composer freezes the row and the view clears — a line break is never
/// inserted. Placeholder (design 2a, white 32%) is drawn by hand; NSTextView
/// has none.
private final class BodyTextView: NSTextView {

    /// Fired for Enter (and its editor variants); the controller freezes the
    /// burst and clears the view.
    var onNewline: (() -> Void)?

    var placeholderText: String = "" {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BodyTextView is created in code")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        (placeholderText as NSString).draw(
            at: textContainerOrigin,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white.withAlphaComponent(0.32),
            ]
        )
    }

    override func doCommand(by selector: Selector) {
        // All explicit-newline editor commands count as burst boundaries
        // (Enter, ⌥↩, ⇧↩ variants route here); none inserts a line break.
        if selector == #selector(insertNewline(_:))
            || selector == #selector(insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(insertLineBreak(_:)) {
            onNewline?()
        } else {
            super.doCommand(by: selector)
        }
    }
}

// MARK: - Controller

/// Scratchpad panel (SPEC §4.3 + §5; design/README "Scratchpad panel", dark
/// HUD primary per design 1b — the light variant 1c is deliberately not
/// built). Floating `.nonactivatingPanel` summoned by ⌥⌘N.
///
/// COMPOSER COUPLING (honest documentation, SPEC §4.3 pending-row pattern):
/// `ScribeApp` owns a `FragmentComposer` and hands it to
/// `SessionCoordinator.attach(_:)`, which installs the composer's
/// `onPersistPending`/`onFreeze` callbacks to drive the STORE. Those
/// callbacks are coordinator-owned — this panel NEVER touches them. The panel
/// only drives the composer's inputs: `edit` on text-did-change,
/// `newline` on Enter, `heartbeat` from a 100 ms timer while visible.
///
/// "Saved" tick: the panel cannot observe persists (the callbacks aren't
/// ours), so the tick is driven by the panel's OWN ~1 s text-did-change
/// debounce, mirroring the composer's `persistDebounce` cadence (1.0 s in
/// both places — change them together). The tick therefore appears at
/// (within one heartbeat tick of) the persist, not on a store confirmation;
/// it additionally fires on the two burst boundaries (newline, ≥3 s pause
/// mirror) where a persist provably just happened through the coordinator.
///
/// Burst-boundary mirror: the composer freezes on a ≥3 s pause via
/// `heartbeat`. Because the panel sends the FULL text on every edit, it must
/// clear the view at the same boundary — otherwise resumed typing would send
/// the frozen line back in as the start of a new pending row (duplicated
/// fragment content for fusion). The mirror clears at 3.15 s (composer's
/// 3.0 s `burstPause` + one heartbeat-granularity slack) so the freeze lands
/// first; when the panel is hidden the mirror pauses with the heartbeat and
/// re-arms on the next summon (a pause long enough to have frozen clears
/// immediately — the first visible heartbeat then freezes the row).
@MainActor
final class ScratchpadPanelController: NSObject {

    /// Design metrics (design 1b/2a/2b/2e; native materials over hex).
    private enum Metrics {
        static let panelWidth: CGFloat = 306
        static let panelHeight: CGFloat = 218
        static let cornerRadius: CGFloat = 12
        static let summonDuration: CFTimeInterval = 0.18
        static let dismissDuration: CFTimeInterval = 0.14
        static let summonScale: CGFloat = 0.96
        static let pulsePeriod: CFTimeInterval = 1.6
        static let pulseFloor: Float = 0.35
        static let heartbeatInterval: TimeInterval = 0.1
        static let elapsedInterval: TimeInterval = 1.0
        /// Mirror of the composer's 1 s persist debounce (see class docs).
        static let savedTickDebounce: TimeInterval = 1.0
        /// "Saved" holds ~2 s before fading out (design 2e).
        static let savedTickHold: TimeInterval = 2.0
        /// Mirror of the composer's 3 s burstPause + heartbeat slack (class docs).
        static let burstClearDelay: TimeInterval = 3.15
    }

    private static let pulseKey = "scribe.scratchpad.pulse"

    private let logger = Logger(subsystem: "com.example.scribe", category: "scratchpad")
    private let coordinator: SessionCoordinator
    private let composer: FragmentComposer

    private let panel: HUDPanel
    private let container: NSView // scale-animation root (anchor top-center)
    private let effectView: NSVisualEffectView
    private let headerStack = NSStackView()
    private let dotView = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let noMeetingLabel = NSTextField(labelWithString: "No meeting")
    private let spacer = NSView()
    private let savedLabel = NSTextField(labelWithString: "Saved")
    private let hotkeyHint = NSTextField(labelWithString: "⌥⌘N")
    private let stopButton: HUDButton
    private let startButton: HUDButton
    private let hairline = NSView()
    private let bodyView = NSView()
    private let scrollView = NSScrollView()
    private let bodyTextView: BodyTextView
    private let noMeetingHint = NSTextField(
        labelWithString: "Fragments typed here are discarded unless a meeting is recording."
    )

    private var eventTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var heartbeatTimer: Timer?
    private var savedDebounceTimer: Timer?
    private var burstClearTimer: Timer?
    private var savedHideWork: DispatchWorkItem?
    private var lastEditWallClock = Date.distantPast

    /// True between summon and dismiss (including during the animations).
    private var isVisibleToUser = false
    private var isRecording: Bool

    init(coordinator: SessionCoordinator, composer: FragmentComposer) {
        self.coordinator = coordinator
        self.composer = composer
        let rect = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight)
        panel = HUDPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel], // no title bar, no resize, no activation
            backing: .buffered,
            defer: false
        )
        container = NSView(frame: rect)
        effectView = NSVisualEffectView(frame: rect)
        stopButton = HUDButton(
            title: "Stop",
            // Design 1b: #FF6961 text on systemRed 16% fill, 26% on hover.
            titleColor: NSColor(srgbRed: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1),
            fill: NSColor.systemRed.withAlphaComponent(0.16),
            hoverFill: NSColor.systemRed.withAlphaComponent(0.26)
        )
        startButton = HUDButton(
            title: "Start Meeting",
            // Design 2a: white on #0A82FF → system accent (+ native rollover).
            titleColor: .white,
            fill: .controlAccentColor,
            hoverFill: NSColor.controlAccentColor.withSystemEffect(.rollover)
        )
        bodyTextView = BodyTextView()
        isRecording = coordinator.displayState == .recording

        super.init()
        buildContent()
        configurePanel()
        wire()
        renderState()
        subscribeToEvents()
    }

    // MARK: - Build

    private func buildContent() {
        // Dark HUD: hudWindow vibrancy + 0.5 pt white-14% border, radius 12
        // (design 1b; native material wins over the HTML's rgba(30,30,33,.9)).
        container.wantsLayer = true // layer-backs the whole subtree (scale animation)
        container.layer?.cornerRadius = Metrics.cornerRadius
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(
            size: NSSize(width: Metrics.panelWidth, height: Metrics.panelHeight),
            radius: Metrics.cornerRadius
        )
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        // Header (design 1b: 10/12/9 padding, 8 pt gaps, hairline bottom).
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 8
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dotView.heightAnchor.constraint(equalToConstant: 7).isActive = true

        // SF Mono 12 tabular wall-clock elapsed (SPEC §4.1 two-clocks rule —
        // display derives from wall clock, never the session clock).
        elapsedLabel.font = Formatting.elapsedFont(ofSize: 12, weight: .medium)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.9)

        noMeetingLabel.font = NSFont.systemFont(ofSize: 12)
        noMeetingLabel.textColor = NSColor.white.withAlphaComponent(0.5)

        // Greedy spacer between the status group and the hint/button group.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        savedLabel.font = NSFont.systemFont(ofSize: 11)
        savedLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        savedLabel.alphaValue = 0

        hotkeyHint.font = NSFont.systemFont(ofSize: 11)
        hotkeyHint.textColor = NSColor.white.withAlphaComponent(0.35)

        headerStack.addView(dotView, in: .leading)
        headerStack.addView(elapsedLabel, in: .leading)
        headerStack.addView(noMeetingLabel, in: .leading)
        headerStack.addView(spacer, in: .leading)
        headerStack.addView(savedLabel, in: .trailing)
        headerStack.addView(hotkeyHint, in: .trailing)
        headerStack.addView(stopButton, in: .trailing)
        headerStack.addView(startButton, in: .trailing)
        container.addSubview(headerStack)

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hairline)

        // Body: 13 pt system font, ~1.55 CSS line-height (≈ 1.25 AppKit
        // multiple — CSS line-height 1.55 ÷ ~1.2 default leading), white 85%.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        bodyTextView.isRichText = false
        bodyTextView.allowsUndo = true
        bodyTextView.drawsBackground = false
        bodyTextView.backgroundColor = .clear
        bodyTextView.textColor = NSColor.white.withAlphaComponent(0.85)
        bodyTextView.font = NSFont.systemFont(ofSize: 13)
        bodyTextView.defaultParagraphStyle = paragraph
        bodyTextView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraph,
        ]
        bodyTextView.insertionPointColor = .controlAccentColor // design: accent caret
        bodyTextView.focusRingType = .none
        bodyTextView.placeholderText = "Jot a fragment — plain text, saved as you type"
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.autoresizingMask = [.width]
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.heightTracksTextView = false
        bodyTextView.textContainer?.lineFragmentPadding = 0 // body padding owns the margins
        bodyTextView.textContainerInset = .zero

        scrollView.documentView = bodyTextView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.scrollerStyle = .overlay // auto-hides; no chrome on the HUD
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(scrollView)

        noMeetingHint.font = NSFont.systemFont(ofSize: 13)
        noMeetingHint.textColor = NSColor.white.withAlphaComponent(0.32)
        noMeetingHint.lineBreakMode = .byWordWrapping
        noMeetingHint.cell?.wraps = true
        noMeetingHint.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(noMeetingHint)
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bodyView)

        // Layout. scrollView and noMeetingHint occupy the same frame — they
        // are the recording/idle faces of the body, never both visible.
        container.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(
            x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight
        ))
        root.addSubview(container)
        panel.contentView = root
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            headerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            hairline.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 9),
            hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            bodyView.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            bodyView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -14),
            scrollView.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: -16),
            noMeetingHint.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 12),
            noMeetingHint.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 14),
            noMeetingHint.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -14),
        ])
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear // vibrancy needs a transparent window
        panel.hasShadow = true // system shadow ≈ design 0 18 48 black 40%
        panel.hidesOnDeactivate = false // stays up when the meeting app is focused
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces, // visible on every Space
            .fullScreenAuxiliary, // visible over full-screen meeting apps
        ]
        panel.becomesKeyOnlyIfNeeded = true // key only via first-responder clicks (no focus steal)
        panel.isReleasedWhenClosed = false
        panel.title = "Scribe Scratchpad"
    }

    private func wire() {
        panel.onEscape = { [weak self] in
            guard let self else { return false }
            dismiss() // SPEC §5: recording continues — the menu-bar dot is untouched
            return true
        }
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        startButton.target = self
        startButton.action = #selector(startTapped)
        bodyTextView.delegate = self
        bodyTextView.onNewline = { [weak self] in self?.handleNewline() }
    }

    /// Rounded-corner mask for the behind-window vibrancy (the supported way
    /// to clip `NSVisualEffectView`; fixed panel size → computed once).
    private static func roundedMaskImage(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: radius,
            yRadius: radius
        ).fill()
        image.unlockFocus()
        return image
    }

    // MARK: - Visibility

    /// Hotkey path (⌥⌘N via `GlobalHotkey.onSummon`, wired by ScribeApp).
    func toggle() {
        isVisibleToUser ? dismiss() : show()
    }

    /// Menu-bar "Open Scratchpad" path — shows without toggling away.
    func show() {
        guard !isVisibleToUser else { return }
        isVisibleToUser = true
        renderState()
        positionPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        applyContainerAnchor()
        resumeBurstMirrorAfterSummon()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.orderFrontRegardless() // SPEC §5: non-activating present
        // Summon (design 2b): 180 ms ease-out opacity 0→1 + scale .96→1,
        // origin top-center; Reduce Motion → fade only.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.summonDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })
        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = Metrics.summonScale
            scale.toValue = 1.0
            scale.duration = Metrics.summonDuration
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.layer?.add(scale, forKey: "scribe.scratchpad.summon")
        }
        syncTimers()
    }

    /// Dismiss (140 ms; fade + slight scale; Reduce Motion → fade only).
    /// Recording continues (SPEC §5).
    func dismiss() {
        guard isVisibleToUser else { return }
        isVisibleToUser = false
        syncTimers()
        cancelSavedTick()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
            if !reduceMotion {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = Metrics.summonScale
                scale.duration = Metrics.dismissDuration
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                container.layer?.add(scale, forKey: "scribe.scratchpad.dismiss")
            }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    /// Top-center of the screen the pointer is on (multi-monitor safe);
    /// near the menu bar, matching the design 2b mock.
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Metrics.panelWidth / 2,
            y: visible.maxY - Metrics.panelHeight - 20
        ))
    }

    /// Scale origin = top-center (design 2b transform-origin).
    private func applyContainerAnchor() {
        guard let layer = container.layer else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.position = CGPoint(x: frame.midX, y: frame.maxY)
    }

    // MARK: - Recording state

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

    /// Panel has exactly two faces (design 2a): recording, and everything
    /// else — in idle/processing/done/failed there is no session to anchor
    /// fragments to, so the panel shows the honest no-meeting state.
    private func apply(_ state: SessionDisplayState) {
        let recording = state == .recording
        guard recording != isRecording else { return }
        isRecording = recording
        renderState()
    }

    private func renderState() {
        let recording = isRecording
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Dot: pulsing systemRed while recording; static white 25% otherwise
        // (design 1b/2a; 1.6 s pulse, Reduce Motion → static).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotView.layer?.backgroundColor = (
            recording ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.25)
        ).cgColor
        CATransaction.commit()
        dotView.layer?.removeAnimation(forKey: Self.pulseKey)
        if recording, !reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = Metrics.pulseFloor
            pulse.duration = Metrics.pulsePeriod / 2
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dotView.layer?.add(pulse, forKey: Self.pulseKey)
        }

        elapsedLabel.isHidden = !recording
        noMeetingLabel.isHidden = recording
        stopButton.isHidden = !recording
        startButton.isHidden = recording
        scrollView.isHidden = !recording
        noMeetingHint.isHidden = recording

        if !recording {
            // No session: nothing pending can survive (coordinator.stop()
            // already flushed the composer). Discard the view's text.
            bodyTextView.string = ""
            cancelSavedTick()
            burstClearTimer?.invalidate()
            burstClearTimer = nil
        }
        syncTimers()
    }

    // MARK: - Timers

    /// Elapsed/heartbeat live only while the panel is visible; the 1 s
    /// elapsed tick additionally requires recording (SPEC §4.1 wall clock).
    private func syncTimers() {
        let visible = isVisibleToUser
        if visible, heartbeatTimer == nil {
            heartbeatTimer = scheduleTimer(interval: Metrics.heartbeatInterval, repeats: true) { [weak self] in
                // 100 ms heartbeat drives the composer's trailing persist
                // debounce and ≥3 s pause freeze (SPEC §4.3).
                guard let self, self.isRecording else { return }
                self.composer.heartbeat(at: self.coordinator.nowOffset())
            }
        }
        if visible, isRecording {
            updateElapsed()
            if elapsedTimer == nil {
                elapsedTimer = scheduleTimer(interval: Metrics.elapsedInterval, repeats: true) { [weak self] in
                    self?.updateElapsed()
                }
            }
        } else {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
        if !visible {
            savedDebounceTimer?.invalidate()
            savedDebounceTimer = nil
            burstClearTimer?.invalidate()
            burstClearTimer = nil
        }
    }

    private func scheduleTimer(
        interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            MainActor.assumeIsolated { handler() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func updateElapsed() {
        elapsedLabel.stringValue = Formatting.elapsedString(coordinator.elapsed())
    }

    // MARK: - Text → composer

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === bodyTextView else { return }
        // No-meeting typing never reaches the composer — there is no session
        // to anchor to (SPEC §5; the body view is hidden in that state, this
        // guard is defensive).
        guard isRecording else { return }
        composer.edit(bodyTextView.string, at: coordinator.nowOffset())
        lastEditWallClock = Date()
        restartSavedDebounce()
        restartBurstClearTimer()
    }

    /// Enter: freeze the burst (SPEC §4.3 explicit-newline boundary) and
    /// clear the view — one fragment per line UX; the composer's freeze→
    /// store write runs synchronously through the coordinator-owned callback,
    /// so the tick below fires on an actual persist.
    private func handleNewline() {
        guard isRecording else { return }
        let hadText = !bodyTextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composer.newline(at: coordinator.nowOffset())
        bodyTextView.string = ""
        savedDebounceTimer?.invalidate()
        savedDebounceTimer = nil
        burstClearTimer?.invalidate()
        burstClearTimer = nil
        if hadText {
            showSavedTick()
        }
    }

    /// Panel-local mirror of the composer's ≥3 s pause freeze (class docs):
    /// clears the view ~150 ms AFTER the heartbeat-driven freeze lands, so a
    /// resumed burst starts from an empty row instead of duplicating the
    /// frozen text. The freeze itself persisted the row — tick is honest.
    private func restartBurstClearTimer() {
        burstClearTimer?.invalidate()
        burstClearTimer = scheduleTimer(interval: Metrics.burstClearDelay, repeats: false) { [weak self] in
            self?.clearViewAtBurstBoundary()
        }
    }

    private func clearViewAtBurstBoundary() {
        let hadText = !bodyTextView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        bodyTextView.string = ""
        savedDebounceTimer?.invalidate()
        savedDebounceTimer = nil
        if hadText {
            showSavedTick()
        }
    }

    /// After a hidden period the heartbeat (and this mirror) were paused. If
    /// the pause already exceeded the burst boundary, the first visible
    /// heartbeat will freeze the pending row — clear the view now; otherwise
    /// re-arm the mirror for the remainder.
    private func resumeBurstMirrorAfterSummon() {
        let text = bodyTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !text.isEmpty else { return }
        let idle = Date().timeIntervalSince(lastEditWallClock)
        if idle >= Metrics.burstClearDelay {
            clearViewAtBurstBoundary()
        } else {
            burstClearTimer?.invalidate()
            burstClearTimer = scheduleTimer(
                interval: Metrics.burstClearDelay - idle,
                repeats: false
            ) { [weak self] in
                self?.clearViewAtBurstBoundary()
            }
        }
    }

    // MARK: - Saved tick (design 2e)

    /// Panel's own ~1 s debounce mirroring the composer's persist cadence —
    /// see class docs for the honest coupling story.
    private func restartSavedDebounce() {
        savedDebounceTimer?.invalidate()
        savedDebounceTimer = scheduleTimer(interval: Metrics.savedTickDebounce, repeats: false) { [weak self] in
            self?.showSavedTick()
        }
    }

    private func showSavedTick() {
        savedHideWork?.cancel()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            savedLabel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                savedLabel.animator().alphaValue = 1
            })
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideSavedTick()
        }
        savedHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.savedTickHold, execute: work)
    }

    private func hideSavedTick() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            savedLabel.alphaValue = 0
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                savedLabel.animator().alphaValue = 0
            })
        }
    }

    private func cancelSavedTick() {
        savedDebounceTimer?.invalidate()
        savedDebounceTimer = nil
        savedHideWork?.cancel()
        savedHideWork = nil
        savedLabel.alphaValue = 0
    }

    // MARK: - Header actions

    /// Stop finalizes pending segments → processing → fusion (SPEC §4.4).
    /// Header state flips via `.stateChanged` events.
    @objc private func stopTapped() {
        Task { await coordinator.stop() }
    }

    @objc private func startTapped() {
        Task { @MainActor in
            do {
                try await coordinator.start()
            } catch {
                logger.error("Meeting start failed from panel: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - NSTextViewDelegate

extension ScratchpadPanelController: NSTextViewDelegate {}
