import AppKit
import CaptureKit
import FusionKit
import TranscribeKit
import os

// MARK: - Persisted phase (SPEC §4.1 first-run flow)

/// Setup-wizard progress persisted in UserDefaults under `setupPhase`
/// (SPEC §4.1: "on relaunch, a persisted `setupPhase` flag resumes the
/// wizard where it left off" — the Screen Recording TCC grant forces that
/// relaunch, so the phase is written on EVERY step transition).
///
/// Phase names:
/// - `welcome` (0): what Scribe does; BOTH permissions explained before any
///   prompt is triggered (SPEC §4.1: explain both prompts, then trigger).
/// - `microphone` (1): mic TCC request → status.
/// - `screenRecording` (2): Screen Recording request → "requires quit &
///   reopen" instruction (a grant only takes effect after relaunch).
/// - `modelDownload` (3): WhisperKit model fetch with progress UI.
/// - `apiKey` (4): optional Anthropic key into the Keychain.
/// - `completed` (5): done — never shown on launch again.
enum SetupWizardPhase: Int {
    case welcome = 0
    case microphone = 1
    case screenRecording = 2
    case modelDownload = 3
    case apiKey = 4
    case completed = 5

    /// UserDefaults key holding the raw phase int.
    static let storageKey = "setupPhase"

    /// Persisted phase; `welcome` when nothing is stored (never run).
    static var persisted: SetupWizardPhase {
        SetupWizardPhase(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .welcome
    }

    static func store(_ phase: SetupWizardPhase) {
        UserDefaults.standard.set(phase.rawValue, forKey: storageKey)
    }

    /// The wizard step addressing the first missing capture permission —
    /// the start-flow guard (T8) opens the wizard here instead of letting a
    /// meeting start fail silently. `nil` when both are granted. Note the
    /// screen enum conflates "never asked" with "denied" (CGPreflight is
    /// boolean) — either way the screen step is the right destination.
    static var firstMissingPermission: SetupWizardPhase? {
        if CapturePermissions.microphone != .granted { return .microphone }
        if CapturePermissions.screenRecording == .denied { return .screenRecording }
        return nil
    }
}

// MARK: - Controller

/// Five-step setup wizard (SPEC §4.1 permissions & first-run flow, §5
/// "Setup wizard", T8): welcome (both permissions explained BEFORE any
/// prompt) → mic prompt → Screen Recording prompt + quit-and-reopen
/// instruction → model download with progress → optional API key → done.
///
/// Survives the Screen Recording TCC relaunch via the persisted
/// `SetupWizardPhase` (resumes where the user left off). Plain AppKit,
/// ~440 pt, grouped-card style matching SettingsWindowController. Cancel
/// just closes the window — the phase persists, so the wizard reappears on
/// the next launch until it completes.
///
/// Keyboard & accessibility (this is the first surface a new user meets, so
/// it has to answer the keyboard):
/// - Esc = Cancel on every step (`makeFooter`), matching Settings' key-edit
///   row. Return = the primary button, but the field editor is committed
///   first (`primaryAction`) so Return can never advance a step with a stale
///   value. ⌘W comes from the app's main menu, not from here.
/// - VoiceOver: status lines, the progress row and the API-key field are named
///   for what they report, not just their contents; the SF Symbols already
///   carry `accessibilityDescription`.
/// - Reduce Motion: the per-step window resize is not animated when the
///   setting is on. Increase Contrast: card hairlines double in width
///   (`ContrastMetrics`), re-read live via
///   `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
/// - Text size: fixed point sizes, accepted as a v0 limitation (AppKit has no
///   Dynamic Type); every label wraps and the window height is solved from the
///   content, so a longer string grows the step instead of clipping.
@MainActor
final class SetupWizardController: NSObject {

    private static let windowWidth: CGFloat = 440
    private static let contentWidth: CGFloat = 400 // 440 − 2×20 outer margins
    private static let cardBodyWidth: CGFloat = 372 // 400 − 2×14 card insets
    private static let minHeight: CGFloat = 340

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "setup")
    private let keychain = KeychainStore()
    private let downloads = ModelDownloadManager()

    private let window: NSWindow
    private var phase: SetupWizardPhase = .welcome

