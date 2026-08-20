import AppKit
import ScratchpadKit
import SessionKit
import os

// MARK: - HUD palette

/// Text colours for the dark HUD (design 1b/2a/2e).
///
/// CONTRAST CORRECTION (UX review finding 12). The artboards' small-text greys
/// — placeholder + no-meeting hint at white 32 %, the ⌥⌘N hint at 35 %,
/// "Saved" at 45 % — measure ≈2.9:1 / 3.1:1 / 4.4:1 against the HUD's
/// ~rgb(30,30,33) backdrop and all fail WCAG AA for text below 18 pt. They are
/// lifted to white 60 % (≈6.8:1 composited), which is also roughly where the
/// native `secondaryLabelColor` sits in dark appearance. `design/README.md`
/// makes the native equivalent win over the HTML's literal alpha values, so
/// this is a correction rather than a deviation.
private enum HUDPalette {
    /// Secondary/hint text on the dark HUD — AA-compliant at 11–13 pt.
    static let mutedText = NSColor.white.withAlphaComponent(0.60)
    /// Primary body text (design 1b white 85 % — already ≈11:1).
    static let bodyText = NSColor.white.withAlphaComponent(0.85)
    /// Failure/Stop text on dark (design colour map `#ff6961`).
    static let failureText = NSColor(
        srgbRed: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1
    )
}

// MARK: - Panel subclass

/// Nonactivating borderless panel (SPEC §5: floats above other windows, never
/// ACTIVATES the app / never takes the meeting app's activation).
///
/// KEY vs ACTIVE (the distinction the whole panel rests on). `.nonactivatingPanel`
/// is documented as "the panel can receive keyboard input without activating
/// the owning app": the panel becomes the KEY window (keystrokes route to it)
/// while the meeting app stays the ACTIVE app (its menu bar, its window
/// chrome, its own focus ring all stay put). That is the Spotlight pattern and
/// it is what SPEC §5 / design 1b mean by "never steals key focus from the
/// meeting app" — the app is never activated and dismissal returns typing to
/// the meeting app with no click.
///
/// NOT YET DOGFOODED (2026-08-19): the machine's screen was locked for this
/// round, so the key transition could only be exercised in-process (the panel
/// takes key and puts first responder on the body; a click on a header button
/// is delivered while the panel is not key). Whether the previously frontmost
/// app keeps its activation through a REAL ⌥⌘N summon still needs one driven
/// check on an unlocked machine.
///
/// The controller therefore calls `makeKey()` + `makeFirstResponder(body)` on
/// summon (UX review findings 2/3). `becomesKeyOnlyIfNeeded` is OFF: it made
/// key status depend on clicking a view that "needs" it (the text body did,
/// the header buttons did not), which is precisely why keystrokes used to land
/// in the meeting app.
///
/// `performKeyEquivalent` below is the ONLY Esc path (it consumes the event
/// before the text view can hear it), and it fires exactly when the panel is
/// the key window — which, because a `.nonactivatingPanel` can be key while
/// another app is active, covers every case where the user is typing into the
/// scratchpad. There is deliberately no global Esc grab; see `dismiss()`.
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
        // UX review finding 11: `.none` stripped the ONLY focus indicator a
        // Full-Keyboard-Access user would get on these borderless buttons.
        // `drawFocusRingMask` below shapes the ring to the 6 pt corner radius.
        focusRingType = .exterior
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

    /// UX review finding 8. The panel deliberately never activates the app, so
    /// a click on Stop/Start arrives while Scribe is inactive — the "first
    /// mouse". `NSButton` refuses those by default, which silently ate the
    /// click (the second, "real" click worked only if the first had made the
    /// panel key — and `becomesKeyOnlyIfNeeded` meant it never did). Accepting
    /// first mouse is safe here: both buttons are explicit, labelled, non
    /// destructive header actions.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Ring follows the button's rounded rect (design 1b radius 6).
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
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
/// Internal (not `private`) so the TextKit stack this initializer builds can
/// be verified without a panel on screen — see `init()`.
final class BodyTextView: NSTextView {

    /// Fired for Enter (and its editor variants); the controller freezes the
    /// burst and clears the view.
    var onNewline: (() -> Void)?

    var placeholderText: String = "" {
        didSet {
            // The placeholder is hand-drawn (NSTextView has none), so it is
            // invisible to VoiceOver unless it is also published as the
            // accessibility placeholder (UX review finding 11).
            setAccessibilityPlaceholderValue(placeholderText)
            needsDisplay = true
        }
    }

