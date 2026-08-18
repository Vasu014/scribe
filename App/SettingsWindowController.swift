import AppKit
import FusionKit
import ServiceManagement
import TranscribeKit
import os

// MARK: - Settings keys (UserDefaults)

/// UserDefaults keys + defaults for Scribe's user settings (SPEC §5 Settings).
/// The Settings window writes; `ScribeApp` reads at wiring time.
enum SettingsKeys {
    /// Whisper model name (SPEC §4.2 user setting, default `small.en`).
    /// Stored as the raw variant name; changing it applies at the NEXT
    /// session start, never mid-session.
    static let whisperModel = "whisperModel"
    static let defaultWhisperModel = WhisperModelOption.defaultsCase.name

    /// Fragment lookback in seconds (SPEC §4.3 user setting, default 20).
    /// Fusion-time transcript-anchoring only — raw audio is never retained
    /// (SPEC §4.6). Read once at app wiring; a changed value applies to
    /// fusion runs after the next launch (the fusion runner pins its lookback
    /// when constructed — see `SessionCoordinator.defaultFusionRunner`).
    static let lookbackSeconds = "lookbackSeconds"
    static let defaultLookbackSeconds: Double = 20

    /// Current lookback (seconds), defaulting to 20 when unset/invalid.
    static var lookback: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: lookbackSeconds)
        return raw > 0 ? raw : defaultLookbackSeconds
    }

    /// Current whisper model name, defaulting when unset/unknown.
    static var whisperModelName: String {
        let raw = UserDefaults.standard.string(forKey: whisperModel) ?? ""
        return WhisperModelOption(named: raw)?.name ?? defaultWhisperModel
    }

    /// DEBUG (T8): run `StubCaptureEngine` instead of `SCKCaptureEngine`
    /// (Bool, default false) — menu-bar/UI development without TCC prompts.
    static let debugUseStubCapture = "debugUseStubCapture"
}

/// Whisper model picker entries (SPEC §4.2: `tiny.en` / `base.en` /
/// `small.en` default / `large-v3-turbo` flagged as a large download).
enum WhisperModelOption: CaseIterable {
    case tinyEN
    case baseEN
    case smallEN
    case largeV3Turbo

    static let defaultsCase = WhisperModelOption.smallEN

    var name: String {
        switch self {
        case .tinyEN: "tiny.en"
        case .baseEN: "base.en"
        case .smallEN: "small.en"
        case .largeV3Turbo: "large-v3-turbo"
        }
    }

    /// Popup title; the turbo variant carries the large-download flag inline.
    var displayTitle: String {
        self == .largeV3Turbo ? "large-v3-turbo (large download)" : name
    }

    init?(named name: String) {
        guard let match = WhisperModelOption.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }
}

// MARK: - Settings window

/// Settings window (SPEC §5; design 1e): single pane, ~520 pt wide,
/// System-Settings grouped-card style (native materials over the HTML hex
/// values). Four groups: Anthropic API Key (Keychain, masked, edit-in-place),
/// Whisper Model, Lookback Window, Launch at Login (`SMAppService`).
///
/// AppKit by choice — the design is plain grouped rows, and AppKit keeps the
/// accessory-app shell free of SwiftUI lifecycle surprises.
@MainActor
final class SettingsWindowController: NSObject {

    private let logger = Logger(subsystem: "com.example.scribe", category: "settings")
    private let keychain = KeychainStore()
    private let window: NSWindow

    // Group 1 — API key
    private var maskedKeyLabel: NSTextField!
    private var staticKeyRow: NSStackView!
    private var editingKeyRow: NSStackView!
    private var secureField: NSSecureTextField!
    private var deleteKeyButton: NSButton!

    // Group 2 — Whisper model
    private var modelPopup: NSPopUpButton!
    private var modelCaption: NSTextField!

    // Group 3 — Lookback
    private var lookbackPopup: NSPopUpButton!
    private var lookbackEntries: [(title: String, seconds: Double)] = []

