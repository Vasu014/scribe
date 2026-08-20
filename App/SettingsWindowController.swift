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
    // Multilingual variants. The `.en` models above are English-ONLY: they
    // are trained on English audio and will garble or force-translate any
    // other language, silently and confidently. Any meeting that is not
    // wholly in English needs one of these.
    case small
    case largeV3Turbo
    /// Hindi→Hinglish fine-tune (Oriserve, CoreML-converted by a third party).
    /// Transcribes Hindi speech as ROMANIZED Hinglish, not Devanagari — the
    /// right choice for Hindi/English code-switched meetings, the wrong one if
    /// you want Devanagari output. Lives in a different HF repo from every
    /// other variant, which is why `repo` exists on the download path.
    case hinglish
    /// Hinglish LARGE — `Trelis/whisper-hinglish-preview` (Apache-2.0, a
    /// whisper-large-v3 fine-tune for Hindi/English code-switched speech),
    /// converted to Core ML float16 with Argmax's `whisperkittools`.
    ///
    /// FLOAT16 (the reference precision), never quantized: a quantized
    /// third-party Hinglish build is what produced segments reading the
    /// literal string `nan`, and the trade this app takes is a large model
    /// that transcribes over a small one that does not.
    ///
    /// Output script differs from `.hinglish` above: this one writes Hindi in
    /// DEVANAGARI and keeps English words in Latin inside the same sentence
    /// ("नमस्ते team, आज का stand up…"), which is what its benchmarks are
    /// measured on. Pick `.hinglish` if romanized Hindi is wanted instead.
    ///
    /// Converted locally with `whisperkittools`, with ONE deviation from a
    /// stock run: the fine-tune adds a 51867th token (`<|mixedcode|>`, an
    /// optional *prompt* marker) and WhisperKit picks its tokenizer purely
    /// from the decoder's logits width — 51866 means large-v3, anything else
    /// silently falls back to `openai/whisper-base`, whose special-token ids
    /// are all shifted. The extra embedding row is dropped before conversion
    /// so the decoder is exactly large-v3 shaped. WhisperKit never feeds or
    /// emits that token, so nothing is lost.
    case hinglishLarge
    /// Hinglish LARGE, ROMANIZED — `Oriserve/Whisper-Hindi2Hinglish-Prime`
    /// (Apache-2.0, a whisper-large-v3 fine-tune, the most-downloaded Hindi→
    /// Hinglish model on the Hub), converted to Core ML float16 with Argmax's
    /// `whisperkittools`.
    ///
    /// Same size class as `.hinglishLarge`; the difference is the OUTPUT
    /// SCRIPT. This one writes Hindi in LATIN letters ("namaste team, aaj ka
    /// stand up…") — romanized Hinglish is what the fine-tune is trained to
    /// emit, and it is the reason this case exists, because `.hinglishLarge`
    /// writes the same speech in Devanagari.
    ///
    /// FLOAT16, never quantized — same trade as `.hinglishLarge`, and here the
    /// counter-example is direct: `.hinglish` above is a QUANTIZED conversion
    /// of THIS SAME upstream model, and every segment it emits is the literal
    /// string `nan`. The model is fine; that conversion is not.
    ///
    /// Nothing had to be reshaped for the conversion (unlike `.hinglishLarge`,
    /// which needed a token row dropped): this fine-tune's vocab is already
    /// 51866, i.e. exactly large-v3 shaped, so WhisperKit picks the large-v3
    /// tokenizer from the decoder's logits width on its own.
    ///
    /// The `_fp16` suffix on the folder is load-bearing. `WhisperModelLocator`
    /// finds a variant by `contains(variant)` and returns the FIRST match, so
    /// a folder named for the bare model version would be a prefix of
    /// `Oriserve_Whisper-Hindi2Hinglish-Prime_889MB` — the broken quantized
    /// build in `.hinglish`, which is on disk right next to it — and the
    /// selection would resolve to whichever the directory enumerator reached
    /// first. The suffix makes neither name a substring of the other.
    case hinglishLargeRomanized

    static let defaultsCase = WhisperModelOption.smallEN

    /// The WhisperKit variant id — what gets persisted, fetched
    /// (`ModelDownloadManager`) and loaded (`WhisperKitEngine`).
    ///
    /// SPEC §4.2 spells the last one `large-v3-turbo`; the model repo
    /// (`argmaxinc/whisperkit-coreml`) publishes it as
    /// `openai_whisper-large-v3_turbo`, i.e. variant `large-v3_turbo`, and
    /// WhisperKit resolves a variant by globbing `*openai*<variant>/*`. The
    /// spec's spelling matches NOTHING in the repo, so picking that option
    /// used to fail with `No models found matching "*openai*large-v3-turbo/*"`
    /// — an option the app offers and can never satisfy. The repo's id wins:
    /// this is a name in someone else's namespace, and the alternative is a
    /// picker entry that is permanently broken.
    var name: String {
        switch self {
        case .tinyEN: "tiny.en"
        case .baseEN: "base.en"
        case .smallEN: "small.en"
        case .small: "small"
        case .largeV3Turbo: "large-v3_turbo"
        case .hinglish: "Oriserve_Whisper-Hindi2Hinglish-Prime_889MB"
        // whisperkittools names the generated folder after the source repo
        // with `/` → `_`; that folder name IS the variant WhisperKit globs for.
        case .hinglishLarge: "Trelis_whisper-hinglish-preview"
        // `_fp16` disambiguates this folder from the `_889MB` quantized build
        // above; see the case comment. It is NOT a whisperkittools default —
        // the conversion was run with `--repo-path-suffix fp16`.
        case .hinglishLargeRomanized: "Oriserve_Whisper-Hindi2Hinglish-Prime_fp16"
        }
    }

    /// SPEC §4.2 flags this variant as a large download. The Settings popup
    /// lists the bare model names (design 1e's option list), so the flag is
    /// surfaced in the row's caption when this variant is selected.
    var isLargeDownload: Bool {
        self == .largeV3Turbo || self == .hinglish || self == .hinglishLarge
            || self == .hinglishLargeRomanized
    }

    /// What the popup shows: language plus size class, never the raw
    /// WhisperKit variant id (a 40-character folder name for a fine-tune).
    var displayTitle: String {
        switch self {
        case .tinyEN: "English — Tiny"
        case .baseEN: "English — Base"
        case .smallEN: "English — Small"
        case .small: "Multilingual — Small"
        case .largeV3Turbo: "Multilingual — Large"
        case .hinglish: "Hinglish — Small"
        // Both large Hinglish builds are the same language and size class, so
        // the script is the only thing that tells them apart in the popup —
        // and it is the whole reason to pick one over the other.
        case .hinglishLarge: "Hinglish — Large (Devanagari)"
        case .hinglishLargeRomanized: "Hinglish — Large (romanized)"
        }
    }

    /// Approximate download size, shown only while the model is missing —
    /// the one moment the number is actionable.
    var approximateSize: String {
        switch self {
        case .tinyEN: "75 MB"
        case .baseEN: "145 MB"
        case .smallEN, .small: "480 MB"
        case .hinglish: "890 MB"
        case .largeV3Turbo: "1.5 GB"
        case .hinglishLarge: "2.9 GB"
        case .hinglishLargeRomanized: "2.9 GB"
        }
    }

    /// Hugging Face repo holding this variant. Fine-tunes are not in Argmax's
    /// catalogue, so the repo travels with the variant.
    var repo: String {
        switch self {
        case .hinglish: "nitinh/whisperkit-hinglish-coreml"
        // Generated locally by `whisperkittools`; this is where the build is
        // to be published so other installs can fetch it. Nothing else in the
        // app reads `repo` when the variant is already on disk.
        case .hinglishLarge: "vbhar/whisperkit-hinglish-large-v3-coreml"
        case .hinglishLargeRomanized: "vbhar/whisperkit-hindi2hinglish-prime-coreml"
        default: ModelDownloadManager.defaultRepo
        }
    }


    /// The SPEC §4.2 spelling of a variant, still accepted so a value
    /// persisted before the id above was corrected resolves to its option
    /// instead of silently reverting to the default.
    private var legacyName: String? {
        self == .largeV3Turbo ? "large-v3-turbo" : nil
    }

    init?(named name: String) {
        guard let match = WhisperModelOption.allCases.first(where: {
            $0.name == name || $0.legacyName == name
        }) else { return nil }
        self = match
    }
}

