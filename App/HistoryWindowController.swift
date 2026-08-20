import AppKit
import CaptureKit
import FusionKit
import Persistence
import SessionKit
import UniformTypeIdentifiers
import os

// MARK: - Controller

/// History window (SPEC §5; design/README "History window" + "Empty state",
/// designs 1d/2d): 760×470 titled window, 236 pt source-list sidebar — rows
/// show title (or "Untitled meeting"), derived meta (`fused | fusing |
/// failed`, SPEC §5 — derived at display time from the storage state plus the
/// last fusion outcome), date, and a "recovered" capsule (SPEC §4.4) — plus a
/// detail pane with a **Notes | Transcript** toggle, rendered markdown with
/// INLINE validator warning cards (SPEC §4.5 — the hallucination-audit
/// surface; the validator is re-run on display, deterministic and cheap) and
/// STATIC action-item checkbox glyphs (v0 stores no done-ness, SPEC §5).
/// With no fused note the Notes face falls back to the user's own scratchpad
/// fragments (see `scratchpadFallback`), so a failed session shows why it
/// failed AND what the user wrote, with Retry still live.
///
/// Actions (design 1d toolbar): **Export** markdown — notes + collapsible
/// `<details>` transcript (SPEC §4.6 export); **Retry Fusion** — enabled for
/// `processing` rows (SPEC §4.5 failure semantics); **Export Eval Case** —
/// enabled when a canonical note exists, optional corrected-output sheet,
/// SPEC §4.5 pinned JSON; **Delete** — confirmed, cascades through the store.
///
/// Data flow (SPEC §3.1): everything reads the store directly; coordinator
/// events (`stateChanged` / `fusionFindings` / `fusionFailed`) and a 1 s
/// timer (only while a "fusing" row exists) trigger reloads. **Do not
/// invest** (SPEC §5) — this window is deleted in Phase 3.
@MainActor
final class HistoryWindowController: NSObject {

    // Design metrics (design 1d/2d).
    private enum Metrics {
        static let windowSize = NSSize(width: 760, height: 470)
        static let minWindowSize = NSSize(width: 560, height: 340)
        static let sidebarWidth: CGFloat = 236
        static let rowHeight: CGFloat = 44
        /// Sidebar top inset: traffic lights (16 + 12 + 14, design 1d) plus
        /// the row list's own 2 pt top padding.
        static let sidebarTopInset: CGFloat = 44
        /// List-refresh cadence while a fusing row exists (spinner rows).
        static let fusingTick: TimeInterval = 1
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("sessionCell")
    /// Selection persistence (last selected session id) — cheap convenience.
    private static let selectedSessionDefaultsKey = "history.selectedSessionId"

    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "history")
    private let store: MeetingStore
    private let coordinator: SessionCoordinator

    private var window: NSWindow!
    private var splitViewController: NSSplitViewController!
    private let tableView = NSTableView()
    private let segmented = NSSegmentedControl(
        labels: ["Notes", "Transcript"], trackingMode: .selectOne, target: nil, action: nil
    )
    private var exportButton: NSButton!
    private var retryButton: NSButton!
    private var evalButton: NSButton!
    private var deleteButton: NSButton!
    private var contentTextView: NSTextView!
    /// Owns the TextKit 1 stack behind `contentTextView` (an `NSLayoutManager`
    /// holds its storage weakly).
    private var contentTextStorage: NSTextStorage!
    private var emptyStateView: NSView!
    /// Empty-state Start Meeting (design 2d) — the keyboard entry point when
    /// there is no table to focus.
    private var emptyStateStartButton: NSButton!

    // MARK: Start-flow permission guard (UX review finding 7)

    /// Fires INSTEAD of starting when microphone or Screen Recording TCC is
    /// missing — the same contract as `MenuBarController.onPermissionsMissing`
    /// so both Start affordances behave identically (design 3a J2).
    ///
    /// `ScribeApp` does not inject this today (it wires only the menu bar), so
    /// when it is `nil` the controller opens the setup wizard itself rather
    /// than leaving a dead button. Wiring it to the app's shared wizard is the
    /// preferred fix once `ScribeApp` can be edited.
    var onPermissionsMissing: (() -> Void)?

    /// Mirrors `MenuBarController.permissionGuardEnabled`: the stub capture
    /// engine needs no TCC, so the guard is off in that mode. Read from the
    /// same UserDefaults flag `ScribeApp` branches on, so the two surfaces
    /// agree without extra wiring.
    var permissionGuardEnabled = !UserDefaults.standard.bool(forKey: SettingsKeys.debugUseStubCapture)

    /// Wizard used only when `onPermissionsMissing` is unwired (see above).
    private var fallbackWizard: SetupWizardController?

    /// Sessions newest-first (store order).
    private var sessions: [SessionRecord] = []
    /// Session ids with a canonical note (drives `fused` meta for
    /// `processing` rows — findings keep notes stored, SPEC §4.5).
    private var notePresence: Set<UUID> = []
    /// Live fusion failures from `fusionFailed` events — the IMMEDIATE half
    /// of the failed row state (SPEC §5: `processing` + last error).
    ///
    /// The durable half is `SessionRecord.fusionErrorMessage` (schema v2);
    /// see `failureMessage(for:)`. This map used to be the ONLY half, which
    /// is why a failed session came back from a relaunch as a permanent
    /// "fusing" spinner with no reason attached.
    private var fusionFailures: [UUID: String] = [:]
    private var selectedSessionId: UUID?
    private var detail: SessionDetail?
    /// Suppresses re-renders (and validator re-runs) on the 1 s tick when
    /// nothing display-relevant changed.
    private var lastRenderKey: DetailKey?

    private var eventTask: Task<Void, Never>?
    private var fusingTimer: Timer?

    /// Whether the window is OPEN, tracked by the controller instead of asked
    /// of AppKit. `NSWindow.isVisible` is still `true` inside
    /// `windowWillClose(_:)`, so a teardown check written as `window.isVisible`
    /// there reads "still open" and tears nothing down: the 1 s fusing timer
    /// used to survive the close and keep querying SQLite behind a window that
    /// no longer exists (measured: it outlived the close and only stopped when
    /// its OWN next tick re-ran the check — one full store query pass per
    /// close, on a dead window, and nothing in the design guarantees that
    /// self-correction). Set on `show()`, cleared on `windowWillClose(_:)`.
    private var isWindowOpen = false

    /// True only while the window is open AND on screen (not closed, not
    /// miniaturized). Every "is this window live?" check goes through here.
    private var isWindowOnScreen: Bool {
        isWindowOpen && window.isVisible
    }

    init(store: MeetingStore, coordinator: SessionCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init()
        buildWindow()
        wire()
        subscribeToEvents()
    }

    // MARK: - Presentation

    /// Opens the window (menu History… path).
    func show() {
        isWindowOpen = true
        reload()
        NSApp.activate(ignoringOtherApps: true) // LSUIElement accessory app
        window.makeKeyAndOrderFront(nil)
        focusPrimaryResponder()
        syncFusingTimer()
    }

    /// Opens the window AT a session (menu-bar done-badge click, SPEC §5).
    func show(sessionId: UUID) {
        isWindowOpen = true
        reload(selecting: sessionId)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusPrimaryResponder()
        syncFusingTimer()
    }

