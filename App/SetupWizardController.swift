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
@MainActor
final class SetupWizardController: NSObject {

    private static let windowWidth: CGFloat = 440
    private static let contentWidth: CGFloat = 400 // 440 − 2×20 outer margins
    private static let cardBodyWidth: CGFloat = 372 // 400 − 2×14 card insets
    private static let minHeight: CGFloat = 340

    private let logger = Logger(subsystem: "com.example.scribe", category: "setup")
    private let keychain = KeychainStore()
    private let downloads = ModelDownloadManager()

    private let window: NSWindow
    private var phase: SetupWizardPhase = .welcome

    // Step refs — rebuilt on every render; only the CURRENT step's are live.
    private var micStatusLabel: NSTextField?
    private var micHelpButton: NSButton?
    private var screenStatusLabel: NSTextField?
    private var screenGrantButton: NSButton?
    private var screenHelpButton: NSButton?
    private var modelProgress: NSProgressIndicator?
    private var modelPercentLabel: NSTextField?
    private var modelStatusLabel: NSTextField?
    private var modelActionButton: NSButton?
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
        screenStatusLabel = nil
        screenGrantButton = nil
        screenHelpButton = nil
        modelProgress = nil
        modelPercentLabel = nil
        modelStatusLabel = nil
        modelActionButton = nil
        apiKeyField = nil
        footerPrimaryButton = nil

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 100))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])

        stack.addArrangedSubview(makeStepCaption())
        stack.addArrangedSubview(makeTitleLabel(header.title))
        if let subtitle = header.subtitle {
            stack.addArrangedSubview(makeBodyLabel(subtitle, width: Self.contentWidth))
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

        stack.addArrangedSubview(makeFooter())

        window.contentView = content
        let height = max(Self.minHeight, ceil(content.fittingSize.height))
        // Keep the title bar anchored while the height changes per step.
        window.setFrame(
            NSRect(x: window.frame.origin.x, y: window.frame.maxY - height,
                   width: Self.windowWidth, height: height),
            display: true,
            animate: window.isVisible
        )
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
        stack.addArrangedSubview(makeBodyLabel(
            "Scribe sits in your menu bar, records the meetings you start, and turns "
                + "them into structured notes. Everything runs on your Mac: audio is "
                + "transcribed on-device, never saved, and never leaves this machine.",
            width: Self.contentWidth
        ))
        stack.addArrangedSubview(makeCard([
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
        ]))
    }

    private func makePermissionRow(symbol: String, title: String, caption: String) -> NSView {
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            icon.image = image
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
        }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSStackView(views: [titleLabel, makeBodyLabel(caption, width: 328)])
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
        micStatusLabel = NSTextField(labelWithString: "")
        micStatusLabel?.font = .systemFont(ofSize: 12, weight: .medium)

        micHelpButton = NSButton(
            title: "Open System Settings…", target: self, action: #selector(openMicSettings)
        )
        micHelpButton?.controlSize = .small
        micHelpButton?.isHidden = true

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addView(micStatusLabel!, in: .leading)
        statusRow.addView(micHelpButton!, in: .trailing)

        stack.addArrangedSubview(makeCard([
            statusRow,
            makeBodyLabel(
                "A grant is effective immediately — no relaunch needed for the microphone.",
                width: Self.cardBodyWidth
            ),
        ]))
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
            micHelpButton?.isHidden = true
        case .denied:
            micStatusLabel?.stringValue = "Microphone access is off"
            micStatusLabel?.textColor = .systemRed
            micHelpButton?.isHidden = false
        case .undetermined:
            micStatusLabel?.stringValue = "Waiting for the macOS prompt…"
            micStatusLabel?.textColor = .secondaryLabelColor
            micHelpButton?.isHidden = true
        }
    }

    // MARK: Step 2 — screen recording (TCC relaunch, SPEC §4.1)

    private func buildScreen(into stack: NSStackView) {
        screenStatusLabel = NSTextField(labelWithString: "")
        screenStatusLabel?.font = .systemFont(ofSize: 12, weight: .medium)

        screenGrantButton = NSButton(
            title: "Grant Screen Recording Access…",
            target: self,
            action: #selector(requestScreenPermission)
        )
        screenHelpButton = NSButton(
            title: "Open System Settings…", target: self, action: #selector(openScreenSettings)
        )
        screenHelpButton?.controlSize = .small
        screenHelpButton?.isHidden = true

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addView(screenStatusLabel!, in: .leading)
        statusRow.addView(screenHelpButton!, in: .trailing)

        let grantRow = NSStackView()
        grantRow.orientation = .horizontal
        grantRow.alignment = .leading
        grantRow.spacing = 8
        grantRow.addView(screenGrantButton!, in: .leading)

        stack.addArrangedSubview(makeCard([
            statusRow,
            grantRow,
            makeBodyLabel(
                "Scribe captures the meeting’s audio, not your screen: video frames are "
                    + "2×2 pixels at 1 fps and are discarded the moment they arrive.",
                width: Self.cardBodyWidth
            ),
        ]))

        // The quit-and-reopen instruction appears only after a FRESH grant
        // this run — a pre-existing (or already-relaunched) grant captures
        // fine (re-checked on every appear, SPEC §4.1).
        if screenNewlyGranted {
            stack.addArrangedSubview(makeCard([
                makeBodyLabel(
                    "Granted — now quit and reopen Scribe. macOS only applies Screen "
                        + "Recording grants after the app relaunches. Choose Quit Scribe "
                        + "(⌘Q) from the menu bar, then start Scribe again — setup resumes "
                        + "right here.",
                    width: Self.cardBodyWidth
                ),
            ]))
        }
        refreshScreenStatus()
    }

    private func refreshScreenStatus() {
        guard phase == .screenRecording else { return }
        if CapturePermissions.screenRecording == .granted {
            screenStatusLabel?.stringValue = "Screen Recording access granted ✓"
            screenStatusLabel?.textColor = .systemGreen
            screenGrantButton?.isHidden = true
            screenHelpButton?.isHidden = true
        } else if screenPromptShown {
            screenStatusLabel?.stringValue = "Not granted — enable Scribe in System Settings, then quit & reopen"
            screenStatusLabel?.textColor = .systemRed
            screenGrantButton?.isHidden = true
            screenHelpButton?.isHidden = false
        } else {
            screenStatusLabel?.stringValue = "Screen Recording access not granted"
            screenStatusLabel?.textColor = .secondaryLabelColor
            screenGrantButton?.isHidden = false
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
        stack.addArrangedSubview(makeBodyLabel(
            "Meetings are transcribed on your Mac with WhisperKit. The speech model "
                + "(“\(variant)”, \(Self.sizeHint(variant))) downloads once and is used "
                + "for every meeting.",
            width: Self.contentWidth
        ))

        modelProgress = NSProgressIndicator()
        modelProgress?.isIndeterminate = false
        modelProgress?.minValue = 0
        modelProgress?.maxValue = 1
        modelProgress?.controlSize = .small

        modelPercentLabel = NSTextField(labelWithString: "")
        modelPercentLabel?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        modelPercentLabel?.textColor = .secondaryLabelColor

        modelStatusLabel = NSTextField(labelWithString: "")
        modelStatusLabel?.font = .systemFont(ofSize: 12, weight: .medium)

        modelActionButton = NSButton(
            title: "Download", target: self, action: #selector(downloadOrRetry)
        )

        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.translatesAutoresizingMaskIntoConstraints = false
        modelProgress?.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressRow.addView(modelProgress!, in: .leading)
        progressRow.addView(modelPercentLabel!, in: .leading)

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.addView(modelStatusLabel!, in: .leading)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.alignment = .leading
        actionRow.addView(modelActionButton!, in: .leading)

        stack.addArrangedSubview(makeCard([
            progressRow,
            statusRow,
            actionRow,
            makeBodyLabel(
                "Until the model finishes, meetings record but are not transcribed. "
                    + "Retry any time — the download resumes instead of restarting.",
                width: Self.cardBodyWidth
            ),
        ]))

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
            modelActionButton?.isHidden = false
            modelActionButton?.title = "Download"
            footerPrimaryButton?.isEnabled = false
        case .downloading(let fraction):
            modelProgress?.doubleValue = fraction
            modelPercentLabel?.stringValue = "\(Int((fraction * 100).rounded())) %"
            modelStatusLabel?.stringValue = "Downloading \(SettingsKeys.whisperModelName)…"
            modelStatusLabel?.textColor = .secondaryLabelColor
            modelActionButton?.isHidden = true
            footerPrimaryButton?.isEnabled = false
        case .completed:
            modelProgress?.doubleValue = 1
            modelPercentLabel?.stringValue = "100 %"
            modelStatusLabel?.stringValue = "Downloaded — ready ✓"
            modelStatusLabel?.textColor = .systemGreen
            modelActionButton?.isHidden = true
            footerPrimaryButton?.isEnabled = true
        case .failed(let message):
            modelProgress?.doubleValue = 0
            modelPercentLabel?.stringValue = ""
            modelStatusLabel?.stringValue = "Download failed — \(message)"
            modelStatusLabel?.textColor = .systemRed
            modelActionButton?.isHidden = false
            modelActionButton?.title = "Retry"
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
        stack.addArrangedSubview(makeBodyLabel(
            "Meeting notes are written by Claude through the Anthropic API. Your key is "
                + "stored in the macOS Keychain and used only for fusion requests.",
            width: Self.contentWidth
        ))

        let hasKey = ((try? keychain.loadAPIKey()) ?? nil) != nil

        apiKeyField = NSSecureTextField()
        apiKeyField?.placeholderString = "sk-ant-…"
        apiKeyField?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField?.delegate = self
        apiKeyField?.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let fieldRow = NSStackView()
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 8
        fieldRow.addView(apiKeyField!, in: .leading)

        stack.addArrangedSubview(makeCard([
            fieldRow,
            makeBodyLabel(
                hasKey
                    ? "A key is already saved — entering a new one replaces it."
                    : "Skipping is fine: add it later in Settings. Until then, finishing a "
                        + "meeting reports a clear fusion error you can retry once a key "
                        + "is saved.",
                width: Self.cardBodyWidth
            ),
        ]))
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

    private func makeFooter() -> NSView {
        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        back.isEnabled = phase.rawValue > SetupWizardPhase.welcome.rawValue
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelWizard))

        let primary = NSButton(
            title: phase == .apiKey ? "Save & Finish" : "Continue",
            target: self,
            action: #selector(primaryAction)
        )
        primary.keyEquivalent = "\r"
        footerPrimaryButton = primary

        let right = NSStackView()
        right.orientation = .horizontal
        right.spacing = 8
        if phase == .apiKey {
            let skip = NSButton(title: "Skip for Now", target: self, action: #selector(skipAPIKey))
            right.addView(skip, in: .leading)
            primary.isEnabled = false // enabled once the field has content
        } else if phase == .modelDownload {
            switch modelState {
            case .completed, .failed: primary.isEnabled = true
            default: primary.isEnabled = false
            }
        } else {
            primary.isEnabled = true
        }
        right.addView(primary, in: .trailing)

        let left = NSStackView(views: [back, cancel])
        left.spacing = 8

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(left)
        footer.addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: footer.topAnchor),
            left.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            left.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            right.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
        ])
        return footer
    }

    @objc private func goBack() {
        guard phase.rawValue > SetupWizardPhase.welcome.rawValue,
              let previous = SetupWizardPhase(rawValue: phase.rawValue - 1) else { return }
        goTo(previous)
    }

    @objc private func primaryAction() {
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
        caption.font = .systemFont(ofSize: 10.5, weight: .semibold)
        caption.textColor = .tertiaryLabelColor
        return caption
    }

    private func makeTitleLabel(_ text: String) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 20, weight: .bold)
        return title
    }

    private func makeBodyLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// Grouped card matching SettingsWindowController's style: native
    /// `controlBackgroundColor`, radius 9, hairline border.
    private func makeCard(_ rows: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 9
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.black.withAlphaComponent(0.10).cgColor

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .width
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

// MARK: - NSTextFieldDelegate (API key field)

extension SetupWizardController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard phase == .apiKey, let field = apiKeyField else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        footerPrimaryButton?.isEnabled = !trimmed.isEmpty
    }
}