    init() {
        // BUG FIX (found by the UI gallery, App/UIGallery.swift): the
        // designated initializer with a `nil` text container leaves the view
        // with NO text system at all — `textContainer`, `layoutManager` and
        // `textStorage` all stay nil, `string` assignments are silently
        // dropped, and nothing typed here could ever be displayed or reach
        // the composer (SPEC §4.3). Build the standard TextKit stack.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true // body wraps to the panel width
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BodyTextView is created in code")
    }

    /// A click into the body while Scribe is inactive must land the caret
    /// where the user clicked, not be swallowed as a window-raise (finding 8).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        // Inherit the typing attributes (13 pt, 1.55 line-height) so the
        // placeholder sits on the exact baseline the first typed line will,
        // recoloured to the AA-compliant muted grey, and wrapped to the
        // container (design 2a's white 32% fails contrast — see HUDPalette).
        var attributes = typingAttributes
        attributes[.foregroundColor] = HUDPalette.mutedText
        let origin = textContainerOrigin
        let width = textContainer?.containerSize.width ?? bounds.width
        (placeholderText as NSString).draw(
            in: NSRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: max(0, bounds.height - origin.y)
            ),
            withAttributes: attributes
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
        /// Design 1b (the primary artboard, and the only one whose body has
        /// content) is 312 pt; 2a/2e draw the same panel at 300. README's
        /// "~300–312 pt" makes either legal — 312 wins because the empty
        /// placeholder ("Jot a fragment — …") measures ~279 pt and needs the
        /// wider body to stay on one line as the artboards draw it.
        static let panelWidth: CGFloat = 312
        static let cornerRadius: CGFloat = 12
        /// Body min-height: 150 pt while recording (1b), 130 pt with no
        /// meeting (2a). Both are floors — 2e's 110 pt is satisfied by 150.
        static let bodyMinHeightRecording: CGFloat = 150
        static let bodyMinHeightIdle: CGFloat = 130
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

    /// Mirrors `MenuBarController.permissionGuardEnabled` (T8 start guard):
    /// when true, Start Meeting checks mic/screen TCC first and routes to the
    /// wizard instead of letting `start()` throw into a log. Defaults to the
    /// same expression ScribeApp uses for the menu path, so the guard is live
    /// even before the app wires anything (the stub capture engine needs no
    /// TCC, so the guard is off in that mode).
    var permissionGuardEnabled = !UserDefaults.standard.bool(
        forKey: SettingsKeys.debugUseStubCapture
    )

    /// Set by ScribeApp to open the setup wizard at the first missing
    /// permission — the SAME callback the menu path uses (UX review finding
    /// 7). When unset the panel still refuses to fail silently: it shows the
    /// missing permission inline in the body (see `startTapped`).
    var onPermissionsMissing: (() -> Void)?