    /// Puts keyboard focus where the window's navigation actually lives (UX
    /// review finding 14): the session list, or — with no sessions — the
    /// empty state's Start Meeting. Without this the window opened with the
    /// window itself as first responder and the arrow keys did nothing until
    /// the user clicked a row.
    private func focusPrimaryResponder() {
        let target: NSView = sessions.isEmpty ? emptyStateStartButton : tableView
        window.initialFirstResponder = target
        // NSButton only accepts first responder under Full Keyboard Access;
        // the table always does, so the common case always lands.
        window.makeFirstResponder(target)
    }

    // MARK: - Gallery test seams (dev tooling — App/UIGallery.swift)

    /// The window, for placement + `windowNumber` in the screenshot gallery.
    var galleryWindow: NSWindow { window }

    /// Puts the window in a fixed, screenshot-able state without a live
    /// session. Needed because two inputs of this surface are not reachable
    /// from the store as the gallery seeds it: the Notes|Transcript segment
    /// (a private control) and the LIVE `fusionFailures` map, fed by
    /// `.fusionFailed` coordinator events that a fixture store can never
    /// emit. (Failures are persisted too now — `failureMessage(for:)` — but
    /// the map keeps the fixture independent of the seeded rows.) Everything
    /// else — rows, meta, validator cards — still comes from the real
    /// `reload()` path.
    func galleryConfigure(select sessionId: UUID?, tab: Int, failed: [UUID: String]) {
        fusionFailures = failed
        segmented.selectedSegment = tab
        reload(selecting: sessionId)
    }

    // MARK: - Window assembly (design 1d)