// MARK: - Settings window

/// Settings window (SPEC §5; design 1e): single pane, 520 pt wide,
/// System-Settings grouped-card style (native system colors over the HTML hex
/// values). Three cards: Anthropic API Key (Keychain, masked, edit-in-place);
/// Whisper Model + Lookback Window (two rows, hairline-separated); Launch at
/// Login (`SMAppService`).
///
/// AppKit by choice — the design is plain grouped rows, and AppKit keeps the
/// accessory-app shell free of SwiftUI lifecycle surprises.
///
/// Accessibility notes:
/// - VoiceOver: every control is named after its row (see `makeRow`), because
///   an `NSSwitch` announces only its state and an `NSPopUpButton` only its
///   selected title — the row title next to them is an unrelated static text.
/// - Increase Contrast: the design's 0.5 pt hairlines are doubled and darkened
///   (see `ContrastMetrics`), re-read live on
///   `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
/// - Text size: fonts are fixed point sizes. macOS has no Dynamic Type for
///   AppKit — `NSFont.preferredFont(forTextStyle:)` returns a font that does
///   NOT track the system text-size setting — so adopting text styles would
///   only re-point the design's 13/11 pt grouped-row metrics without gaining
///   any scaling. Accepted as a v0 limitation; what IS guaranteed is that a
///   longer string never clips: row labels and captions wrap inside the left
///   column and the window re-solves its height (`resizeToFit`).
@MainActor
final class SettingsWindowController: NSObject {

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "settings")
    private let keychain = KeychainStore()
    private let window: NSWindow
    /// App-owned hook for best-effort preparation after selection/download.
    var onSpeechModelReady: (() -> Void)?

    // Group 1 — API key
    private var maskedKeyLabel: NSTextField!
    /// The drawn chip around `maskedKeyLabel` — it, not the label, is the
    /// accessibility element for the key (see `makeKeyChip`).
    private var keyChip: NSView!
    private var staticKeyRow: NSView!
    private var editingKeyRow: NSView!
    private var secureField: NSSecureTextField!
    private var deleteKeyButton: NSButton!
    /// Undo affordance for a deleted key (finding 25) — see `offerUndo`.
    private var undoDeleteButton: NSButton!
    private var deletedKeyHolder: String?
    private var undoExpiry: Task<Void, Never>?

    // Group 2, row 1 — Whisper model
    private var modelPopup: NSPopUpButton!
    private var modelCaption: NSTextField!
    /// Download/Retry for the SELECTED variant — the app's only way to fetch
    /// a model after setup completes (see `refreshModelSection`).
    private var modelDownloadButton: NSButton!
    private let downloads = ModelDownloadManager()
    private var modelDownloadTask: Task<Void, Never>?
    private var modelDownload: ModelDownloadUIState = .idle

    /// What the model row is doing right now. `.idle` defers to the
    /// on-disk presence check; the other cases describe a fetch this window
    /// started.
    private enum ModelDownloadUIState: Equatable {
        case idle
        case downloading(variant: String, fraction: Double)
        case failed(variant: String, message: String)
    }

    // Group 2, row 2 — Lookback
    private var lookbackPopup: NSPopUpButton!
    private var lookbackEntries: [(title: String, seconds: Double)] = []

    // Group 3 — Launch at login
    private var loginSwitch: NSSwitch!

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        buildContent() // also sizes the window from the solved layout
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

    /// Design 1e geometry. The window is fixed-width, so the card and caption
    /// widths are derivable constants rather than runtime measurements.
    private enum Metrics {
        static let windowWidth: CGFloat = 520
        static let contentInsetX: CGFloat = 20
        static let contentInsetTop: CGFloat = 10
        static let contentInsetBottom: CGFloat = 24
        /// Gap between group cards.
        static let cardSpacing: CGFloat = 14
        /// Card padding is horizontal only — rows supply the vertical padding.
        static let cardPaddingX: CGFloat = 14
        static let rowPaddingY: CGFloat = 11
        static let rowGap: CGFloat = 12
        /// Usable width inside a card; captions wrap against what's left of it.
        static let cardInnerWidth = windowWidth - 2 * contentInsetX - 2 * cardPaddingX
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: 100))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = Metrics.cardSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.contentInsetTop),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Metrics.contentInsetBottom),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Metrics.contentInsetX),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Metrics.contentInsetX),
            // Pin the WIDTH before measuring: `fittingSize` is a minimum-size
            // solve, so with no width constraint the wrapping captions report
            // single-line intrinsic sizes and the window comes out too short
            // (the same under-measurement that broke the setup wizard).
            content.widthAnchor.constraint(equalToConstant: Metrics.windowWidth),
        ])

        // Three cards (design 1e): API key · model + lookback · launch at login.
        for card in [makeAPIKeyCard(), makeModelAndLookbackCard(), makeLoginCard()] {
            stack.addArrangedSubview(card)
            pinFullWidth(card, in: stack)
        }

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        // Height from the solved constraint graph; width pinned at 520.
        window.setContentSize(NSSize(width: Metrics.windowWidth, height: ceil(content.fittingSize.height)))
    }

    /// Grouped card: `controlBackgroundColor` fill, radius 9, 0.5 pt hairline
    /// border, rows separated by a hairline inset to the card's inner width
    /// and absent after the last row (design 1e).
    private func makeCard(_ rows: [NSView]) -> NSView {
        let card = CardView()
        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .width
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.cardPaddingX),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.cardPaddingX),
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = HairlineView()
                inner.addArrangedSubview(separator)
                pinFullWidth(separator, in: inner)
            }
            inner.addArrangedSubview(row)
            pinFullWidth(row, in: inner)
        }
        return card
    }

    /// `NSStackView`'s `alignment = .width` does not reliably hold arranged
    /// subviews at the stack's full width — the cards, and then the rows
    /// inside them, both ended up hugging their content and trailing-aligned.
    /// Pinning both edges is what actually spans the column.
    private func pinFullWidth(_ view: NSView, in stack: NSStackView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    /// One card row: 13 pt label plus an optional 11 pt caption in a flexible
    /// left column, control flush against the card's inner trailing edge
    /// (design 1e: `label column { flex: 1 }`, control right-aligned).
    private func makeRow(title: String, caption: NSTextField? = nil, control: NSView? = nil) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        // Wrapping, not truncating (finding 24): the design's titles all fit
        // on one line, but a longer localization has to break inside the left
        // column — the row's height is content-driven, so it just grows.
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false
        (label.cell as? NSTextFieldCell)?.wraps = true

        let column = NSStackView(views: caption.map { [label, $0] } ?? [label])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1 // caption margin-top
        column.translatesAutoresizingMaskIntoConstraints = false
        // The column takes the slack; the control keeps its intrinsic width.
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        column.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        row.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            column.topAnchor.constraint(equalTo: row.topAnchor, constant: Metrics.rowPaddingY),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -Metrics.rowPaddingY),
        ])

        guard let control else {
            column.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
            return row
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: column.trailingAnchor, constant: Metrics.rowGap),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: Metrics.rowPaddingY),
            control.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -Metrics.rowPaddingY),
        ])
        // Label and caption wrap inside the left column, never under the
        // control. The window is fixed-width, so the wrap width is the card's
        // inner width minus this row's control — known here, which keeps the
        // measured height and the drawn height in agreement.
        let wrapWidth = max(
            160,
            Metrics.cardInnerWidth - Metrics.rowGap - ceil(control.fittingSize.width)
        )
        label.preferredMaxLayoutWidth = wrapWidth
        caption?.preferredMaxLayoutWidth = wrapWidth

        // VoiceOver (finding 15): the row title is a separate static text with
        // no relationship to the control, so a bare `NSSwitch` announced
        // "switch, on" and a popup only its selected title. Naming the control
        // after the row it belongs to is cheapest right here, where the title
        // is in hand, and yields "Launch at Login, switch, on" / "Whisper
        // Model, pop up button, small.en". Control GROUPS (the API-key
        // cluster) are not elements themselves — their members are labelled
        // individually at their construction site.
        if !(control is NSStackView) {
            control.setAccessibilityLabel(title)
            if let caption, !caption.stringValue.isEmpty {
                control.setAccessibilityHelp(caption.stringValue)
            }
        }
        return row
    }

    /// 11 pt secondary caption, left-aligned under its row's label and free to
    /// wrap within the left column (design 1e).
    private func makeCaption(_ text: String) -> NSTextField {
        let caption = NSTextField(labelWithString: text)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .left
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 0
        caption.cell?.usesSingleLineMode = false
        (caption.cell as? NSTextFieldCell)?.wraps = true
        return caption
    }

    // MARK: Group 1 — Anthropic API Key (Keychain, SPEC §4.5/§5)

    private func makeAPIKeyCard() -> NSView {
        // SF Mono with tabular figures — the mask must not jitter (design 1e).
        maskedKeyLabel = NSTextField(labelWithString: "")
        maskedKeyLabel.font = Formatting.elapsedFont(ofSize: 13, weight: .regular)
        maskedKeyLabel.textColor = .secondaryLabelColor
        // Pre-fill the widest mask so the row measures its caption's wrap
        // width against the control width it will actually have.
        applyMask(Self.mask(String(repeating: "x", count: 20)), spaced: true)

        let edit = NSButton(title: "Edit…", target: self, action: #selector(beginKeyEditing))
        edit.controlSize = .small
        edit.setAccessibilityLabel("Edit the Anthropic API Key")
        deleteKeyButton = NSButton(title: "Delete", target: self, action: #selector(deleteKey))
        deleteKeyButton.controlSize = .small
        // Finding 25 without a third confirm (§3b allows exactly two, and this
        // is not one of them): destructive tint so the button reads as the one
        // that removes something, a wider gap from the "Edit…" it sits one
        // mis-click away from, and an Undo that makes the action recoverable.
        deleteKeyButton.hasDestructiveAction = true
        deleteKeyButton.setAccessibilityLabel("Delete the Anthropic API Key")

        undoDeleteButton = NSButton(title: "Undo", target: self, action: #selector(undoDeleteKey))
        undoDeleteButton.controlSize = .small
        undoDeleteButton.isHidden = true // shown for 10 s after a delete
        undoDeleteButton.setAccessibilityLabel("Undo deleting the Anthropic API Key")

        keyChip = makeKeyChip(maskedKeyLabel)
        let keyControls = makeControlGroup([keyChip, edit, deleteKeyButton, undoDeleteButton])
        keyControls.setCustomSpacing(16, after: edit) // Delete stands apart

        staticKeyRow = makeRow(
            title: "Anthropic API Key",
            caption: makeCaption("Stored in the macOS Keychain"),
            control: keyControls
        )

        secureField = NSSecureTextField()
        secureField.placeholderString = "sk-ant-…"
        secureField.font = Formatting.elapsedFont(ofSize: 13, weight: .regular)
        secureField.setAccessibilityLabel("Anthropic API Key")
        secureField.setAccessibilityHelp("Stored in the macOS Keychain")
        secureField.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        // Preferred, not required, and below the label column's compression
        // resistance — the field yields first, so the label and its caption
        // keep the same width (and the row the same height) in both states.
        let preferredWidth = secureField.widthAnchor.constraint(equalToConstant: 220)
        preferredWidth.priority = NSLayoutConstraint.Priority(200)
        NSLayoutConstraint.activate([
            secureField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            preferredWidth,
        ])

        let save = NSButton(title: "Save", target: self, action: #selector(saveKey))
        save.controlSize = .small
        save.keyEquivalent = "\r"
        save.setAccessibilityLabel("Save the Anthropic API Key")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelKeyEditing))
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel editing the Anthropic API Key")

        editingKeyRow = makeRow(
            title: "Anthropic API Key",
            caption: makeCaption("Stored in the macOS Keychain"),
            control: makeControlGroup([secureField, save, cancel])
        )
        editingKeyRow.isHidden = true

        // One logical row in two mutually exclusive states — a stack, so the
        // hidden state collapses and no separator lands between them.
        let keyRow = NSStackView(views: [staticKeyRow, editingKeyRow])
        keyRow.orientation = .vertical
        keyRow.alignment = .width
        keyRow.spacing = 0
        pinFullWidth(staticKeyRow, in: keyRow)
        pinFullWidth(editingKeyRow, in: keyRow)
        return makeCard([keyRow])
    }

    /// Right-hand control cluster for a row (masked key + buttons, field +
    /// Save/Cancel): horizontal, centred, content-hugging so it stays at its
    /// intrinsic width against the card's trailing edge.
    private func makeControlGroup(_ views: [NSView]) -> NSStackView {
        let group = NSStackView(views: views)
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 8
        group.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return group
    }

    /// The masked key sits in a soft rounded chip (design 1e: `rgba(0,0,0,.04)`
    /// fill, 0.5 pt border, radius 6, padding 4/10 — system colors here).
    /// The CHIP, not the label inside it, is the accessibility element for the
    /// key (finding 15): on its own the label was an anonymous row of bullets,
    /// and `NSTextField` answers `accessibilityValue()` with its own string —
    /// it ignores `setAccessibilityValue(_:)`, verified by reading the
    /// attribute back out of a running build. Naming the container and hiding
    /// the label from the tree gives VoiceOver "Anthropic API Key, Saved,
    /// ending in 7f2a" (the value is written in `refreshKeySection`).
    private func makeKeyChip(_ label: NSTextField) -> NSView {
        let chip = ChipView()
        label.setAccessibilityElement(false)
        chip.setAccessibilityElement(true)
        chip.setAccessibilityRole(.staticText)
        chip.setAccessibilityLabel("Anthropic API Key")
        chip.setAccessibilityHelp("Stored in the macOS Keychain")
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
        ])
        return chip
    }

    @objc private func beginKeyEditing() {
        clearUndo()
        secureField.stringValue = ""
        staticKeyRow.isHidden = true
        editingKeyRow.isHidden = false
        resizeToFit()
        window.makeFirstResponder(secureField)
    }

    @objc private func cancelKeyEditing() {
        editingKeyRow.isHidden = true
        staticKeyRow.isHidden = false
        resizeToFit()
    }

    @objc private func saveKey() {
        // Commit the field editor first: Save carries Return as its key
        // equivalent, and AppKit dispatches key equivalents BEFORE the field
        // editor sees the keystroke, so the cell could still hold the value
        // from before the last keypress.
        window.endEditing(for: nil)
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
        let previous = (try? keychain.loadAPIKey()) ?? nil
        do {
            try keychain.deleteAPIKey() // idempotent — missing item is not an error
            offerUndo(previous)
            refreshKeySection()
        } catch {
            presentError("Couldn't delete the API key", error)
        }
    }

    /// Finding 25: key deletion is destructive and sits one mis-click from
    /// "Edit…", but §3b budgets exactly two confirms in the app (quit-while-
    /// recording and session Delete) and this is neither — so the action is
    /// made RECOVERABLE instead of guarded. The deleted key is held in memory
    /// (it was already in this process, having just been read out of the
    /// Keychain) and an Undo button takes its place for 10 s, after which the
    /// holder is dropped. No modal, no extra click on the happy path.
    private func offerUndo(_ key: String?) {
        undoExpiry?.cancel()
        undoExpiry = nil
        guard let key, !key.isEmpty else {
            deletedKeyHolder = nil
            undoDeleteButton.isHidden = true
            return
        }
        deletedKeyHolder = key
        undoDeleteButton.isHidden = false
        resizeToFit() // the row's caption can re-wrap around the wider cluster
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.clearUndo()
        }
    }

    @objc private func undoDeleteKey() {
        guard let key = deletedKeyHolder else {
            clearUndo()
            return
        }
        do {
            try keychain.saveAPIKey(key)
            clearUndo()
            refreshKeySection()
        } catch {
            presentError("Couldn't restore the API key", error)
        }
    }

    /// Drops the in-memory copy of the deleted key and hides the affordance.
    private func clearUndo() {
        undoExpiry?.cancel()
        undoExpiry = nil
        deletedKeyHolder = nil
        guard undoDeleteButton != nil, !undoDeleteButton.isHidden else { return }
        undoDeleteButton.isHidden = true
        resizeToFit()
    }

    private func refreshKeySection() {
        let key: String?
        do {
            key = try keychain.loadAPIKey()
        } catch {
            logger.error("Keychain read failed: \(String(describing: error), privacy: .public)")
            key = nil
        }
        applyMask(Self.mask(key), spaced: key != nil)
        // Spoken form of the chip (finding 15): the visible mask is bullets,
        // which VoiceOver would read out one by one. Never announce more of
        // the key than the mask shows.
        if let key, !key.isEmpty {
            keyChip.setAccessibilityValue(
                key.count > 8 ? "Saved, ending in \(String(key.suffix(4)))" : "Saved"
            )
        } else {
            keyChip.setAccessibilityValue("Not set")
        }
        deleteKeyButton.isEnabled = key != nil
    }

    /// Draws the mask with the design's letter-spacing (1e specifies `.14em`;
    /// trimmed slightly so the row's caption still fits on one line). The
    /// "Not set" placeholder renders unspaced.
    private func applyMask(_ text: String, spaced: Bool) {
        maskedKeyLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: maskedKeyLabel.font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: spaced ? 1.2 : 0,
            ]
        )
    }

    /// `••••••••••7f2a`-style mask (design 1e); "Not set" when no key exists.
    private static func mask(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "Not set" }
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return String(repeating: "•", count: 10) + String(key.suffix(4))
    }

    // MARK: Group 2 — Whisper Model (SPEC §4.2) + Lookback Window (SPEC §4.3)

    /// Design 1e groups these as two hairline-separated rows in ONE card.
    private func makeModelAndLookbackCard() -> NSView {
        modelPopup = NSPopUpButton()
        modelPopup.addItems(withTitles: WhisperModelOption.allCases.map(\.displayTitle))
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // The row's control is a GROUP (popup + Download), and `makeRow`
        // labels only non-group controls — members are named here.
        modelPopup.setAccessibilityLabel("Whisper Model")
        modelCaption = makeCaption("")
        // The picker used to write the variant and merely REPORT "not
        // downloaded": the fetch lived only in the setup wizard, which
        // nothing reopens once setup completes, so picking a variant the
        // user did not have was a one-way trip into meetings that record for
        // an hour and transcribe nothing. The row downloads it now.
        modelDownloadButton = NSButton(title: "Download", target: self, action: #selector(downloadModel))
        modelDownloadButton.controlSize = .small
        modelDownloadButton.setAccessibilityLabel("Download the selected speech model")

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
        lookbackPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        return makeCard([
            makeRow(
                title: "Whisper Model",
                caption: modelCaption,
                control: makeControlGroup([modelPopup, modelDownloadButton])
            ),
            makeRow(
                title: "Lookback Window",
                caption: makeCaption("Advanced — how far back fusion anchors a fragment"),
                control: lookbackPopup
            ),
        ])
    }

    @objc private func modelChanged() {
        let index = modelPopup.indexOfSelectedItem
        guard WhisperModelOption.allCases.indices.contains(index) else { return }
        // A fetch belongs to the variant it was started for; switching the
        // selection abandons it (WhisperKit resumes rather than restarts, so
        // nothing is thrown away — see `ModelDownloadManager`).
        cancelModelDownload()
        UserDefaults.standard.set(WhisperModelOption.allCases[index].name, forKey: SettingsKeys.whisperModel)
        refreshModelSection()
        if downloads.isDownloaded(SettingsKeys.whisperModelName) {
            onSpeechModelReady?()
        }
    }

    /// Fetches the SELECTED variant with `ModelDownloadManager` — the same
    /// plumbing the setup wizard uses (SPEC §4.2 "model download … with
    /// progress UI"), reused rather than reimplemented. Progress and failure
    /// land in the row's caption; the button becomes Retry on failure.
    @objc private func downloadModel() {
        let variant = SettingsKeys.whisperModelName
        cancelModelDownload()
        modelDownload = .downloading(variant: variant, fraction: 0)
        refreshModelSection()
        let downloads = self.downloads
        // Inherits the main actor (this type is @MainActor), so the UI
        // updates below need no hop.
        modelDownloadTask = Task { [weak self] in
            // The repo travels with the variant: fine-tunes (Hinglish) are not in
            // Argmax's catalogue, and fetching them from it 404s.
            let repo = WhisperModelOption(named: variant)?.repo ?? ModelDownloadManager.defaultRepo
            for await event in downloads.download(variant, repo: repo) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .progress(let fraction):
                    // Progress arrives many times a second and every caption
                    // change re-solves the card's height — whole percents only.
                    guard case .downloading(_, let shown) = self.modelDownload,
                          Int((fraction * 100).rounded()) != Int((shown * 100).rounded())
                    else { continue }
                    self.modelDownload = .downloading(variant: variant, fraction: fraction)
                case .completed:
                    self.modelDownload = .idle // presence check takes over
                    self.onSpeechModelReady?()
                case .failed(let message):
                    self.logger.error("""
                    Model download failed for '\(variant, privacy: .public)': \
                    \(message, privacy: .public)
                    """)
                    self.modelDownload = .failed(variant: variant, message: message)
                }
                self.refreshModelSection()
            }
        }
    }

    private func cancelModelDownload() {
        modelDownloadTask?.cancel()
        modelDownloadTask = nil
        modelDownload = .idle
    }

    /// The model row's whole story in one caption plus one button: which
    /// variant is selected, whether it is actually on disk, what happens if
    /// it is not, and the one action that fixes it.
    ///
    /// The "not downloaded" wording is deliberately consequential rather than
    /// descriptive: the previous caption said "not downloaded" next to a
    /// picker that could not download anything, and the user's next meeting
    /// recorded for an hour with an empty transcript and no other signal.
    private func refreshModelSection() {
        let option = WhisperModelOption(named: SettingsKeys.whisperModelName) ?? .defaultsCase
        if let index = WhisperModelOption.allCases.firstIndex(of: option) {
            modelPopup.selectItem(at: index)
        }
        // The large-download flag (SPEC §4.2) rides in the caption, not in
        // the popup title (design 1e lists bare model names).
        // Language capability leads the caption: picking an English-only
        // model for a non-English meeting fails SILENTLY (plausible nonsense,
        // no error), so it has to be visible before recording, not after.
        // The caption says only what the user must DO. Which languages a
        // model handles is in its title; the download size matters only while
        // it is missing. Everything else was jargon (variant ids, "Large
        // download", the language arrow) that pushed the one actionable fact
        // onto a third line.
        switch modelDownload {
        case .downloading(let variant, let fraction) where variant == option.name:
            modelCaption.stringValue = "Downloading… \(Int((fraction * 100).rounded())) %"
            modelCaption.textColor = .secondaryLabelColor
            modelDownloadButton.isHidden = true
        case .failed(let variant, let message) where variant == option.name:
            modelCaption.stringValue = "Download failed — \(message)"
            modelCaption.textColor = .systemRed
            modelDownloadButton.isHidden = false
            modelDownloadButton.title = "Retry"
            modelDownloadButton.setAccessibilityLabel("Retry downloading the selected speech model")
        default:
            if downloads.isDownloaded(option.name) {
                modelCaption.stringValue = "Ready · applies at your next meeting"
                modelCaption.textColor = .secondaryLabelColor
                modelDownloadButton.isHidden = true
            } else {
                modelCaption.stringValue =
                    "Not downloaded (\(option.approximateSize)) — meetings can’t start"
                modelCaption.textColor = .systemRed
                modelDownloadButton.isHidden = false
                modelDownloadButton.title = "Download"
                modelDownloadButton.setAccessibilityLabel("Download the selected speech model")
            }
        }
        // The caption is built empty, so its VoiceOver help is attached here,
        // where the text actually exists (finding 15).
        modelPopup.setAccessibilityHelp(modelCaption.stringValue)
        // Caption length changes with the state (and the Download button
        // comes and goes), so the card's height has to be re-solved.
        resizeToFit()
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

    // MARK: Group 3 — Launch at Login

    private func makeLoginCard() -> NSView {
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggleChanged)
        return makeCard([makeRow(title: "Launch at Login", control: loginSwitch)])
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
        clearUndo() // a stale Undo must not survive a close/re-open
        refreshKeySection()
        refreshModelSection()
        refreshLookbackSection()
        refreshLoginSection()
        resizeToFit()
    }

    /// Re-solves the layout and re-sizes the window, keeping the title bar
    /// anchored. Row heights are content-driven (the API key row swaps between
    /// two states; the model caption's wrap depends on its text), so the
    /// height measured at build time is not necessarily the final one.
    private func resizeToFit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        guard abs(height - content.frame.height) > 0.5 else { return }
        let frame = window.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: height)
        )
        window.setFrame(
            NSRect(
                x: window.frame.origin.x,
                y: window.frame.maxY - frame.height,
                width: frame.width,
                height: frame.height
            ),
            display: true
        )
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