    // Step refs — rebuilt on every render; only the CURRENT step's are live.
    private var micStatusLabel: NSTextField?
    private var micHelpButton: NSButton?
    /// Rows wrapping the optional buttons — hidden WITH their button so the
    /// card stack collapses the row's spacing too (hiding only the button
    /// leaves an 8 pt gap behind).
    private var micHelpRow: NSStackView?
    private var screenStatusLabel: NSTextField?
    private var screenGrantButton: NSButton?
    private var screenHelpButton: NSButton?
    /// The row wrapping `screenGrantButton` — hidden with it (see
    /// `modelActionRow`).
    private var screenGrantRow: NSStackView?
    private var screenHelpRow: NSStackView?
    private var modelProgress: NSProgressIndicator?
    private var modelPercentLabel: NSTextField?
    private var modelStatusLabel: NSTextField?
    private var modelActionButton: NSButton?
    /// The row wrapping `modelActionButton` — hidden with it so the stack
    /// collapses the row's spacing too (hiding only the button left a gap).
    private var modelActionRow: NSStackView?
    private var apiKeyField: NSSecureTextField?
    private var footerPrimaryButton: NSButton?

    /// Step 2 bookkeeping: `true` when THIS wizard run triggered the Screen
    /// Recording prompt and it was granted — the "quit and reopen"
    /// instruction only applies then (SPEC §4.1). On a resumed run the
    /// pre-existing grant needs no relaunch.
    private var screenNewlyGranted = false
    /// Step 2: the TCC prompt was already surfaced this run; further calls
    /// to CGRequestScreenCaptureAccess would no-op, so point at System
    /// Settings instead.
    private var screenPromptShown = false