    private func buildWindow() {
        // `HistoryWindow` only adds the ⌘1/⌘2 pane toggle (UX review finding
        // 14) — a key path AppKit cannot express as a control key equivalent.
        // Closing is plain `performClose:` from the app's Window menu (⌘W).
        let historyWindow = HistoryWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        historyWindow.onKeyEquivalent = { [weak self] event in
            self?.handleKeyEquivalent(event) ?? false
        }
        window = historyWindow
        // Design 1d: no title strip — the content runs full height and the
        // traffic lights float over the top of the sidebar.
        window.title = "History" // Window menu / accessibility only
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = Metrics.minWindowSize

        let split = NSSplitViewController()
        // A PLAIN item, not `sidebarWithViewController:`: on macOS 26 the
        // sidebar behavior wraps the item's view in a concentric-glass
        // container — an inset, rounded "card" around the list that design 1d
        // does not have, and which also steals row width. The source-list
        // material is drawn by our own NSVisualEffectView, full-bleed.
        let sidebarItem = NSSplitViewItem(viewController: sidebarViewController())
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = Metrics.sidebarWidth
        sidebarItem.maximumThickness = Metrics.sidebarWidth
        let detailItem = NSSplitViewItem(viewController: detailViewController())
        detailItem.minimumThickness = 320
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        split.splitView.dividerStyle = .thin // hairline right border (design 1d)
        splitViewController = split
        window.contentViewController = split
        window.setContentSize(Metrics.windowSize)
        window.center()

        // Empty state (design 2d) layered above the split view; reload()
        // swaps between the two faces (opaque background so the sidebar
        // material doesn't show through).
        emptyStateView = buildEmptyStateView()
        emptyStateView.isHidden = true
        split.view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: split.view.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
        ])

        // Keyboard traversal (UX review finding 14): an explicit key-view loop
        // so Tab under Full Keyboard Access walks list → pane toggle → the
        // four actions → back to the list, instead of AppKit's incidental
        // geometric order across two split-view children.
        window.initialFirstResponder = tableView
        tableView.nextKeyView = segmented
        segmented.nextKeyView = exportButton
        exportButton.nextKeyView = retryButton
        retryButton.nextKeyView = evalButton
        evalButton.nextKeyView = deleteButton
        deleteButton.nextKeyView = tableView
    }

    /// 236 pt source-list sidebar: sidebar material + plain view-based
    /// table (rows built in `SessionCellView`; selection drawn by
    /// `SidebarRowView`).
    private func sidebarViewController() -> NSViewController {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 200))

        let effect = NSVisualEffectView()
        effect.material = .sidebar // native source-list material ≈ design #F2F1EF
        // `.withinWindow`, not `.behindWindow`: sampling the desktop makes the
        // sidebar as light (or dark) as whatever happens to sit behind the
        // window, which flips design 1d's sidebar/detail relationship — over a
        // white background the sidebar rendered LIGHTER than the notes pane.
        // Sampling the window keeps the sidebar the recessed surface and the
        // detail pane the content surface in both appearances.
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)

        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2) // design row gap 2
        // `.plain`: inside an NSSplitViewItem sidebar the `.automatic` style
        // resolves to the source-list style, which (macOS 26) both insets the
        // rows — squeezing the 13 pt titles into an early ellipsis — and paints
        // a rounded "card" behind the list that design 1d does not have. The
        // row list's own padding comes from the scroll view's constraints.
        tableView.style = .plain
        tableView.backgroundColor = .clear
        // The focus ring stays ON (UX review finding 14): it is the only
        // indicator that tells a keyboard user the session list — the window's
        // primary navigation — currently has focus. `SidebarRowView` adds the
        // second signal by drawing the emphasized selection fill.
        tableView.focusRingType = .default
        // VoiceOver: the table is unlabeled otherwise ("table").
        tableView.setAccessibilityLabel("Sessions")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: Self.cellIdentifier))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        // Flat, full-bleed under the sidebar material (design 1d): every layer
        // of the scroll stack has to opt out of drawing, otherwise the clip
        // view fills its bounds with the control background.
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // Top inset clears the OS traffic lights (design 1d: 16/16/14 →
            // 12 pt circles at 16 from the top + 14 below); row list padding
            // is 2px 8px 12px.
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: Metrics.sidebarTopInset),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    /// Detail pane: toolbar (segmented Notes | Transcript + four actions,
    /// hairline bottom) over the content text view.
    private func detailViewController() -> NSViewController {
        // Content surface (design 1d: the notes pane is `#fff` beside the
        // `#F2F1EF` source-list sidebar) — `windowBackgroundColor` inverts that
        // contrast in light mode.
        let container = ContentBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        segmented.font = NSFont.systemFont(ofSize: 12) // design 1d: 12 pt segments
        segmented.selectedSegment = 0
        segmented.setAccessibilityLabel("View")
        segmented.toolTip = "Notes (⌘1) or Transcript (⌘2)" // discoverability for the key path

        exportButton = makeToolbarButton(
            "Export", action: #selector(exportTapped), key: "e", help: "Export notes and transcript as Markdown"
        )
        retryButton = makeToolbarButton(
            "Retry Fusion", action: #selector(retryTapped), key: "r", help: "Run fusion again for this session"
        )
        evalButton = makeToolbarButton(
            "Export Eval Case", action: #selector(exportEvalTapped),
            key: "E", modifiers: [.command, .shift], help: "Export this session as an eval case"
        )
        deleteButton = makeToolbarButton(
            "Delete", action: #selector(deleteTapped), red: true,
            key: "\u{8}", help: "Delete this session (asks first)"
        )

        let toolbar = NSStackView(views: [
            segmented, toolbarSpacer(), exportButton, retryButton, evalButton, deleteButton,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 10 // design 1d toolbar gap
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)

        let hairline = HairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hairline)

        // Explicit TextKit 1 stack: the inline validator cards (design 1d)
        // are drawn from line-fragment geometry, which needs NSLayoutManager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let textContainer = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        layout.addTextContainer(textContainer)
        contentTextStorage = storage
        contentTextView = NotesTextView(frame: .zero, textContainer: textContainer)
        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.isRichText = false
        contentTextView.drawsBackground = false
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.minSize = .zero
        contentTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        contentTextView.autoresizingMask = [.width]
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.textContainer?.lineFragmentPadding = 0
        contentTextView.textContainerInset = NSSize(width: 24, height: 20) // padding 20/24/26 (design 1d)

        let scroll = NSScrollView()
        scroll.documentView = contentTextView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            hairline.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            scroll.topAnchor.constraint(equalTo: hairline.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let controller = NSViewController()
        controller.view = container
        return controller
    }

    /// Greedy spacer between the segmented control and the action buttons.
    private func toolbarSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return spacer
    }

    /// Bordered 12 pt toolbar button (design 1d: radius 6, 0.5 pt border);
    /// Delete variant renders its title in the failure red #E0483E.
    ///
    /// `key` gives the action a ⌘ equivalent (UX review finding 14): without
    /// one these four buttons were reachable only with Full Keyboard Access
    /// turned on. The equivalent is echoed in the tooltip because nothing else
    /// in this window advertises it, and it fires only while the button is
    /// enabled — `NSButton.performKeyEquivalent` checks `isEnabled` itself, so
    /// the `updateActions` enablement rules cover the keyboard path too.
    private func makeToolbarButton(
        _ title: String,
        action: Selector,
        red: Bool = false,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command],
        help: String
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.font = NSFont.systemFont(ofSize: 12)
        if red {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: HistoryMeta.failureColor,
            ])
        }
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = modifiers
        button.toolTip = "\(help) (\(Self.shortcutLabel(key: key, modifiers: modifiers)))"
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.isEnabled = false // enabled by selection state (updateActions)
        return button
    }

    /// "⌘E" / "⇧⌘E" / "⌘⌫" — the tooltip's shortcut suffix.
    private static func shortcutLabel(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        switch key {
        case "\u{8}", "\u{7f}": return label + "⌫"
        default: return label + key.uppercased()
        }
    }

    /// Empty state (design 2d): centered gray waveform + "No sessions yet" +
    /// caption + bordered Start Meeting button.
    private func buildEmptyStateView() -> NSView {
        // Opaque backdrop so the sidebar material doesn't show through; drawn
        // (not a CALayer color) so it follows appearance changes.
        let view = BackdropView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(image: HistoryGlyphs.emptyWaveform)
        // Decorative (the title beneath says it): keep it out of the AX tree
        // rather than let VoiceOver announce a bare "image". The cell carries
        // the image view's accessibility in AppKit, so both are silenced.
        glyph.setAccessibilityElement(false)
        glyph.cell?.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "No sessions yet")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = NSColor.labelColor.withAlphaComponent(0.65) // ≈5.9:1 — passes AA

        let caption = NSTextField(wrappingLabelWithString:
            "Start a meeting from the menu bar. Notes land here when fusion finishes.")
        caption.font = NSFont.systemFont(ofSize: 12)
        // Design 2d asks for black 40%, which is ≈2.8:1 on white — a WCAG AA
        // failure (UX review finding 20). `secondaryLabelColor` is the native
        // caption color the rest of this window already uses (≈4.6:1), and
        // design/README's "always prefer the native system equivalent" makes
        // that the correction rather than a deviation.
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let start = NSButton(title: "Start Meeting", target: self, action: #selector(startMeetingTapped))
        start.bezelStyle = .rounded // bordered native push button (design 2d)
        start.controlSize = .regular
        start.setAccessibilityHelp("Starts a meeting and begins recording")
        emptyStateStartButton = start

        let stack = NSStackView(views: [glyph, title, caption, start])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -8),
        ])
        return view
    }

    private func wire() {
        segmented.target = self
        segmented.action = #selector(modeChanged)
        window.delegate = self
    }

    // MARK: - Data

    /// Why the last fusion attempt failed, or `nil` if it did not.
    ///
    /// Two sources, in priority order: the live `fusionFailed` event for this
    /// launch (immediate — it lands before the coordinator's store write is
    /// visible to a reload already in flight), then the persisted column
    /// (schema v2), which is what a session that failed in an EARLIER launch
    /// has. Both are cleared by Retry, and the coordinator clears the column
    /// whenever an attempt stores a note, so a value here always means "the
    /// most recent attempt failed".
    private func failureMessage(for session: SessionRecord) -> String? {
        fusionFailures[session.id] ?? session.fusionErrorMessage
    }

    private func rowState(_ session: SessionRecord) -> HistoryRow.State {
        HistoryRow.state(
            storage: session.state,
            failureMessage: failureMessage(for: session),
            hasStoredNote: notePresence.contains(session.id)
        )
    }

    /// Reloads the list (and, when its inputs changed, the detail). Selection
    /// follows `requested` → current → persisted → first row.
    private func reload(selecting requested: UUID? = nil) {
        let previous = requested ?? selectedSessionId
        sessions = (try? store.allSessions()) ?? []
        notePresence = Set(sessions.compactMap { session -> UUID? in
            guard session.state != .recording else { return nil }
            let note = (try? store.canonicalNote(sessionId: session.id)) ?? nil
            return note != nil ? session.id : nil
        })

        tableView.reloadData()

        let target: UUID?
        if let previous, sessions.contains(where: { $0.id == previous }) {
            target = previous
        } else if let persisted = UserDefaults.standard
            .string(forKey: Self.selectedSessionDefaultsKey)
            .flatMap(UUID.init(uuidString:)),
            sessions.contains(where: { $0.id == persisted }) {
            target = persisted
        } else {
            target = sessions.first?.id
        }
        selectedSessionId = target
        if let target {
            UserDefaults.standard.set(target.uuidString, forKey: Self.selectedSessionDefaultsKey)
            if let row = sessions.firstIndex(where: { $0.id == target }) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        emptyStateView.isHidden = !sessions.isEmpty // design 2d face swap
        let preparing = coordinator.displayState == .preparing
        emptyStateStartButton.title = preparing ? "Preparing speech model…" : "Start Meeting"
        emptyStateStartButton.isEnabled = !preparing
        refreshDetailIfNeeded()
        updateActions()
        syncFusingTimer()
    }

    /// Re-reads + re-renders the detail only when something display-relevant
    /// changed (guards the 1 s fusing tick from re-running the validator).
    private func refreshDetailIfNeeded() {
        let key = currentDetailKey()
        guard key != lastRenderKey else { return }
        lastRenderKey = key

        guard let key,
              let session = sessions.first(where: { $0.id == key.id }) else {
            detail = nil
            contentTextView.textStorage?.setAttributedString(emptySelectionText())
            return
        }
        let note = (try? store.canonicalNote(sessionId: session.id)) ?? nil
        let segments = (try? store.segments(sessionId: session.id)) ?? []
        let fragments = (try? store.fragments(sessionId: session.id)) ?? []
        detail = SessionDetail(
            session: session, note: note, segments: segments, fragments: fragments
        )
        renderDetail()
    }

    /// Cheap identity of everything the detail rendering depends on.
    private func currentDetailKey() -> DetailKey? {
        guard let id = selectedSessionId,
              let session = sessions.first(where: { $0.id == id }) else { return nil }
        let note = (try? store.canonicalNote(sessionId: id)) ?? nil
        let segmentCount = (try? store.segmentCount(sessionId: id)) ?? 0
        let fragmentCount = (try? store.fragments(sessionId: id).count) ?? 0
        return DetailKey(
            id: id,
            state: session.state,
            title: session.title,
            endedAt: session.endedAt,
            noteCreatedAt: note?.createdAt,
            segmentCount: segmentCount,
            fragmentCount: fragmentCount,
            // A failure does not move `state` (it stays `processing`, SPEC
            // §4.5), so without this the pane kept showing "Fusing…" after
            // the failure landed — the key was unchanged and the render was
            // skipped. Covers the clear on Retry too.
            failure: failureMessage(for: session),
            mode: segmented.selectedSegment
        )
    }

    // MARK: - Detail rendering

    private func renderDetail() {
        guard let detail else { return }
        let isNotes = segmented.selectedSegment == 0
        let attributed = isNotes ? renderNotes(detail) : renderTranscript(detail)
        contentTextView.textStorage?.setAttributedString(attributed)
        contentTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        // VoiceOver: which face of the pane is showing (the segmented control
        // is a separate element and is not read with the text).
        contentTextView.setAccessibilityLabel(
            isNotes ? "Notes for \(detail.displayTitle)" : "Transcript for \(detail.displayTitle)"
        )
    }

    /// Notes face (design 1d): 17 pt semibold title, meta line
    /// ("Today, 9:00–9:42 AM · fused from 3 fragments"), inline validator
    /// warning cards, rendered note markdown with static checkbox glyphs.
    private func renderNotes(_ detail: SessionDetail) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 3 // meta line margin-top (design 1d)
        out.append(NSAttributedString(string: detail.displayTitle + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: titleParagraph,
        ]))

        let metaParagraph = NSMutableParagraphStyle()
        metaParagraph.paragraphSpacing = 14 // meta line margin-bottom (design 1d)
        out.append(NSAttributedString(string: metaLine(detail) + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: metaParagraph,
        ]))

        if let note = detail.note {
            // SPEC §4.5 validator: re-run on display — deterministic, no
            // model calls, no stored findings needed.
            let findings = NotesValidator.validate(markdown: note.markdown, segments: detail.segments)
            let body = NSMutableAttributedString(
                attributedString: MarkdownMiniRenderer.render(note.markdown, checkbox: HistoryGlyphs.checkbox)
            )
            if !findings.isEmpty {
                // Design 1d: the card sits INSIDE the notes flow, after the
                // summary body and before the next section label.
                let cards = NSMutableAttributedString()
                for finding in findings { cards.append(validatorCard(finding)) }
                body.insert(cards, at: MarkdownMiniRenderer.endOfFirstSection(in: body))
            }
            out.append(body)
        } else {
            out.append(statusLine(for: detail))
            // With no fused note this pane used to end at the status line,
            // and the user's OWN typed fragments were displayed nowhere in
            // the app — the Transcript face renders audio segments only. A
            // meeting's worth of deliberate jotting could vanish behind a
            // missing API key, which breaks the scratchpad's whole promise
            // that typing is safe. They are shown verbatim, under their own
            // heading, so they never read as model output; once fusion
            // succeeds they are woven into the note and this block is gone.
            out.append(scratchpadFallback(detail))
        }
        return out
    }

    /// The user's raw scratchpad fragments (SPEC §4.3), shown only when no
    /// canonical note exists — see the call site. Anchor offsets are the
    /// session-clock values the fragments were typed at, rendered with the
    /// same formatter the transcript uses (FusionKit canonical rendering) so
    /// the two faces line up.
    private func scratchpadFallback(_ detail: SessionDetail) -> NSAttributedString {
        guard !detail.fragments.isEmpty else { return NSAttributedString() }

        let out = NSMutableAttributedString()

        let labelParagraph = NSMutableParagraphStyle()
        labelParagraph.paragraphSpacingBefore = 16 // design 1d section-label margin
        out.append(NSAttributedString(string: "YOUR NOTES\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6, // design 1d: .05em tracking on section labels
            .paragraphStyle: labelParagraph,
        ]))

        let captionParagraph = NSMutableParagraphStyle()
        captionParagraph.paragraphSpacing = 8
        out.append(NSAttributedString(
            string: "Typed by you during the meeting — shown as written, not fused.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: captionParagraph,
            ]
        ))

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineHeightMultiple = 1.45
        bodyParagraph.paragraphSpacing = 3
        bodyParagraph.headIndent = 52 // wrapped lines clear the timestamp column
        let stamp: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: bodyParagraph,
        ]
        let text: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: bodyParagraph,
        ]
        // Store order is anchor-ascending (SPEC §4.3), i.e. the order typed.
        for fragment in detail.fragments {
            out.append(NSAttributedString(
                string: CanonicalRendering.timestamp(fragment.anchorOffset) + "  ", attributes: stamp
            ))
            out.append(NSAttributedString(
                string: fragment.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
                attributes: text
            ))
        }
        return out
    }

    /// Meta line under the title (design 1d).
    private func metaLine(_ detail: SessionDetail) -> String {
        var text = HistoryMeta.timeRange(start: detail.session.startedAt, end: detail.session.endedAt)
        let count = detail.fragments.count
        let fragmentText = "fused from \(count) fragment\(count == 1 ? "" : "s")"
        switch detail.session.state {
        case .recording:
            text += " · recording in progress"
        case .complete:
            text += " · \(fragmentText)"
        case .processing:
            if detail.note != nil {
                text += " · \(fragmentText)" // note stored; findings keep Retry (SPEC §4.5)
            } else if failureMessage(for: detail.session) != nil {
                text += " · fusion failed"
            } else {
                text += " · fusing…"
            }
        }
        return text
    }

    /// Inline validator warning card (SPEC §4.5; design 1d): a real block
    /// card — systemYellow 12% fill, radius 7, 0.5 pt border, warning glyph
    /// top-left, 12 pt text at 1.5 line-height, 10 pt above.
    ///
    /// The card is ONE paragraph carrying `ValidatorCard.attribute`; the
    /// rounded fill + border are drawn behind it by `NotesTextView` from the
    /// paragraph's line-fragment geometry, so it tracks the pane's real width
    /// on resize and resolves its colors per appearance. The paragraph
    /// indents supply the card's inner padding.
    private func validatorCard(_ finding: NotesValidator.Finding) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = ValidatorCard.marginTop + ValidatorCard.paddingY
        paragraph.paragraphSpacing = ValidatorCard.paddingY
        paragraph.firstLineHeadIndent = ValidatorCard.paddingX
        paragraph.headIndent = ValidatorCard.paddingX + ValidatorCard.glyphSize.width + ValidatorCard.glyphGap
        paragraph.tailIndent = -ValidatorCard.paddingX
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.25 // design 12 pt / 1.5

        let font = NSFont.systemFont(ofSize: 12)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor, // design black 65%
            .paragraphStyle: paragraph,
        ]

        let card = NSMutableAttributedString()
        let glyph = NSTextAttachment()
        glyph.image = HistoryGlyphs.validatorWarning
        glyph.bounds = CGRect(
            x: 0, y: font.descender - 1,
            width: ValidatorCard.glyphSize.width, height: ValidatorCard.glyphSize.height
        )
        card.append(NSAttributedString(attachment: glyph))
        card.append(NSAttributedString(string: "  ", attributes: base))
        var prefix = base
        prefix[.font] = NSFont.systemFont(ofSize: 12, weight: .semibold)
        prefix[.foregroundColor] = NSColor.labelColor // design black 75%
        card.append(NSAttributedString(string: "Validator: ", attributes: prefix))
        card.append(NSAttributedString(string: finding.detail + "\n", attributes: base))
        card.addAttributes(
            [.paragraphStyle: paragraph, ValidatorCard.attribute: true],
            range: NSRange(location: 0, length: card.length)
        )
        return card
    }

    /// No-note status line (fusing / failed / recording).
    private func statusLine(for detail: SessionDetail) -> NSAttributedString {
        let text: String
        switch detail.session.state {
        case .recording:
            text = "Meeting in progress — notes appear here after fusion."
        case .processing:
            if let message = failureMessage(for: detail.session) {
                text = "Fusion failed: \(message) Use Retry Fusion to try again."
            } else {
                text = "Fusing transcript and fragments — notes will appear here shortly."
            }
        case .complete:
            text = "No fused notes were stored for this session."
        }
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .obliqueness: 0.15,
        ])
    }

    /// Transcript face (design 1d toggle): monospaced 12 pt canonical
    /// rendering (FusionKit — the same formatter the model cites into).
    private func renderTranscript(_ detail: SessionDetail) -> NSAttributedString {
        let rendered = CanonicalRendering.renderTranscript(detail.segments)
        let text = rendered.isEmpty ? "No transcript segments were persisted." : rendered
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = 2
        return NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    private func emptySelectionText() -> NSAttributedString {
        NSAttributedString(string: "Select a session.\n", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    /// Toolbar enablement: Export/Delete need a selection; Retry Fusion only
    /// for `processing` (SPEC §4.5); Export Eval Case needs a canonical note.
    private func updateActions() {
        let hasSelection = selectedSessionId != nil && detail != nil
        exportButton.isEnabled = hasSelection
        retryButton.isEnabled = hasSelection && detail?.session.state == .processing
        evalButton.isEnabled = hasSelection && detail?.note != nil
        deleteButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    /// Export markdown (SPEC §4.6): notes + collapsible transcript. Format:
    /// the note markdown verbatim, `---`, then
    /// `<details><summary>Transcript</summary>` + a ```text fence + the
    /// canonical transcript rendering + `</details>`. (Transcript lines are
    /// `[MM:SS] Me: text` — they never contain backtick fences.)
    @objc private func exportTapped() {
        guard let detail else { return }
        var markdown = detail.note?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if markdown.isEmpty {
            markdown = "# \(detail.displayTitle)\n\nNo fused notes yet."
        }
        let transcript = CanonicalRendering.renderTranscript(detail.segments)
        let transcriptBlock = transcript.isEmpty
            ? "_No transcript segments were persisted._"
            : "```text\n\(transcript)\n```"
        let contents = """
            \(markdown)

            ---

            <details>
            <summary>Transcript</summary>

            \(transcriptBlock)

            </details>
            """
        savePanel(
            defaultName: Self.fileName(for: detail.displayTitle, extension: "md"),
            type: UTType(filenameExtension: "md") ?? .plainText,
            data: Data(contents.utf8)
        )
    }

    /// Retry Fusion (SPEC §4.5): re-runs fusion on the selected `processing`
    /// session; the row flips back to "fusing" immediately.
    @objc private func retryTapped() {
        guard let session = detail?.session, session.state == .processing else { return }
        // Both halves of the failure state (see `failureMessage(for:)`). The
        // stored one is cleared here as well as by the coordinator so the row
        // flips to "fusing" on THIS reload, rather than a beat later when the
        // async retry gets going.
        fusionFailures[session.id] = nil
        try? store.clearFusionFailure(sessionId: session.id)
        Task { await coordinator.retryFusion(for: session) }
        reload()
    }

    /// Export Eval Case (SPEC §4.5): corrected-output sheet (optional) →
    /// `EvalCase.build` (pinned schema v1) → pretty-printed JSON → save panel.
    @objc private func exportEvalTapped() {
        guard let detail, detail.note != nil else { return }
        presentEvalSheet(for: detail)
    }

    /// Delete: confirm → `store.deleteSession` (cascades segments, fragments,
    /// notes) → reload.
    @objc private func deleteTapped() {
        guard let session = detail?.session else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(session.title ?? HistoryMeta.fallbackTitle(session))”?"
        alert.informativeText = "The transcript, fragments, and notes are deleted permanently. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try self.store.deleteSession(id: session.id)
                self.fusionFailures[session.id] = nil
                if self.selectedSessionId == session.id { self.selectedSessionId = nil }
                self.reload()
            } catch {
                self.presentError("Couldn't delete the session", error)
            }
        }
    }

    /// Empty-state Start Meeting (design 2d), guarded exactly like the menu's
    /// Start (UX review finding 7).
    ///
    /// This used to call `coordinator.start()` straight through and log the
    /// throw: with microphone or Screen Recording TCC missing the button did
    /// nothing at all, with no feedback — a dead control on the one surface a
    /// user with no sessions ever sees. Now missing permissions open the setup
    /// wizard at the missing step (same as `MenuBarController.toggleMeeting`),
    /// and a genuine engine failure is surfaced as a sheet, never log-only.
    @objc private func startMeetingTapped() {
        // T8 start guard: a start without TCC throws (mic) or silently
        // degrades to mic-only (screen) — route to the wizard instead.
        if permissionGuardEnabled,
           CapturePermissions.microphone != .granted
            || CapturePermissions.screenRecording == .denied {
            presentPermissionSetup()
            return
        }
        Task { @MainActor in
            do {
                try await coordinator.start()
                reload() // the new session row replaces the empty state
            } catch {
                presentError("Couldn't start the meeting", error)
            }
        }
    }

    /// Hands a missing-permission start to the host, or — unwired — opens the
    /// wizard directly, so the button always does something visible.
    private func presentPermissionSetup() {
        if let onPermissionsMissing {
            onPermissionsMissing()
            return
        }
        guard let step = SetupWizardPhase.firstMissingPermission else {
            logger.error("Permission guard fired with no missing permission — start not attempted.")
            return
        }
        if fallbackWizard == nil { fallbackWizard = SetupWizardController() }
        fallbackWizard?.show(at: step)
    }

    @objc private func modeChanged() {
        refreshDetailIfNeeded() // mode is part of the render key
    }

    /// ⌘1 / ⌘2 — the Notes ⇄ Transcript toggle's key path (UX review finding
    /// 14; design 3a J3's `⟲ Notes ⇄ Transcript` is otherwise mouse-only).
    /// Everything else in this window is a control key equivalent or a main
    /// menu item, so nothing else is intercepted here.
    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              window.attachedSheet == nil else { return false }
        switch event.charactersIgnoringModifiers {
        case "1": selectMode(0)
        case "2": selectMode(1)
        default: return false
        }
        return true
    }

    private func selectMode(_ index: Int) {
        guard segmented.selectedSegment != index else { return }
        segmented.selectedSegment = index
        modeChanged()
    }

    // MARK: - Eval-case sheet (SPEC §4.5 collection path)

    private var evalSheet: NSWindow?
    private var evalTextView: NSTextView?

    /// Optional corrected-output prompt: text field + Save/Cancel, then the
    /// JSON save panel.
    private func presentEvalSheet(for detail: SessionDetail) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let label = NSTextField(wrappingLabelWithString:
            "Optional: paste corrected notes for this case. Leave empty to export the fusion output as-is (SPEC §4.5 eval set).")
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let textView = NSTextView(frame: .zero)
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.borderType = .bezelBorder
        textScroll.hasVerticalScroller = true
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Save", target: self, action: #selector(evalSaveTapped))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(evalCancelTapped))
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [save, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [label, textScroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheet.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: sheet.contentView!.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: sheet.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: sheet.contentView!.trailingAnchor, constant: -16),
            textScroll.heightAnchor.constraint(equalToConstant: 120),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        ])

        evalSheet = sheet
        evalTextView = textView
        window.beginSheet(sheet) { [weak self] response in
            guard let self, response == .OK else { return }
            let corrected = self.evalTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            self.exportEvalCase(for: detail, corrected: (corrected?.isEmpty == false) ? corrected : nil)
        }
        sheet.makeFirstResponder(textView)
    }

    @objc private func evalSaveTapped() {
        guard let sheet = evalSheet else { return }
        window.endSheet(sheet, returnCode: .OK)
    }

    @objc private func evalCancelTapped() {
        guard let sheet = evalSheet else { return }
        window.endSheet(sheet, returnCode: .cancel)
    }

    private func exportEvalCase(for detail: SessionDetail, corrected: String?) {
        guard let note = detail.note else { return }
        let findings = NotesValidator.validate(markdown: note.markdown, segments: detail.segments)
        let evalCase = EvalCase.build(
            session: detail.session,
            segments: detail.segments,
            fragments: detail.fragments,
            note: note,
            validatorFindings: findings,
            correctedOutput: corrected
        )
        do {
            // Pinned SPEC §4.5 schema: ISO-8601 dates, sorted keys, pretty.
            let data = try evalCase.encodedJSON()
            savePanel(
                defaultName: Self.fileName(for: "eval \(detail.displayTitle)", extension: "json"),
                type: .json,
                data: data
            )
        } catch {
            presentError("Couldn't encode the eval case", error)
        }
    }

    // MARK: - Panels & errors

    /// Save panel as a WINDOW-modal sheet (UX review finding 22).
    ///
    /// `runModal()` is app-modal: it froze the status item — the app's
    /// persistent root — for as long as the panel was open, which design 3b's
    /// "No modal states anywhere" forbids. A sheet on the History window keeps
    /// the menu bar (and Stop) live.
    ///
    /// Presented on the next run-loop pass because the eval-case path calls
    /// this from `beginSheet`'s completion handler, and AppKit refuses a
    /// second sheet while the first is still being torn down.
    private func savePanel(defaultName: String, type: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            panel.beginSheetModal(for: self.window) { [weak self] response in
                guard let self, response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self.logger.info("Exported \(url.lastPathComponent, privacy: .public)")
                } catch {
                    self.presentError("Couldn't save \(url.lastPathComponent)", error)
                }
            }
        }
    }

    /// Filesystem-safe export name (≤60 chars before the extension).
    static func fileName(for title: String, extension ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = title.components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Session" : String(cleaned.prefix(60))
        return "\(base).\(ext)"
    }

    /// Window-modal error sheet (never log-only — UX review finding 7).
    /// Deferred one run-loop pass for the same reason `savePanel` is: the
    /// callers are sheet completion handlers.
    private func presentError(_ message: String, _ error: Error) {
        logger.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: self.window)
        }
    }

    // MARK: - Events & timers

    private func subscribeToEvents() {
        // NOTE: init-time `.recoveredSessions` is replayed only to the FIRST
        // subscriber (the menu bar, subscribed at app launch); recovered
        // sessions still appear here because reload() reads the store —
        // the store remains the source of truth (SPEC §3.1).
        eventTask = Task { [weak self, coordinator] in
            for await event in coordinator.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: CoordinatorEvent) {
        switch event {
        case .stateChanged, .fusionFindings:
            if isWindowOnScreen { reload() }
        case .fusionFailed(let sessionId, let message):
            fusionFailures[sessionId] = message
            if isWindowOnScreen { reload() }
        case .recoveredSessions:
            if isWindowOnScreen { reload() }
        case .deviceEventLogged, .transcriptDrainTimedOut:
            break // logged by ScribeApp; the session row itself is unaffected
        }
    }

    /// 1 s list refresh while a "fusing" row exists (spec'd data path for
    /// fusing rows; stopped when the window is closed or none remain).
    ///
    /// The liveness test is `isWindowOnScreen`, NOT `window.isVisible`: this
    /// is called from `windowWillClose(_:)`, where AppKit still reports the
    /// window as visible.
    private func syncFusingTimer() {
        let needsTimer = isWindowOnScreen && sessions.contains { rowState($0) == .fusing }
        if needsTimer, fusingTimer == nil {
            let timer = Timer(timeInterval: Metrics.fusingTick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reload()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            fusingTimer = timer
        } else if !needsTimer, let timer = fusingTimer {
            timer.invalidate()
            fusingTimer = nil
        }
    }
}

// MARK: - NSTableView data & delegate

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView() // radius-6 neutral selection fill (design 1d)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        // makeView reuses identifier-matched views when available (small
        // lists; per-reload allocation at 1 Hz while fusing is fine — SPEC §5
        // "do not invest").
        let cell = (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? SessionCellView)
            ?? SessionCellView()
        cell.identifier = Self.cellIdentifier

        let state = rowState(session)
        cell.configure(
            title: HistoryRow.title(session),
            dateText: HistoryMeta.dateAndTime(session.startedAt),
            meta: HistoryRow.meta(for: state, duration: durationText(session)),
            // design: #E0483E, dark-mode aware (see HistoryMeta.failureColor).
            metaColor: state == .failed ? HistoryMeta.failureColor : .secondaryLabelColor,
            isFusing: state == .fusing,
            isRecovered: session.recovered
        )
        return cell
    }

    private func durationText(_ session: SessionRecord) -> String? {
        // Wall-clock duration (SPEC §4.1); recovered sessions keep a nil
        // endedAt on purpose — an invented end would lie (SPEC §4.4).
        guard let ended = session.endedAt else { return nil }
        return HistoryMeta.duration(ended.timeIntervalSince(session.startedAt))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if sessions.indices.contains(row) {
            selectedSessionId = sessions[row].id
            UserDefaults.standard.set(sessions[row].id.uuidString, forKey: Self.selectedSessionDefaultsKey)
        } else if !sessions.isEmpty {
            selectedSessionId = nil // clicked below the rows
        }
        refreshDetailIfNeeded()
        updateActions()
    }
}