// MARK: - Appearance-aware layer views

/// Increase Contrast (finding 23). Design 1e's chrome is all 0.5 pt hairlines
/// at `separatorColor`; at the system's "Increase contrast" setting those are
/// exactly the strokes that disappear, so they double in width and step up to
/// a colour that actually reads. Every value is computed at DRAW time, and
/// `AppearanceAwareView` re-draws on the change notification, so a mid-session
/// toggle applies live rather than at the next relayout.
///
/// This is the pattern the other surfaces should copy: read the flag inside
/// `updateLayer()`/`draw(_:)`, never cache it, and observe
/// `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.
private enum ContrastMetrics {
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var hairlineWidth: CGFloat { increaseContrast ? 1 : 0.5 }

    static var hairlineColor: NSColor { increaseContrast ? .tertiaryLabelColor : .separatorColor }
}

/// Layer-backed view that re-resolves its CALayer colors on every appearance
/// change. A `CGColor` snapshots the appearance it was created under and never
/// updates itself — which is why the old hardcoded black-alpha border was
/// invisible in dark mode. Subclasses put their colors in `updateLayer()`.
///
/// It also re-draws when the accessibility display options change, so
/// Increase Contrast takes effect while the window is open (finding 23).
private class AppearanceAwareView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // NSNotificationCenter has held observers as zeroing weak references
        // since 10.11, so no explicit removal is needed in `deinit`.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — Settings builds its views in code")
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true // re-runs updateLayer() under the new appearance
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        invalidateIntrinsicContentSize() // hairline height tracks the setting
        needsDisplay = true
    }
}

/// Group card (design 1e): radius 9, 0.5 pt hairline border, control-background
/// fill — the native stand-ins for `#fff` / `rgba(0,0,0,.1)`.
private final class CardView: AppearanceAwareView {
    override func updateLayer() {
        layer?.cornerRadius = 9
        layer?.borderWidth = ContrastMetrics.hairlineWidth
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = ContrastMetrics.hairlineColor.cgColor
    }
}

/// 0.5 pt row separator inside a card (design 1e: between rows, never after
/// the last one). Inset to the card's inner width by the card's inner stack.
private final class HairlineView: AppearanceAwareView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ContrastMetrics.hairlineWidth)
    }

    override func updateLayer() {
        layer?.backgroundColor = ContrastMetrics.hairlineColor.cgColor
    }
}

/// Soft rounded chip behind the masked API key (design 1e: `rgba(0,0,0,.04)`
/// fill, 0.5 pt border, radius 6).
private final class ChipView: AppearanceAwareView {
    override func updateLayer() {
        layer?.cornerRadius = 6
        layer?.borderWidth = ContrastMetrics.hairlineWidth
        layer?.backgroundColor = NSColor.quinaryLabel.cgColor
        layer?.borderColor = ContrastMetrics.hairlineColor.cgColor
    }
}