    // Group 4 — Launch at login
    private var loginSwitch: NSSwitch!

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        buildContent()
        // Height from the constraint graph; width pinned at 520 (design 1e).
        window.setContentSize(NSSize(width: 520, height: window.contentView?.fittingSize.height ?? 400))
    }

    /// Shows (or re-fronts) the window. Accessory app (LSUIElement), so
    /// activate explicitly or the window opens behind everything.
    func show() {
        refresh()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout (design 1e grouped cards)

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 100))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        stack.addArrangedSubview(makeAPIKeyCard())
        stack.addArrangedSubview(makeModelCard())
        stack.addArrangedSubview(makeLookbackCard())
        stack.addArrangedSubview(makeLoginCard())
        window.contentView = content
    }

    /// White card, radius 9, 0.5 pt hairline border (design 1e; native
    /// material: `controlBackgroundColor` adapts to dark mode).
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

    /// Label left, control right, 13 pt label (design 1e rows).
    private func makeRow(title: String, trailingControl: NSView? = nil) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        row.addView(label, in: .leading)
        if let control = trailingControl {
            row.addView(control, in: .trailing)
        }
        return row
    }

    private func makeCaption(_ text: String) -> NSTextField {
        let caption = NSTextField(labelWithString: text)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        return caption
    }

    // MARK: Group 1 — Anthropic API Key (Keychain, SPEC §4.5/§5)

    private func makeAPIKeyCard() -> NSView {
        maskedKeyLabel = NSTextField(labelWithString: "")
        maskedKeyLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        maskedKeyLabel.textColor = .secondaryLabelColor

        let edit = NSButton(title: "Edit…", target: self, action: #selector(beginKeyEditing))
        edit.controlSize = .small
        deleteKeyButton = NSButton(title: "Delete", target: self, action: #selector(deleteKey))
        deleteKeyButton.controlSize = .small

        staticKeyRow = makeRow(
            title: "Anthropic API Key",
            trailingControl: NSStackView(views: [maskedKeyLabel, edit, deleteKeyButton])
        )

        secureField = NSSecureTextField()
        secureField.placeholderString = "sk-ant-…"
        secureField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        secureField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        secureField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.controlSize = .small
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelKeyEditing))
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"

        editingKeyRow = makeRow(
            title: "Anthropic API Key",
            trailingControl: NSStackView(views: [secureField, save, cancel])
        )
        editingKeyRow.isHidden = true

        return makeCard([staticKeyRow, editingKeyRow, makeCaption("Stored in the macOS Keychain")])
    }

    @objc private func beginKeyEditing() {
        secureField.stringValue = ""
        staticKeyRow.isHidden = true
        editingKeyRow.isHidden = false
        window.makeFirstResponder(secureField)
    }

    @objc private func cancelKeyEditing() {
        editingKeyRow.isHidden = true
        staticKeyRow.isHidden = false
    }

    @objc private func saveKey() {
        let trimmed = secureField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelKeyEditing()
            return
        }
        do {
            try keychain.saveAPIKey(trimmed)
            cancelKeyEditing()
            refreshKeySection()
        } catch {
            presentError("Couldn't save the API key", error)
        }
    }

    @objc private func deleteKey() {
        do {
            try keychain.deleteAPIKey() // idempotent — missing item is not an error
            refreshKeySection()
        } catch {
            presentError("Couldn't delete the API key", error)
        }
    }

    private func refreshKeySection() {
        let key: String?
        do {
            key = try keychain.loadAPIKey()
        } catch {
            logger.error("Keychain read failed: \(String(describing: error), privacy: .public)")
            key = nil
        }
        maskedKeyLabel.stringValue = Self.mask(key)
        deleteKeyButton.isEnabled = key != nil
    }

    /// `••••••••••7f2a`-style mask (design 1e); "Not set" when no key exists.
    private static func mask(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "Not set" }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(repeating: "•", count: 10) + String(key.suffix(4))
    }

    // MARK: Group 2 — Whisper Model (SPEC §4.2)

    private func makeModelCard() -> NSView {
        modelPopup = NSPopUpButton()
        modelPopup.addItems(withTitles: WhisperModelOption.allCases.map(\.displayTitle))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelCaption = makeCaption("")
        return makeCard([makeRow(title: "Whisper Model", trailingControl: modelPopup), modelCaption])
    }

    @objc private func modelChanged() {
        let index = modelPopup.indexOfSelectedItem
        guard WhisperModelOption.allCases.indices.contains(index) else { return }
        UserDefaults.standard.set(WhisperModelOption.allCases[index].name, forKey: SettingsKeys.whisperModel)
        refreshModelSection()
    }

    private func refreshModelSection() {
        let option = WhisperModelOption(named: SettingsKeys.whisperModelName) ?? .defaultsCase
        if let index = WhisperModelOption.allCases.firstIndex(of: option) {
            modelPopup.selectItem(at: index)
        }
        // Presence preview; the download UI itself is the setup wizard (T8).
        let downloaded = ModelDownloadManager().isDownloaded(option.name)
        modelCaption.stringValue = downloaded
            ? "Default small.en · applies at the next session start · downloaded"
            : "Default small.en · applies at the next session start · not yet downloaded"
    }

    // MARK: Group 3 — Lookback Window (SPEC §4.3)

    private func makeLookbackCard() -> NSView {
        lookbackEntries = [
            ("20 seconds", 20), // v0 default
            ("10 seconds", 10),
            ("30 seconds", 30),
            ("60 seconds", 60),
        ]
        lookbackPopup = NSPopUpButton()
        lookbackPopup.addItems(withTitles: lookbackEntries.map(\.title))
        lookbackPopup.target = self
        lookbackPopup.action = #selector(lookbackChanged)
        return makeCard([
            makeRow(title: "Lookback Window", trailingControl: lookbackPopup),
            makeCaption("Advanced — how far back fusion anchors a fragment in the transcript"),
        ])
    }

    @objc private func lookbackChanged() {
        let index = lookbackPopup.indexOfSelectedItem
        guard lookbackEntries.indices.contains(index) else { return }
        UserDefaults.standard.set(lookbackEntries[index].seconds, forKey: SettingsKeys.lookbackSeconds)
    }

    private func refreshLookbackSection() {
        let current = SettingsKeys.lookback
        if let index = lookbackEntries.firstIndex(where: { $0.seconds == current }) {
            lookbackPopup.selectItem(at: index)
        }
    }

    // MARK: Group 4 — Launch at Login

    private func makeLoginCard() -> NSView {
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggleChanged)
        return makeCard([makeRow(title: "Launch at Login", trailingControl: loginSwitch)])
    }

    @objc private func loginToggleChanged() {
        do {
            if loginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            presentError("Couldn't change Launch at Login", error)
        }
        refreshLoginSection()
    }

    /// Reflects the REAL service status — `requiresApproval` shows as on
    /// (the user must approve it in System Settings > Login Items).
    private func refreshLoginSection() {
        let status = SMAppService.mainApp.status
        loginSwitch.state = (status == .enabled || status == .requiresApproval) ? .on : .off
    }

    // MARK: - Misc

    private func refresh() {
        refreshKeySection()
        refreshModelSection()
        refreshLookbackSection()
        refreshLoginSection()
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