// MARK: - NSWindowDelegate

extension HistoryWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Order matters: the window is still `isVisible` here, so the flag
        // must drop BEFORE the sync or the timer survives the close.
        isWindowOpen = false
        syncFusingTimer() // stops the fusing tick while closed
    }

    /// Miniaturizing clears `isVisible`; the timer is only re-armed when the
    /// window comes back, so the tick does not run behind the Dock icon.
    func windowDidMiniaturize(_ notification: Notification) {
        syncFusingTimer()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        reload() // re-reads the store and re-arms the tick if a row is fusing
    }
}

// MARK: - Value types

/// Everything the detail pane needs for one session, read once per change.
private struct SessionDetail {
    let session: SessionRecord
    let note: NoteRecord?
    let segments: [SegmentRecord]
    let fragments: [FragmentRecord]

    /// SPEC §4.5: untitled (pre-fusion) sessions display date/duration.
    var displayTitle: String {
        if let title = session.title, !title.isEmpty { return title }
        return HistoryMeta.fallbackTitle(session)
    }
}

/// Identity of the detail render inputs (guards the 1 s tick).
private struct DetailKey: Equatable {
    let id: UUID
    let state: SessionState
    let title: String?
    let endedAt: Date?
    let noteCreatedAt: Date?
    let segmentCount: Int
    let fragmentCount: Int
    let failure: String?
    let mode: Int
}