    /// Inline, non-modal failure text shown in the body's no-meeting face
    /// (design 3b: "no modal states anywhere"). Cleared on the next successful
    /// start / state change.
    private var startFailureMessage: String?

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "scratchpad")
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
    private static let noMeetingHintText =
        "Fragments typed here are discarded unless a meeting is recording."
    private let noMeetingHint = NSTextField(labelWithString: noMeetingHintText)

    /// Body type ramp (13 pt / ~1.55 line-height) shared by the text view and
    /// the no-meeting/failure hint.
    private let bodyParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        return paragraph
    }()

    /// Body floor, retargeted per state (150 pt recording / 130 pt idle).
    private var bodyMinHeight: NSLayoutConstraint!

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
    private var isPreparing: Bool

    init(coordinator: SessionCoordinator, composer: FragmentComposer) {
        self.coordinator = coordinator
        self.composer = composer
        // Height is a placeholder: the real one comes from the content
        // (`sizePanelToFit`), which is what makes the body's 150/130 pt
        // min-heights the panel's actual height.
        let rect = NSRect(
            x: 0, y: 0,
            width: Metrics.panelWidth,
            height: Metrics.bodyMinHeightRecording
        )
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
            titleColor: HUDPalette.failureText,
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
        isPreparing = coordinator.displayState == .preparing

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
        container.layer?.masksToBounds = true // nothing renders outside the radius
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.maskImage = Self.roundedMaskImage(radius: Metrics.cornerRadius)
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
        noMeetingLabel.textColor = HUDPalette.mutedText // design 2a white 50% → AA (finding 12)

        // Greedy spacer between the status group and the hint/button group.
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        savedLabel.font = NSFont.systemFont(ofSize: 11)
        savedLabel.textColor = HUDPalette.mutedText // design 2e white 45% → AA (finding 12)
        savedLabel.alphaValue = 0
        // Faded out via alpha (isHidden would jitter the header layout), so it
        // must leave the accessibility tree explicitly — otherwise VoiceOver
        // reads a permanent, invisible "Saved" (finding 11).
        savedLabel.setAccessibilityElement(false)

        hotkeyHint.font = NSFont.systemFont(ofSize: 11)
        hotkeyHint.textColor = HUDPalette.mutedText // design 1b white 35% → AA (finding 12)

        configureHeaderAccessibility()

        headerStack.addView(dotView, in: .leading)
        headerStack.addView(elapsedLabel, in: .leading)
        headerStack.addView(noMeetingLabel, in: .leading)
        headerStack.addView(spacer, in: .leading)
        // Trailing gravity lays out left→right in insertion order, so the
        // tick sits IMMEDIATELY left of Stop (design 2e), after the hint.
        headerStack.addView(hotkeyHint, in: .trailing)
        headerStack.addView(savedLabel, in: .trailing)
        headerStack.addView(stopButton, in: .trailing)
        headerStack.addView(startButton, in: .trailing)
        container.addSubview(headerStack)

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hairline)

        // Body: 13 pt system font, ~1.55 CSS line-height (≈ 1.25 AppKit
        // multiple — CSS line-height 1.55 ÷ ~1.2 default leading), white 85%.
        let paragraph = bodyParagraph
        bodyTextView.isRichText = false
        bodyTextView.allowsUndo = true
        bodyTextView.drawsBackground = false
        bodyTextView.backgroundColor = .clear
        bodyTextView.textColor = HUDPalette.bodyText
        bodyTextView.font = NSFont.systemFont(ofSize: 13)
        bodyTextView.defaultParagraphStyle = paragraph
        bodyTextView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: HUDPalette.bodyText,
            .paragraphStyle: paragraph,
        ]
        bodyTextView.insertionPointColor = .controlAccentColor // design: accent caret
        // The ring is drawn by the enclosing scroll view (below) so it frames
        // the fixed body area instead of the text view's growing frame.
        bodyTextView.focusRingType = .none
        bodyTextView.setAccessibilityLabel("Scratchpad")
        bodyTextView.setAccessibilityHelp(
            "Type a fragment. Return saves it and starts a new one. Escape closes the panel."
        )
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
        // Focus indicator for the body (finding 11): NSScrollView draws the
        // ring around its own bounds while its document view is the key
        // window's first responder — a stable frame, unlike the text view's.
        scrollView.focusRingType = .exterior
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(scrollView)

        // Body hint (design 2a, same 13 pt/1.55 body type; white 32% lifted to
        // AA — see HUDPalette). The attributed value is assigned LAST so its
        // paragraph style survives the cell's wrapping setters.
        noMeetingHint.lineBreakMode = .byWordWrapping
        noMeetingHint.cell?.wraps = true
        applyBodyHint(noMeetingHint.stringValue, color: HUDPalette.mutedText)
        // BUG FIX: without a wrap width this label's intrinsic size is its
        // FULL single-line width (~400 pt) — a required constraint that
        // widened the whole panel to ~429 pt in EVERY state (hidden views
        // still layout). Wrap it to the body's content width instead.
        noMeetingHint.preferredMaxLayoutWidth = Metrics.panelWidth - 2 * 14
        noMeetingHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noMeetingHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        noMeetingHint.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(noMeetingHint)
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bodyView)

        // Layout. scrollView and noMeetingHint occupy the same frame — they
        // are the recording/idle faces of the body, never both visible.
        container.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView(frame: NSRect(
            x: 0, y: 0,
            width: Metrics.panelWidth,
            height: Metrics.bodyMinHeightRecording
        ))
        root.addSubview(container)
        panel.contentView = root
        bodyMinHeight = bodyView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Metrics.bodyMinHeightRecording
        )
        NSLayoutConstraint.activate([
            // The panel is exactly one design width; everything inside wraps
            // or compresses to it (never the other way round).
            container.widthAnchor.constraint(equalToConstant: Metrics.panelWidth),
            bodyMinHeight,
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
            // Body's 16 pt bottom padding also holds for a hint that wraps
            // past the min-height (the body grows, it never clips).
            noMeetingHint.bottomAnchor.constraint(
                lessThanOrEqualTo: bodyView.bottomAnchor, constant: -16
            ),
        ])
    }

    // MARK: - Accessibility (UX review finding 11)

    /// Static labels for the header group and its controls. Everything in the
    /// header was previously unlabeled: the state dot is a bare `NSView`, the
    /// hint reads as punctuation, and the elapsed time had no name.
    private func configureHeaderAccessibility() {
        headerStack.setAccessibilityElement(true)
        headerStack.setAccessibilityRole(.group)
        dotView.setAccessibilityElement(true)
        dotView.setAccessibilityRole(.image)
        elapsedLabel.setAccessibilityLabel("Elapsed time")
        hotkeyHint.setAccessibilityLabel("Option-Command-N closes the scratchpad")
        savedLabel.setAccessibilityLabel("Fragment saved")
        stopButton.setAccessibilityLabel("Stop meeting")
        stopButton.setAccessibilityHelp("Ends the recording and starts fusion. Command-Return.")
        startButton.setAccessibilityLabel("Start meeting")
        startButton.setAccessibilityHelp("Starts recording. Return.")
        panel.setAccessibilityLabel("Scribe Scratchpad")
        updateHeaderAccessibility()
    }

    /// State-dependent labels — VoiceOver announces the header group as
    /// "Recording, 24:16" / "No meeting" (the elapsed time is otherwise just a
    /// string with no context).
    private func updateHeaderAccessibility() {
        if isRecording {
            let elapsed = elapsedLabel.stringValue
            dotView.setAccessibilityLabel("Recording")
            headerStack.setAccessibilityLabel(
                elapsed.isEmpty ? "Recording" : "Recording, \(elapsed)"
            )
        } else {
            dotView.setAccessibilityLabel("Not recording")
            headerStack.setAccessibilityLabel(isPreparing ? "Preparing speech model" : "No meeting")
        }
    }

    /// Body-face text (no-meeting hint, or an inline start failure).
    private func applyBodyHint(_ text: String, color: NSColor) {
        noMeetingHint.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: color,
                .paragraphStyle: bodyParagraph,
            ]
        )
    }

    /// The panel is exactly as tall as its content: header (10/12/9) +
    /// hairline + body floor (150 pt recording / 130 pt idle — design
    /// 1b/2a). Called on every state change; the TOP edge stays put, since
    /// the panel is anchored near the top of the screen (design 2b).
    private func sizePanelToFit() {
        guard let root = panel.contentView else { return }
        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Metrics.panelWidth, height: ceil(root.fittingSize.height))
        guard abs(size.height - panel.frame.height) > 0.5
            || abs(size.width - panel.frame.width) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        root.layoutSubtreeIfNeeded()
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
        // OFF (UX review findings 2/3): with it on, the panel became key only
        // when a click landed on a view that "needs" key input, so after ⌥⌘N
        // every keystroke went to the meeting app — the core loop "hotkey,
        // then jot" required a mouse click first. The panel now takes KEY on
        // summon (`focusPanel()`); it still never ACTIVATES the app, which is
        // what SPEC §5 / design 1b actually guarantee (see `HUDPanel` docs).
        panel.becomesKeyOnlyIfNeeded = false
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
    /// to clip `NSVisualEffectView` — layer masking does not reach the
    /// window-server-side blur).
    ///
    /// It is a NINE-PART image: corner-sized bitmap + cap insets + `.stretch`,
    /// so AppKit rebuilds it for whatever size the effect view ends up. A
    /// mask baked at one fixed panel size is the bug this replaces — once the
    /// panel was any other width the image no longer covered the view and the
    /// HUD rendered as a square full-bleed slab with a rounded rectangle
    /// floating inside it.
    private static func roundedMaskImage(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1 // 1 pt of stretchable middle
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Visibility

    /// Hotkey path (⌥⌘N via `GlobalHotkey.onSummon`, wired by ScribeApp).
    func toggle() {
        isVisibleToUser ? dismiss() : show()
    }

    // MARK: - Gallery test seams (dev tooling — App/UIGallery.swift)

    /// The panel, for placement + `windowNumber` in the screenshot gallery.
    var galleryWindow: NSWindow { panel }

    /// Presents the panel in a FIXED visual state for a screenshot. The real
    /// faces come from the coordinator's event stream plus a 1 s elapsed
    /// timer, neither of which a capture harness can drive to a deterministic
    /// "24:16 while recording" — so this sets the two state inputs and calls
    /// the production `renderState()`. It deliberately bypasses `show()`:
    /// that would run the summon animation and, via `isVisibleToUser`, start
    /// the elapsed timer, which would immediately overwrite the fixed time
    /// with the (idle) coordinator's.
    func galleryPresent(recording: Bool, elapsed: TimeInterval, body: String) {
        isRecording = recording
        renderState()
        if recording {
            elapsedLabel.stringValue = Formatting.elapsedString(elapsed)
            bodyTextView.string = body
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
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
        focusPanel() // findings 2/3: keystrokes must land HERE, not in the meeting app
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

    /// Takes KEY (not activation) and puts the caret in the body — the fix for
    /// UX review findings 2/3 ("typing after ⌥⌘N goes to the meeting app").
    ///
    /// `.nonactivatingPanel` is documented to receive keyboard input without
    /// activating the owning app, so the meeting app remains the frontmost /
    /// active application: no menu-bar swap, no window-order change, and
    /// dismissing the panel hands typing straight back. In the no-meeting face
    /// the body is hidden, so the window itself holds first responder — Return
    /// (Start Meeting) and Esc still resolve as key equivalents.
    private func focusPanel() {
        panel.makeKey()
        if isRecording, !scrollView.isHidden {
            panel.makeFirstResponder(bodyTextView)
        } else {
            panel.makeFirstResponder(nil)
        }
    }

    /// Dismiss (140 ms; fade + slight scale; Reduce Motion → fade only).
    /// Recording continues (SPEC §5).
    ///
    /// ESC IS NOT GRABBED GLOBALLY. This used to be reachable from a bare-Esc
    /// `RegisterEventHotKey` registered for as long as the panel was on
    /// screen. That was tolerable while the panel was a briefly-summoned HUD,
    /// but the owner-approved auto-show (see `ScribeApp`'s `.recording`
    /// deviation) keeps it up for the WHOLE meeting — and `RegisterEventHotKey`
    /// consumes the key system-wide, so every other app lost Escape (no
    /// cancelling a dialog, no leaving full-screen video, no dismissing a
    /// menu) for the duration of the call. Esc now arrives only through
    /// `HUDPanel.performKeyEquivalent`, i.e. only while the panel is the KEY
    /// window — which `show()`/`focusPanel()` makes it on every summon, and
    /// which a `.nonactivatingPanel` keeps even though the meeting app stays
    /// the ACTIVE app. Once the user clicks back into the meeting app the
    /// panel resigns key and Esc belongs to that app again; ⌥⌘N (or Stop)
    /// still dismisses from there.
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
            // The completion is a non-isolated closure AppKit calls on the
            // main thread (same shape as the recording chip's fade).
            MainActor.assumeIsolated {
                // Re-validate: a ⌥⌘N (or the auto-show) inside the 140 ms
                // window has already re-summoned the panel, and ordering it
                // out here would leave it invisible while the controller
                // believes it is showing — the next hotkey press would then
                // be eaten by `dismiss()`'s guard. Same re-check as the
                // recording chip's fade completion.
                guard let self, !self.isVisibleToUser else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1 // reset for the next summon (fades 0→1)
            }
        })
    }

    /// Top-center of the screen the pointer is on (multi-monitor safe);
    /// near the menu bar, matching the design 2b mock.
    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size // content-sized (see sizePanelToFit)
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 20
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
        let preparing = state == .preparing
        guard recording != isRecording || preparing != isPreparing else { return }
        isRecording = recording
        isPreparing = preparing
        if recording {
            startFailureMessage = nil // a start succeeded — the notice is stale
        }
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
        noMeetingLabel.stringValue = isPreparing ? "Preparing speech model…" : "No meeting"
        stopButton.isHidden = !recording
        startButton.isHidden = recording
        startButton.title = isPreparing ? "Preparing…" : "Start Meeting"
        startButton.isEnabled = !isPreparing
        savedLabel.isHidden = !recording // nothing persists with no session
        scrollView.isHidden = !recording
        noMeetingHint.isHidden = recording

        // Keyboard stop/start (UX review finding 18 — there was NO keyboard
        // way to stop a recording). ⌘⏎ stops; plain ⏎ starts, which is free
        // only in the no-meeting face (while recording, ⏎ in the body is the
        // burst boundary). Assigned per state rather than relying on AppKit
        // skipping hidden buttons' key equivalents.
        stopButton.keyEquivalent = recording ? "\r" : ""
        stopButton.keyEquivalentModifierMask = recording ? .command : []
        startButton.keyEquivalent = recording ? "" : "\r"
        startButton.keyEquivalentModifierMask = []

        // Body face text: the no-meeting hint, or an inline start failure
        // (finding 7 — never log-only).
        if isPreparing {
            applyBodyHint("Preparing speech model… Recording will start when it’s ready.", color: HUDPalette.mutedText)
        } else if let startFailureMessage {
            applyBodyHint(startFailureMessage, color: HUDPalette.failureText)
        } else {
            applyBodyHint(Self.noMeetingHintText, color: HUDPalette.mutedText)
        }
        updateHeaderAccessibility()

        // Body floor: 150 pt recording (1b), 130 pt no-meeting (2a).
        bodyMinHeight.constant = recording
            ? Metrics.bodyMinHeightRecording
            : Metrics.bodyMinHeightIdle
        sizePanelToFit()

        if !recording {
            // No session: nothing pending can survive (coordinator.stop()
            // already flushed the composer). Discard the view's text.
            bodyTextView.string = ""
            cancelSavedTick()
            burstClearTimer?.invalidate()
            burstClearTimer = nil
        }
        // The face changed under an on-screen panel (e.g. Start/Stop pressed
        // while it is open): move the keyboard with it.
        if isVisibleToUser, panel.isKeyWindow {
            focusPanel()
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
        updateHeaderAccessibility() // "Recording, 24:16" (finding 11)
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
        savedLabel.setAccessibilityElement(true) // in the a11y tree only while visible
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
        savedLabel.setAccessibilityElement(false)
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
        savedLabel.setAccessibilityElement(false)
    }

    // MARK: - Header actions

    /// Stop finalizes pending segments → processing → fusion (SPEC §4.4).
    /// Header state flips via `.stateChanged` events.
    @objc private func stopTapped() {
        Task { await coordinator.stop() }
    }

    /// Start Meeting (UX review finding 7 — this was a silent dead button).
    ///
    /// It called `coordinator.start()` directly, bypassing the TCC guard the
    /// menu path has (`MenuBarController.toggleMeeting`), and swallowed the
    /// throw into a log: with mic or Screen Recording missing, the click did
    /// nothing at all and said nothing. Now it runs the same guard — routing
    /// to the wizard through `onPermissionsMissing` — and every failure shows
    /// in the panel.
    @objc private func startTapped() {
        if permissionGuardEnabled, let missing = SetupWizardPhase.firstMissingPermission {
            logger.info("Start blocked: \(String(describing: missing), privacy: .public) permission missing.")
            if let onPermissionsMissing {
                clearStartFailure()
                onPermissionsMissing() // wizard, at the first missing permission
            } else {
                // Not wired (or wired late) — still never silent.
                showStartFailure(Self.permissionMessage(for: missing))
            }
            return
        }
        clearStartFailure()
        Task { @MainActor in
            do {
                try await coordinator.start()
            } catch {
                logger.error("Meeting start failed from panel: \(String(describing: error), privacy: .public)")
                showStartFailure(error.localizedDescription)
            }
        }
    }

    private static func permissionMessage(for step: SetupWizardPhase) -> String {
        switch step {
        case .microphone:
            return "Microphone access is off. Open Scribe’s setup from the menu bar to grant it."
        case .screenRecording:
            return "Screen Recording access is off. Open Scribe’s setup from the menu bar to grant it."
        default:
            return "Scribe needs setup before a meeting can start — open it from the menu bar."
        }
    }

    /// Shows a failure inline in the body (design 3b: no modal states) and
    /// announces it, so VoiceOver users get the same feedback.
    private func showStartFailure(_ message: String) {
        startFailureMessage = message
        renderState()
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func clearStartFailure() {
        guard startFailureMessage != nil else { return }
        startFailureMessage = nil
        renderState()
    }
}

// MARK: - NSTextViewDelegate

extension ScratchpadPanelController: NSTextViewDelegate {}