    /// Step 3 state — survives step navigation so the download continues in
    /// the background while the user pages around.
    private enum ModelState: Equatable {
        case idle
        case downloading(Double)
        case completed
        case failed(String)
    }
    private var modelState: ModelState = .idle
    private var downloadTask: Task<Void, Never>?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Scribe Setup"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
    }

    /// Shows the wizard. `step` forces a phase without persisting it (the
    /// start-flow guard jumps straight to the missing permission); `nil`
    /// renders the persisted phase (first-run launch, re-open).
    func show(at step: SetupWizardPhase? = nil) {
        if let step {
            phase = step
        } else {
            phase = SetupWizardPhase.persisted
        }
        render()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true) // LSUIElement accessory app
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Step machine

    /// Advances and persists (SPEC §4.1: the phase flag is what resumes the
    /// wizard across the TCC relaunch).
    private func goTo(_ next: SetupWizardPhase) {
        phase = next
        SetupWizardPhase.store(next)
        if next == .completed {
            window.orderOut(nil) // never shown on launch again
        } else {
            render()
        }
    }

    private func render() {
        guard phase != .completed else {
            window.orderOut(nil)
            return
        }
        // Drop stale refs from the previous step before rebuilding.
        micStatusLabel = nil
        micHelpButton = nil
        micHelpRow = nil
        screenStatusLabel = nil
        screenGrantButton = nil
        screenHelpButton = nil
        screenGrantRow = nil
        screenHelpRow = nil
        modelProgress = nil
        modelPercentLabel = nil
        modelStatusLabel = nil
        modelActionButton = nil
        modelActionRow = nil
        apiKeyField = nil
        footerPrimaryButton = nil

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.minHeight))
        let stack = NSStackView()
        stack.orientation = .vertical
        // `.leading`, NOT `.width`: for a vertical stack `.width` is not a
        // positioning alignment at all — NSStackView emits no equal-width
        // constraint for it and falls back to its `Edge.Min.Leading` (@250)
        // and `Edge.Min.Trailing` (@260) pair. Trailing outranks leading, so
        // every short label (the step caption, the title) was parked flush
        // RIGHT. `.leading` emits a real `NSStackView.Align` leading
        // constraint; `addRow` supplies the full-column width where a row
        // needs it.
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // The column width is pinned, and STAYS pinned: `fittingSize` is a
        // MINIMUM-size solve, so without it the wrapping labels are measured
        // at their compressed width — both when the height is computed below
        // and later, when AppKit re-sizes this fixed-size window to its
        // content's fitting size (dropping the pin collapsed the window to
        // ~40 pt wide).
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.windowWidth),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        let caption = makeStepCaption()
        addRow(caption, to: stack)
        stack.setCustomSpacing(3, after: caption)
        let title = makeTitleLabel(header.title)
        addRow(title, to: stack)
        if let subtitle = header.subtitle {
            stack.setCustomSpacing(5, after: title)
            addRow(makeBodyLabel(subtitle, width: Self.contentWidth), to: stack)
        }

        switch phase {
        case .welcome:
            buildWelcome(into: stack)
        case .microphone:
            buildMic(into: stack)
        case .screenRecording:
            buildScreen(into: stack)
        case .modelDownload:
            buildModel(into: stack)
        case .apiKey:
            buildAPIKey(into: stack)
        case .completed:
            break // unreachable; guarded above
        }

        // The footer is pinned to the BOTTOM of the content view rather than
        // appended to the stack: the steps differ a lot in height, and the
        // `minHeight` floor would otherwise leave a stretch of dead space
        // BELOW the buttons on the short ones. The `>=` chain (stack → 18 pt →
        // footer → 20 pt → bottom) is still what the minimum-size solve reads,
        // so every step's window is tall enough for its footer.
        let footer = makeFooter()
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            footer.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 18),
        ])

        // Measure BEFORE the view becomes the window's contentView: detached,
        // `content` owns every constraint that decides its size, so the solve
        // is the honest one.
        let height = max(Self.minHeight, ceil(content.fittingSize.height))
        content.setFrameSize(NSSize(width: Self.windowWidth, height: height))
        window.contentView = content
        // `setFrame` takes a FRAME rect, so the computed CONTENT height has to
        // go through `frameRect(forContentRect:)` — passing it straight through
        // (as this did) swallowed the ~28 pt title bar and cut the footer off
        // the bottom of every step. Keep the title bar anchored while the
        // height changes per step.
        var frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: height)
        )
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        // Reduce Motion (finding 23): the step-to-step height change is the
        // wizard's only animation. Read at the moment of the animation, so a
        // mid-session toggle applies to the very next step.
        window.setFrame(
            frame,
            display: true,
            animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )

        // A keyboard user must land somewhere useful (finding 13): the API-key
        // step focuses its field so the key can be typed (or pasted, via the
        // app's Edit menu) without touching the mouse; every other step points
        // at the primary button for Full Keyboard Access users.
        if let field = apiKeyField {
            window.initialFirstResponder = field
            window.makeFirstResponder(field)
        } else {
            window.initialFirstResponder = footerPrimaryButton
        }
    }

    /// Adds a full-column row. `stack.alignment` only positions rows; rows
    /// that must fill the column (cards, footers, wrapping labels) need the
    /// width match, otherwise they collapse to their intrinsic size and the
    /// wrapping labels re-wrap at the wrong width.
    private func addRow(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private var header: (title: String, subtitle: String?) {
        switch phase {
        case .welcome:
            return ("Welcome to Scribe", nil)
        case .microphone:
            return ("Microphone", "Scribe needs the microphone to transcribe what you say.")
        case .screenRecording:
            return ("Screen Recording", "macOS delivers meeting audio through this permission.")
        case .modelDownload:
            return ("Speech Model", "One-time download for on-device transcription.")
        case .apiKey, .completed:
            return ("AI Notes — Optional", nil)
        }
    }

    // MARK: Step 0 — welcome (SPEC §4.1: both permissions explained BEFORE
    // any prompt is triggered)

    private func buildWelcome(into stack: NSStackView) {
        addRow(makeBodyLabel(
            "Scribe sits in your menu bar, records the meetings you start, and turns "
                + "them into structured notes. Everything runs on your Mac: audio is "
                + "transcribed on-device, never saved, and never leaves this machine.",
            width: Self.contentWidth
        ), to: stack)
        addRow(makeCard([
            makePermissionRow(
                symbol: "mic.fill",
                title: "Microphone",
                caption: "Transcribes what you say. macOS will ask for permission on the next step."
            ),
            makePermissionRow(
                symbol: "display",
                title: "Screen Recording",
                caption: "macOS routes meeting audio — the other participants — through this "
                    + "permission. Scribe captures audio only: screen frames are 2×2 px and "
                    + "discarded instantly. Granting it requires quitting and reopening Scribe once."
            ),
        ]), to: stack)
    }

    /// Icon column width in a permission row — fixed so the caption's wrap
    /// width is a constant rather than whatever the SF Symbol happens to be.
    private static let permissionIconWidth: CGFloat = 22

    private func makePermissionRow(symbol: String, title: String, caption: String) -> NSView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageAlignment = .alignTop
        icon.widthAnchor.constraint(equalToConstant: Self.permissionIconWidth).isActive = true
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            icon.image = image
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
        }
        let textWidth = Self.cardBodyWidth - Self.permissionIconWidth - 10
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSStackView(views: [titleLabel, makeBodyLabel(caption, width: textWidth)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        return row
    }

    // MARK: Step 1 — microphone (request → status)

    private func buildMic(into stack: NSStackView) {
        let status = makeStatusLabel()
        // VoiceOver: the status line's text changes ("granted ✓" / "is off"),
        // so it needs a stable name for what it reports (finding 15's pattern
        // applied here).
        status.setAccessibilityLabel("Microphone permission status")
        micStatusLabel = status

        let help = makeSecondaryButton(
            "Open System Settings…", action: #selector(openMicSettings)
        )
        // Two steps carry an identically-titled button; name each for its pane.
        help.setAccessibilityLabel("Open System Settings — Microphone privacy")
        micHelpButton = help
        let helpRow = makeLeadingRow(help)
        micHelpRow = helpRow

        addRow(makeCard([
            status,
            helpRow,
            makeBodyLabel(
                "A grant is effective immediately — no relaunch needed for the microphone.",
                width: Self.cardBodyWidth
            ),
        ]), to: stack)
        refreshMicStatus()

        // SPEC §4.1 order: the mic prompt fires only after step 0 explained
        // both permissions. When already determined this resolves instantly.
        if CapturePermissions.microphone == .undetermined {
            micStatusLabel?.stringValue = "Waiting for the macOS prompt…"
            Task {
                _ = await CapturePermissions.requestMicrophone()
                refreshMicStatus()
            }
        }
    }

    private func refreshMicStatus() {
        guard phase == .microphone else { return }
        switch CapturePermissions.microphone {
        case .granted:
            micStatusLabel?.stringValue = "Microphone access granted ✓"
            micStatusLabel?.textColor = .systemGreen
            micHelpRow?.isHidden = true
            micHelpButton?.isHidden = true
        case .denied:
            micStatusLabel?.stringValue = "Microphone access is off"
            micStatusLabel?.textColor = .systemRed
            micHelpRow?.isHidden = false
            micHelpButton?.isHidden = false
        case .undetermined:
            micStatusLabel?.stringValue = "Waiting for the macOS prompt…"
            micStatusLabel?.textColor = .secondaryLabelColor
            micHelpRow?.isHidden = true
            micHelpButton?.isHidden = true
        }
    }

    // MARK: Step 2 — screen recording (TCC relaunch, SPEC §4.1)

    private func buildScreen(into stack: NSStackView) {
        let status = makeStatusLabel()
        status.setAccessibilityLabel("Screen Recording permission status")
        screenStatusLabel = status

        let grant = NSButton(
            title: "Grant Screen Recording Access…",
            target: self,
            action: #selector(requestScreenPermission)
        )
        grant.setContentHuggingPriority(.required, for: .horizontal)
        grant.setAccessibilityLabel("Grant Screen Recording access")
        screenGrantButton = grant
        let grantRow = makeLeadingRow(grant)
        screenGrantRow = grantRow

        let help = makeSecondaryButton(
            "Open System Settings…", action: #selector(openScreenSettings)
        )
        help.setAccessibilityLabel("Open System Settings — Screen Recording privacy")
        screenHelpButton = help
        let helpRow = makeLeadingRow(help)
        screenHelpRow = helpRow

        addRow(makeCard([
            status,
            grantRow,
            helpRow,
            makeBodyLabel(
                "Scribe captures the meeting’s audio, not your screen: video frames are "
                    + "2×2 pixels at 1 fps and are discarded the moment they arrive.",
                width: Self.cardBodyWidth
            ),
        ]), to: stack)

        // The quit-and-reopen instruction appears only after a FRESH grant
        // this run — a pre-existing (or already-relaunched) grant captures
        // fine (re-checked on every appear, SPEC §4.1).
        if screenNewlyGranted {
            addRow(makeCard([
                makeBodyLabel(
                    "Granted — now quit and reopen Scribe. macOS only applies Screen "
                        + "Recording grants after the app relaunches. Choose Quit "
                        + "(⌘Q) from the menu bar, then start Scribe again — setup resumes "
                        + "right here.",
                    width: Self.cardBodyWidth
                ),
            ]), to: stack)
        }
        refreshScreenStatus()
    }

    private func refreshScreenStatus() {
        guard phase == .screenRecording else { return }
        if CapturePermissions.screenRecording == .granted {
            screenStatusLabel?.stringValue = "Screen Recording access granted ✓"
            screenStatusLabel?.textColor = .systemGreen
            screenGrantRow?.isHidden = true
            screenGrantButton?.isHidden = true
            screenHelpRow?.isHidden = true
            screenHelpButton?.isHidden = true
        } else if screenPromptShown {
            screenStatusLabel?.stringValue = "Not granted — enable Scribe in System Settings, then quit & reopen"
            screenStatusLabel?.textColor = .systemRed
            screenGrantRow?.isHidden = true
            screenGrantButton?.isHidden = true
            screenHelpRow?.isHidden = false
            screenHelpButton?.isHidden = false
        } else {
            screenStatusLabel?.stringValue = "Screen Recording access not granted"
            screenStatusLabel?.textColor = .secondaryLabelColor
            screenGrantRow?.isHidden = false
            screenGrantButton?.isHidden = false
            screenHelpRow?.isHidden = true
            screenHelpButton?.isHidden = true
        }
    }

    @objc private func requestScreenPermission() {
        screenPromptShown = true
        screenGrantButton?.isEnabled = false
        screenStatusLabel?.stringValue = "Waiting for the macOS prompt…"
        screenStatusLabel?.textColor = .secondaryLabelColor
        // CGRequestScreenCaptureAccess is synchronous (it returns only after
        // the system dialog is answered) — run it off the main thread, then
        // re-render with the outcome.
        let prompt = Task.detached(priority: .userInitiated) {
            CapturePermissions.requestScreenRecording()
        }
        Task {
            screenNewlyGranted = await prompt.value
            screenGrantButton?.isEnabled = true
            render() // relaunch-instruction card appears on a fresh grant
        }
    }

    // MARK: Step 3 — model download (SPEC §4.2 first-launch fetch)

    private func buildModel(into stack: NSStackView) {
        let variant = SettingsKeys.whisperModelName
        addRow(makeBodyLabel(
            "Meetings are transcribed on your Mac with WhisperKit. The speech model "
                + "(“\(variant)”, \(Self.sizeHint(variant))) downloads once and is used "
                + "for every meeting.",
            width: Self.contentWidth
        ), to: stack)

        modelProgress = NSProgressIndicator()
        modelProgress?.isIndeterminate = false
        modelProgress?.minValue = 0
        modelProgress?.maxValue = 1
        modelProgress?.controlSize = .small
        // The progress row is three anonymous pieces to VoiceOver — a bar, a
        // number and a line of text. Name each for what it reports.
        modelProgress?.setAccessibilityLabel("Speech model download progress")

        modelPercentLabel = NSTextField(labelWithString: "")
        modelPercentLabel?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        modelPercentLabel?.textColor = .secondaryLabelColor
        modelPercentLabel?.setAccessibilityLabel("Download progress")

        modelStatusLabel = NSTextField(labelWithString: "")
        modelStatusLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        modelStatusLabel?.setAccessibilityLabel("Speech model download status")

        modelActionButton = NSButton(
            title: "Download", target: self, action: #selector(downloadOrRetry)
        )
        modelActionButton?.setContentHuggingPriority(.required, for: .horizontal)
        modelActionButton?.setAccessibilityLabel("Download the speech model")

        // The bar takes the row's slack (low hugging) and the percentage sits
        // in a fixed, tabular-figure column on the right, so the bar doesn't
        // jitter as the number grows from "0 %" to "100 %".
        modelProgress?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        modelPercentLabel?.alignment = .right
        modelPercentLabel?.setContentHuggingPriority(.required, for: .horizontal)
        modelPercentLabel?.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let progressRow = NSStackView(views: [modelProgress!, modelPercentLabel!])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.distribution = .fill
        progressRow.spacing = 8

        let statusRow = makeLeadingRow(modelStatusLabel!)
        let actionRow = makeLeadingRow(modelActionButton!)
        modelActionRow = actionRow

        addRow(makeCard([
            progressRow,
            statusRow,
            actionRow,
            makeBodyLabel(
                "Until the model finishes, meetings record but are not transcribed. "
                    + "Retry any time — the download resumes instead of restarting.",
                width: Self.cardBodyWidth
            ),
        ]), to: stack)

        // Skip if already downloaded (task: "skip if isDownloaded");
        // otherwise auto-start the fetch (SPEC §4.2 progress UI on first
        // launch). A download begun on an earlier visit keeps running.
        if modelState == .idle {
            if downloads.isDownloaded(variant) {
                modelState = .completed
                updateModelStepUI()
            } else {
                startModelDownload()
            }
        } else {
            updateModelStepUI()
        }
    }

    private func startModelDownload() {
        let variant = SettingsKeys.whisperModelName
        modelState = .downloading(0)
        updateModelStepUI()
        let downloads = self.downloads
        downloadTask = Task {
            for await event in downloads.download(variant) {
                handle(event)
            }
        }
    }

    /// MainActor (Task created in a @MainActor context) — safe to touch UI.
    private func handle(_ event: ModelDownloadEvent) {
        switch event {
        case .progress(let fraction):
            modelState = .downloading(fraction)
        case .completed:
            modelState = .completed
        case .failed(let message):
            modelState = .failed(message)
        }
        updateModelStepUI()
    }

    /// In-place refresh (progress events arrive at high frequency — no full
    /// re-render per tick).
    private func updateModelStepUI() {
        guard phase == .modelDownload else { return }
        switch modelState {
        case .idle:
            modelProgress?.doubleValue = 0
            modelPercentLabel?.stringValue = ""
            modelStatusLabel?.stringValue = "Not started"
            modelStatusLabel?.textColor = .secondaryLabelColor
            modelActionRow?.isHidden = false
            modelActionButton?.isHidden = false
            modelActionButton?.title = "Download"
            modelActionButton?.setAccessibilityLabel("Download the speech model")
            footerPrimaryButton?.isEnabled = false
        case .downloading(let fraction):
            modelProgress?.doubleValue = fraction
            modelPercentLabel?.stringValue = "\(Int((fraction * 100).rounded())) %"
            modelStatusLabel?.stringValue = "Downloading \(SettingsKeys.whisperModelName)…"
            modelStatusLabel?.textColor = .secondaryLabelColor
            modelActionRow?.isHidden = true
            modelActionButton?.isHidden = true
            footerPrimaryButton?.isEnabled = false
        case .completed:
            modelProgress?.doubleValue = 1
            modelPercentLabel?.stringValue = "100 %"
            modelStatusLabel?.stringValue = "Downloaded — ready ✓"
            modelStatusLabel?.textColor = .systemGreen
            modelActionRow?.isHidden = true
            modelActionButton?.isHidden = true
            footerPrimaryButton?.isEnabled = true
        case .failed(let message):
            modelProgress?.doubleValue = 0
            modelPercentLabel?.stringValue = ""
            modelStatusLabel?.stringValue = "Download failed — \(message)"
            modelStatusLabel?.textColor = .systemRed
            modelActionRow?.isHidden = false
            modelActionButton?.isHidden = false
            modelActionButton?.title = "Retry"
            modelActionButton?.setAccessibilityLabel("Retry the speech model download")
            // Continue stays available (with the honest caption above) so a
            // flaky network can't trap the user inside the wizard.
            footerPrimaryButton?.isEnabled = true
        }
    }

    @objc private func downloadOrRetry() {
        startModelDownload()
    }

    private static func sizeHint(_ variant: String) -> String {
        switch variant {
        case "tiny.en": return "~75 MB"
        case "base.en": return "~150 MB"
        case "small.en": return "~500 MB"
        default: return "large, over 1 GB"
        }
    }

    // MARK: Step 4 — API key (optional; Keychain, SPEC §4.5/§5)

    private func buildAPIKey(into stack: NSStackView) {
        addRow(makeBodyLabel(
            "Meeting notes are written by Claude through the Anthropic API. Your key is "
                + "stored in the macOS Keychain and used only for fusion requests.",
            width: Self.contentWidth
        ), to: stack)

        let hasKey = ((try? keychain.loadAPIKey()) ?? nil) != nil

        let field = NSSecureTextField()
        field.placeholderString = "sk-ant-…"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Anthropic API Key")
        field.setAccessibilityHelp(
            "Optional. Stored in the macOS Keychain; you can add it later in Settings."
        )
        apiKeyField = field

        addRow(makeCard([
            field,
            makeBodyLabel(
                hasKey
                    ? "A key is already saved — entering a new one replaces it."
                    : "Skipping is fine: add it later in Settings. Until then, finishing a "
                        + "meeting reports a clear fusion error you can retry once a key "
                        + "is saved.",
                width: Self.cardBodyWidth
            ),
        ]), to: stack)
    }

    @objc private func saveAndFinish() {
        let trimmed = apiKeyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.saveAPIKey(trimmed)
            goTo(.completed)
        } catch {
            presentError("Couldn't save the API key", error)
        }
    }

    @objc private func skipAPIKey() {
        goTo(.completed) // fusion retries later with a clear error (T8 brief)
    }

    // MARK: - Footer

    /// Back/Cancel on the left, the primary (plus Skip on the key step) on
    /// the right.
    ///
    /// A single gravity stack, deliberately: the previous hand-rolled
    /// container held `left`/`right` with plain `addSubview`, and
    /// `NSStackView()` (unlike `NSStackView(views:)`) leaves
    /// `translatesAutoresizingMaskIntoConstraints` ON — so the never-laid-out
    /// right-hand stack contributed required `width == 0` / `height == 0`
    /// autoresizing constraints. The engine broke the real ones, the footer
    /// collapsed to 0 × 0 at the trailing edge, and its buttons drew outside
    /// it (a blue sliver in the window corner) while the step measured 0 pt
    /// of footer height. `addView(_:in:)` clears the flag for us.
    private func makeFooter() -> NSView {
        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        back.isEnabled = phase.rawValue > SetupWizardPhase.welcome.rawValue
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelWizard))
        // Finding 13: without this the wizard had NO keyboard exit at all —
        // no Esc here, and ⌘W needs a main menu that the app only grew later.
        // Same treatment Settings' key-edit row already had. A key equivalent
        // is dispatched before the field editor sees the keystroke, so Esc
        // gets out even while the API-key field has focus.
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel setup")

        let primary = NSButton(
            title: phase == .apiKey ? "Save & Finish" : "Continue",
            target: self,
            action: #selector(primaryAction)
        )
        primary.keyEquivalent = "\r" // system accent fill (design-spec 1e primary)
        footerPrimaryButton = primary
        back.setAccessibilityLabel("Back to the previous step")

        let footer = NSStackView()
        // `NSStackView()` — unlike `NSStackView(views:)` — leaves this ON, and
        // the footer is `addSubview`d rather than added to a stack, so nothing
        // else would clear it. See the note above.
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.setHuggingPriority(.defaultLow, for: .horizontal) // spread to the column
        // NSButton hugs at 250, so in a full-width row the buttons themselves
        // absorbed the slack and stretched. Let them keep their intrinsic
        // width and put the slack between the two gravity areas instead.
        for button in [back, cancel, primary] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        footer.addView(back, in: .leading)
        footer.addView(cancel, in: .leading)

        if phase == .apiKey {
            let skip = NSButton(title: "Skip for Now", target: self, action: #selector(skipAPIKey))
            skip.setContentHuggingPriority(.required, for: .horizontal)
            footer.addView(skip, in: .trailing)
            primary.isEnabled = false // enabled once the field has content
        } else if phase == .modelDownload {
            switch modelState {
            case .completed, .failed: primary.isEnabled = true
            default: primary.isEnabled = false
            }
        } else {
            primary.isEnabled = true
        }
        footer.addView(primary, in: .trailing)
        return footer
    }

    @objc private func goBack() {
        guard phase.rawValue > SetupWizardPhase.welcome.rawValue,
              let previous = SetupWizardPhase(rawValue: phase.rawValue - 1) else { return }
        goTo(previous)
    }

    @objc private func primaryAction() {
        // Return is the primary button's key equivalent, and AppKit dispatches
        // key equivalents BEFORE the field editor sees the keystroke — so on
        // the API-key step, Return would have run "Save & Finish" against the
        // cell's last committed value instead of what was just typed
        // (finding 13). Ending editing pushes the field editor's text into the
        // cell first; when the field is empty the primary is disabled, so
        // Return simply does nothing and cannot blow through the step.
        window.endEditing(for: nil)
        switch phase {
        case .welcome: goTo(.microphone)
        case .microphone: goTo(.screenRecording)
        case .screenRecording: goTo(.modelDownload)
        case .modelDownload: goTo(.apiKey)
        case .apiKey: saveAndFinish()
        case .completed: break
        }
    }

    /// Cancel just closes (T8 brief): the phase persists and the wizard
    /// resumes on the next launch (SPEC §4.1).
    @objc private func cancelWizard() {
        window.orderOut(nil)
    }

    // MARK: - System Settings helpers

    @objc private func openMicSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shared builders (Settings-style grouped cards)

    private func makeStepCaption() -> NSTextField {
        let caption = NSTextField(labelWithString: "STEP \(phase.rawValue + 1) OF 5")
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .left
        // Spoken as a sentence rather than shouted initialisms.
        caption.setAccessibilityLabel("Step \(phase.rawValue + 1) of 5")
        return caption
    }

    private func makeTitleLabel(_ text: String) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.textColor = .labelColor
        title.alignment = .left
        // Wrapping rather than truncating (finding 24): the design's titles fit
        // the 400 pt column, a longer localization must not lose its tail.
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 0
        title.cell?.usesSingleLineMode = false
        (title.cell as? NSTextFieldCell)?.wraps = true
        title.preferredMaxLayoutWidth = Self.contentWidth
        return title
    }

    private func makeBodyLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// One control flush to the leading edge of its card row (the trailing
    /// slack is empty). A gravity stack rather than a bare view so the
    /// control keeps its intrinsic size instead of stretching.
    private func makeLeadingRow(_ view: NSView) -> NSStackView {
        let row = NSStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY // `.leading` is not a valid HORIZONTAL alignment
        row.spacing = 8
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        row.addView(view, in: .leading)
        return row
    }

    /// A permission/progress status line. WRAPPING, not a single-line label:
    /// the longest string ("Not granted — enable Scribe in System Settings,
    /// then quit & reopen") does not fit the 372 pt card column on one line
    /// and was being truncated.
    private func makeStatusLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .left
        label.preferredMaxLayoutWidth = Self.cardBodyWidth
        return label
    }

    /// A small, intrinsically-sized secondary button (starts hidden — every
    /// caller shows it only in the state that needs it).
    private func makeSecondaryButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.isHidden = true
        return button
    }

    /// Grouped card matching SettingsWindowController's style: native
    /// `controlBackgroundColor`, radius 9, hairline border.
    private func makeCard(_ rows: [NSView]) -> NSView {
        let card = CardView()

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading // see `addRow` — `.width` does not align
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])
        for row in rows {
            inner.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return card
    }

    private func presentError(_ message: String, _ error: Error) {
        logger.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Card chrome

/// The grouped-card background used by every wizard step (design-spec 1e:
/// 9 pt radius, 0.5 pt hairline border).
///
/// A layer-backed view rather than a drawn one, but the colours are resolved
/// in `updateLayer()` under `effectiveAppearance`: a `CGColor` baked once at
/// build time is a fixed RGBA that does NOT follow a light/dark switch, so
/// the previous `layer?.backgroundColor = …cgColor` in the builder left the
/// card painted for whichever appearance happened to be active when the step
/// was rendered.
private final class CardView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        // NSNotificationCenter holds observers as zeroing weak references
        // (10.11+), so no explicit removal is needed in `deinit`.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = ContrastMetrics.hairlineWidth
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = ContrastMetrics.hairlineColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // re-resolve the dynamic colours above
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        needsDisplay = true // Increase Contrast applies without a relaunch
    }
}

/// Increase Contrast (finding 23) — the same values Settings uses. Read at
/// DRAW time and never cached, so the notification above is all it takes for a
/// mid-session toggle to land. This is the pattern for the other surfaces:
/// hairlines that vanish at 0.5 pt double in width and darken.
private enum ContrastMetrics {
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var hairlineWidth: CGFloat { increaseContrast ? 1 : 0.5 }

    static var hairlineColor: NSColor { increaseContrast ? .tertiaryLabelColor : .separatorColor }
}

// MARK: - NSTextFieldDelegate (API key field)

extension SetupWizardController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard phase == .apiKey, let field = apiKeyField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        footerPrimaryButton?.isEnabled = !trimmed.isEmpty
    }
}