// MARK: - Window

/// History window. Adds ONE thing to `NSWindow`: the ⌘1 / ⌘2 pane toggle
/// (UX review finding 14). `NSSegmentedControl` has no per-segment modifier
/// mask, so the toggle cannot be expressed as a control key equivalent, and it
/// does not belong in the app's main menu (it is meaningful only here).
///
/// Closing is deliberately NOT overridden: ⌘W comes from the app's Window
/// menu → `performClose:`, which this window services normally (`.closable`,
/// `isReleasedWhenClosed = false`, `windowWillClose` clears `isWindowOpen`
/// and stops the fusing timer).
private final class HistoryWindow: NSWindow {
    /// Returns true when the controller consumed the event.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Sidebar rows

/// Selection fill for sidebar rows (design 1d: radius 6, neutral — black 7%
/// on light). `unemphasizedSelectedContentBackgroundColor` is the native
/// source-list equivalent and is the only one that stays a *highlight* in
/// dark mode; it resolves here because selection is drawn, not layered.
///
/// `isEmphasized` (window is key AND the table is first responder) adds an
/// accent-colored outline around that same fill — the second half of the focus
/// indicator restored for UX review finding 14, so arrow-key navigation is
/// visibly *live* rather than merely remembered. An outline rather than
/// AppKit's accent FILL on purpose: the row's labels are custom (not the
/// cell's `textField`), so they never flip to white and dark-on-accent would
/// trade one contrast failure for another.
private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        shape.fill()
        guard isEmphasized else { return }
        NSColor.controlAccentColor.setStroke()
        shape.lineWidth = 2
        shape.stroke()
    }
}

// MARK: - Appearance-following primitives
//
// CALayer colors do NOT re-resolve when the effective appearance changes, so
// every tinted surface in this window draws itself instead.

/// 0.5 pt `separatorColor` hairline (design 1d toolbar/sidebar borders).
private final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}

/// Opaque content-surface backdrop for the detail pane (design 1d: `#fff`).
/// `textBackgroundColor` is the semantic content surface — white in light,
/// near-black in dark — which puts the notes pane on the light side of the
/// sidebar material in Aqua and the dark side in Dark Aqua.
private final class ContentBackdropView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Opaque window-background backdrop (design 2d empty state).
private final class BackdropView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// `recovered` tag capsule (design 1d): systemYellow 22% fill, radius 4.
private final class TagCapsuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - Validator card (design 1d)

/// Geometry + the marker attribute for the inline validator warning card.
private enum ValidatorCard {
    /// Marks the card paragraph so `NotesTextView` can draw its block.
    static let attribute = NSAttributedString.Key("scribe.history.validatorCard")
    static let marginTop: CGFloat = 10
    static let paddingX: CGFloat = 10
    static let paddingY: CGFloat = 8
    static let cornerRadius: CGFloat = 7
    static let glyphSize = NSSize(width: 13, height: 12)
    static let glyphGap: CGFloat = 8
}

/// Notes pane text view. Draws the validator warning cards (design 1d) as
/// real rounded blocks behind their paragraphs, sized from the live line
/// fragments so they follow the pane's actual width.
private final class NotesTextView: NSTextView {

    override func draw(_ dirtyRect: NSRect) {
        drawValidatorCards()
        super.draw(dirtyRect)
    }

    private func drawValidatorCards() {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        let origin = textContainerOrigin
        let inset = container.lineFragmentPadding
        let width = container.size.width - inset * 2
        guard width > 0 else { return }

        storage.enumerateAttribute(
            ValidatorCard.attribute,
            in: NSRange(location: 0, length: storage.length),
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var used = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, _ in
                used = used.union(usedRect)
            }
            guard !used.isNull, !used.isEmpty else { return }

            let card = NSRect(
                x: origin.x + inset,
                y: origin.y + used.minY - ValidatorCard.paddingY,
                width: width,
                height: used.height + ValidatorCard.paddingY * 2
            )
            let path = NSBezierPath(
                roundedRect: card.insetBy(dx: 0.25, dy: 0.25),
                xRadius: ValidatorCard.cornerRadius,
                yRadius: ValidatorCard.cornerRadius
            )
            NSColor.systemYellow.withAlphaComponent(0.12).setFill() // design rgba(255,204,0,.12)
            path.fill()
            NSColor.systemYellow.withAlphaComponent(0.35).setStroke() // design rgba(178,134,0,.25)
            path.lineWidth = 0.5
            path.stroke()
        }
    }
}

/// One sidebar row (design 1d): title 13 pt medium truncating + right meta
/// 11 pt ("42 min" | spinner + "fusing" | "failed" red; "recovered" yellow
/// capsule), second line date 11 pt.
private final class SessionCellView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let capsule = TagCapsuleView()
    private let capsuleLabel = NSTextField(labelWithString: "recovered")
    private let spinner = NSProgressIndicator()
    private let metaStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor // design #1D1D1F
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.cell?.wraps = false
        // The title takes whatever the meta column leaves and truncates only
        // then (design: meta never truncates, titles rarely do — the 236 pt
        // sidebar fits "Design crit — panels" beside a fusing spinner).
        titleLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dateLabel.font = NSFont.systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor // design black 45%

        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor

        // "recovered" capsule (design 1d): 9 pt medium, systemYellow 22% fill,
        // #8A6A00 text (lightened in dark mode), radius 4 — drawn, not
        // layered, so it survives an appearance change.
        capsule.isHidden = true
        capsule.setAccessibilityElement(false) // decorative fill; the label inside reads "recovered"
        capsuleLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        capsuleLabel.textColor = HistoryMeta.capsuleTextColor
        capsuleLabel.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(capsuleLabel)
        NSLayoutConstraint.activate([
            capsuleLabel.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 1.5),
            capsuleLabel.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -1.5),
            capsuleLabel.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 5),
            capsuleLabel.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -5),
        ])

        // 10 pt spinner beside "fusing" (design 1d: 9 pt ring).
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        // VoiceOver: an unlabeled progress indicator otherwise (finding 19).
        // The adjacent "fusing" label still carries the state visually.
        spinner.setAccessibilityLabel("Fusing")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 10).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 10).isActive = true

        metaStack.orientation = .horizontal
        metaStack.alignment = .centerY
        metaStack.spacing = 4
        metaStack.setViews([capsule, spinner, metaLabel], in: .leading)
        // The meta column hugs its content and never compresses; the title
        // gets the rest. The tight case is a row carrying BOTH the "recovered"
        // capsule and a meta value.
        metaStack.setContentHuggingPriority(.required, for: .horizontal)
        metaStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [capsuleLabel, metaLabel] {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        for view in [titleLabel, metaStack, dateLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaStack.leadingAnchor, constant: -6),
            metaStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            metaStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionCellView is created in code")
    }

    func configure(
        title: String, dateText: String, meta: String,
        metaColor: NSColor, isFusing: Bool, isRecovered: Bool
    ) {
        titleLabel.stringValue = title
        dateLabel.stringValue = dateText
        metaLabel.stringValue = meta
        metaLabel.textColor = metaColor
        capsule.isHidden = !isRecovered
        spinner.isHidden = !isFusing
        if isFusing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

// MARK: - Sidebar/date/duration text

/// History text helpers (design 1d). Wall-clock based (SPEC §4.1 — durations
/// derive from wall clock, never the session clock).
enum HistoryMeta {
    /// Failure text token (design 1d #E0483E). Dynamic: #E0483E reads as mud
    /// on a dark background, so dark mode falls back to `systemRed`.
    static let failureColor = NSColor(name: "scribe.history.failure") { appearance in
        appearance.isDark
            ? .systemRed
            : NSColor(srgbRed: 0xE0 / 255, green: 0x48 / 255, blue: 0x3E / 255, alpha: 1)
    }

    /// Recovered-capsule text (design 1d #8A6A00 on the systemYellow 22%
    /// fill). Dark mode needs a light-on-dark counterpart.
    static let capsuleTextColor = NSColor(name: "scribe.history.recoveredTag") { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 1, green: 0.84, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0x8A / 255, green: 0x6A / 255, blue: 0x00, alpha: 1)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let hourMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    /// "Today, 9:00 AM" · "Yesterday, 2:30 PM" · "Aug 14, 9:30 AM".
    static func dateAndTime(_ date: Date) -> String {
        "\(dayLabel(date)), \(timeFormatter.string(from: date))"
    }

    /// "Today, 9:00–9:42 AM" (same-day range, one meridiem) — start only
    /// when the end is unknown or crosses midnight.
    static func timeRange(start: Date, end: Date?) -> String {
        guard let end, Calendar.current.isDate(start, inSameDayAs: end) else {
            return dateAndTime(start)
        }
        return "\(dayLabel(start)), \(hourMinuteFormatter.string(from: start))–\(timeFormatter.string(from: end))"
    }

    private static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    /// "42 min" / "1 hr 5 min" (rounded, minimum 1 min).
    static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
        }
        return "\(minutes) min"
    }

    /// Sidebar title for a session fusion never named. The row carries the
    /// date and the duration in dedicated slots already, so the date/duration
    /// `fallbackTitle` only duplicated them; this states the one thing the
    /// row cannot otherwise say.
    static let untitledRowTitle = "Untitled meeting"

    /// Untitled-session fallback (SPEC §4.5): date/duration. Used where there
    /// is no separate date line to duplicate — the detail pane heading, the
    /// delete confirmation, and export filenames. Recovered sessions keep a
    /// nil `endedAt` (SPEC §4.4) → date only.
    static func fallbackTitle(_ session: SessionRecord) -> String {
        if let ended = session.endedAt {
            return "\(dateAndTime(session.startedAt)) · \(duration(ended.timeIntervalSince(session.startedAt)))"
        }
        return dateAndTime(session.startedAt)
    }
}

private extension NSAppearance {
    /// True for the dark appearances (used by the dynamic color providers).
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Glyph drawing

/// History glyphs (design 1d/2d). Drawn through
/// `NSImage(size:flipped:drawingHandler:)` so the handler re-runs (and
/// `labelColor` re-resolves) whenever the glyph is drawn in a new
/// appearance — a `lockFocus` bitmap would bake in light or dark.
private enum HistoryGlyphs {

    /// Static action-item checkbox (design 1d): 13 pt square, radius 4,
    /// 1.5 pt border black 25% — a GLYPH, never interactive (SPEC §5: v0
    /// stores no done-ness; this surface must not become a todo widget).
    ///
    /// The accessibility description is phrased as STATE, not as a control
    /// (UX review finding 19): VoiceOver reading "checkbox, unchecked" would
    /// promise a toggle that does not exist here. The glyph rides inline as an
    /// `NSTextAttachment` before each action item, so the row reads
    /// "Action item, not tracked — Send annual-prepay quote to Dan".
    static let checkbox: NSImage = {
        let image = NSImage(size: NSSize(width: 13, height: 13), flipped: false) { _ in
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            let path = NSBezierPath(
                roundedRect: NSRect(x: 0.75, y: 0.75, width: 11.5, height: 11.5),
                xRadius: 4,
                yRadius: 4
            )
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        image.accessibilityDescription = "Action item, not tracked"
        return image
    }()

    /// Validator warning triangle (design 1d: `exclamationmark.triangle`,
    /// 13×12, #E6A700 with a knocked-out white mark). Appearance-independent
    /// on purpose — it sits on the card's yellow fill in both modes.
    static let validatorWarning: NSImage = {
        let image = NSImage(size: NSSize(width: 13, height: 12), flipped: true) { _ in
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 6.5, y: 1))
            triangle.line(to: NSPoint(x: 12, y: 11))
            triangle.line(to: NSPoint(x: 1, y: 11))
            triangle.close()
            NSColor(srgbRed: 0xE6 / 255, green: 0xA7 / 255, blue: 0, alpha: 1).setFill()
            triangle.fill()
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: 5.9, y: 4.4, width: 1.2, height: 3.2), xRadius: 0.6, yRadius: 0.6
            ).fill()
            NSBezierPath(ovalIn: NSRect(x: 5.75, y: 8.25, width: 1.5, height: 1.5)).fill()
            return true
        }
        image.accessibilityDescription = "Warning"
        return image
    }()

    /// Gray waveform for the empty state (design 2d): 26×22, four rounded
    /// bars, black 18%.
    static let emptyWaveform = NSImage(size: NSSize(width: 26, height: 22), flipped: false) { rect in
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let heights: [CGFloat] = [6, 16, 10, 4]
        let originX = (rect.width - (CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap)) / 2
        for (index, height) in heights.enumerated() {
            let bar = NSRect(
                x: originX + CGFloat(index) * (barWidth + gap),
                y: (rect.height - height) / 2,
                width: barWidth,
                height: height
            )
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        return true
    }
}


// MARK: - Sidebar row derivation (pure)

/// What one sidebar row says about a session (design 1d; SPEC §5).
///
/// Split out of `HistoryWindowController` — which needs a window, a table
/// view and an open GRDB store to exist — because the row is where the
/// storage state, the last fusion outcome and the note's presence are folded
/// into one word, and all three of those have been wrong in shipped builds.
enum HistoryRow {

    /// Row state, DERIVED at display time (SPEC §5): storage states stay
    /// `recording | processing | complete` on the rows themselves.
    enum State: Equatable {
        case recording, fused, fusing, failed
    }

    /// `failureMessage` is the live-event-or-persisted-column value (see
    /// `HistoryWindowController.failureMessage(for:)`) and `hasStoredNote`
    /// is whether the store holds a canonical note for the session.
    ///
    /// The `processing` case is the whole point. `processing` alone cannot
    /// tell "still fusing" from "failed permanently", and when the reason
    /// lived only in memory a failed meeting came back from a relaunch as a
    /// spinner that would never stop. A stored note under `processing` means
    /// fusion succeeded WITH validator findings — that row is fused, and
    /// Retry stays available; it is not a failure.
    static func state(storage: SessionState, failureMessage: String?, hasStoredNote: Bool) -> State {
        switch storage {
        case .recording:
            return .recording
        case .complete:
            return .fused
        case .processing:
            if failureMessage != nil { return .failed } // SPEC §5: processing + last error
            return hasStoredNote ? .fused : .fusing // findings keep a stored note
        }
    }

    /// The row's meta column. Only a fused row shows a duration, and a
    /// recovered session has no end (SPEC §4.4) so its duration is `nil` —
    /// an empty column, never an invented number.
    static func meta(for state: State, duration: String?) -> String {
        switch state {
        case .fused: return duration ?? ""
        case .recording: return "recording"
        case .fusing: return "fusing"
        case .failed: return "failed"
        }
    }

    /// The row's title line.
    ///
    /// NOT `HistoryMeta.fallbackTitle` (date · duration): this row already
    /// prints the date on line 2 and the duration in its own meta column, so
    /// the SPEC §4.5 fallback rendered as "Today, 8:30 AM · 1 min" stacked
    /// directly on top of "Today, 8:30 AM". The detail pane, which has no
    /// such columns, still uses the spec'd form.
    static func title(_ session: SessionRecord) -> String {
        guard let title = session.title, !title.isEmpty else { return HistoryMeta.untitledRowTitle }
        return title
    }
}
