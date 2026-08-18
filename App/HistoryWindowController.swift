import AppKit
import FusionKit
import Persistence
import SessionKit
import UniformTypeIdentifiers
import os

// MARK: - Controller

/// History window (SPEC §5; design/README "History window" + "Empty state",
/// designs 1d/2d): 760×470 titled window, 236 pt source-list sidebar — rows
/// show title (or date/duration fallback, SPEC §4.5), derived meta
/// (`fused | fusing | failed`, SPEC §5 — derived at display time, never a
/// schema column), date, and a "recovered" capsule (SPEC §4.4) — plus a
/// detail pane with a **Notes | Transcript** toggle, rendered markdown with
/// INLINE validator warning cards (SPEC §4.5 — the hallucination-audit
/// surface; the validator is re-run on display, deterministic and cheap) and
/// STATIC action-item checkbox glyphs (v0 stores no done-ness, SPEC §5).
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
        /// List-refresh cadence while a fusing row exists (spinner rows).
        static let fusingTick: TimeInterval = 1
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("sessionCell")
    /// Selection persistence (last selected session id) — cheap convenience.
    private static let selectedSessionDefaultsKey = "history.selectedSessionId"

    private let logger = Logger(subsystem: "com.example.scribe", category: "history")
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
    private var emptyStateView: NSView!

    /// Sessions newest-first (store order).
    private var sessions: [SessionRecord] = []
    /// Session ids with a canonical note (drives `fused` meta for
    /// `processing` rows — findings keep notes stored, SPEC §4.5).
    private var notePresence: Set<UUID> = []
    /// In-memory fusion failures from `fusionFailed` events (SPEC §5: the
    /// failed UI state is derived from `processing` + last error and is
    /// deliberately NOT persisted; before the first failure event after a
    /// relaunch, an interrupted session shows as "fusing" — documented v0
    /// limitation, Retry Fusion is always available for `processing` rows).
    private var fusionFailures: [UUID: String] = [:]
    private var selectedSessionId: UUID?
    private var detail: SessionDetail?
    /// Suppresses re-renders (and validator re-runs) on the 1 s tick when
    /// nothing display-relevant changed.
    private var lastRenderKey: DetailKey?

    private var eventTask: Task<Void, Never>?
    private var fusingTimer: Timer?

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
        reload()
        NSApp.activate(ignoringOtherApps: true) // LSUIElement accessory app
        window.makeKeyAndOrderFront(nil)
        syncFusingTimer()
    }

    /// Opens the window AT a session (menu-bar done-badge click, SPEC §5).
    func show(sessionId: UUID) {
        reload(selecting: sessionId)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        syncFusingTimer()
    }

    // MARK: - Window assembly (design 1d)

    private func buildWindow() {
        window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.minSize = Metrics.minWindowSize

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController())
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
        emptyStateView.wantsLayer = true
        emptyStateView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        emptyStateView.isHidden = true
        split.view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: split.view.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
        ])
    }

    /// 236 pt source-list sidebar: sidebar material + plain view-based
    /// table (rows built in `SessionCellView`; selection drawn by
    /// `SidebarRowView`).
    private func sidebarViewController() -> NSViewController {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.sidebarWidth, height: 200))

        let effect = NSVisualEffectView()
        effect.material = .sidebar // native source-list material ≈ design #F2F1EF
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)

        tableView.headerView = nil
        tableView.rowHeight = Metrics.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2) // design row gap 2
        tableView.backgroundColor = .clear
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: Self.cellIdentifier))

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
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
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        return controller
    }

    /// Detail pane: toolbar (segmented Notes | Transcript + four actions,
    /// hairline bottom) over the content text view.
    private func detailViewController() -> NSViewController {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        segmented.font = NSFont.systemFont(ofSize: 12) // design 1d: 12 pt segments
        segmented.selectedSegment = 0

        exportButton = makeToolbarButton("Export", action: #selector(exportTapped))
        retryButton = makeToolbarButton("Retry Fusion", action: #selector(retryTapped))
        evalButton = makeToolbarButton("Export Eval Case", action: #selector(exportEvalTapped))
        deleteButton = makeToolbarButton("Delete", action: #selector(deleteTapped), red: true)

        let toolbar = NSStackView(views: [
            segmented, toolbarSpacer(), exportButton, retryButton, evalButton, deleteButton,
        ])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toolbar)

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hairline)

        contentTextView = NSTextView(frame: .zero)
        contentTextView.isEditable = false
        contentTextView.isSelectable = true
        contentTextView.isRichText = false
        contentTextView.drawsBackground = false
        contentTextView.isVerticallyResizable = true
        contentTextView.isHorizontallyResizable = false
        contentTextView.autoresizingMask = [.width]
        contentTextView.textContainer?.widthTracksTextView = true
        contentTextView.textContainer?.lineFragmentPadding = 0
        contentTextView.textContainerInset = NSSize(width: 24, height: 18) // padding 20/24 (design 1d)

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
    private func makeToolbarButton(_ title: String, action: Selector, red: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.font = NSFont.systemFont(ofSize: 12)
        if red {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: HistoryMeta.failureColor,
            ])
        }
        button.isEnabled = false // enabled by selection state (updateActions)
        return button
    }

    /// Empty state (design 2d): centered gray waveform + "No sessions yet" +
    /// caption + bordered Start Meeting button.
    private func buildEmptyStateView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView(image: HistoryGlyphs.emptyWaveform)

        let title = NSTextField(labelWithString: "No sessions yet")
        title.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        title.textColor = NSColor.labelColor.withAlphaComponent(0.65)

        let caption = NSTextField(wrappingLabelWithString:
            "Start a meeting from the menu bar. Notes land here when fusion finishes.")
        caption.font = NSFont.systemFont(ofSize: 12)
        caption.textColor = NSColor.labelColor.withAlphaComponent(0.40)
        caption.alignment = .center
        caption.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let start = NSButton(title: "Start Meeting", target: self, action: #selector(startMeetingTapped))
        start.bezelStyle = .rounded // bordered native push button (design 2d)
        start.controlSize = .regular

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

    /// Sidebar row state, DERIVED at display time (SPEC §5): storage states
    /// stay `recording | processing | complete` on the rows.
    private enum RowState {
        case recording, fused, fusing, failed
    }

    private func rowState(_ session: SessionRecord) -> RowState {
        switch session.state {
        case .recording:
            return .recording
        case .complete:
            return .fused
        case .processing:
            if fusionFailures[session.id] != nil { return .failed } // SPEC §5: processing + last error
            return notePresence.contains(session.id) ? .fused : .fusing // findings keep a stored note
        }
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
            mode: segmented.selectedSegment
        )
    }

    // MARK: - Detail rendering

    private func renderDetail() {
        guard let detail else { return }
        let attributed = segmented.selectedSegment == 0
            ? renderNotes(detail)
            : renderTranscript(detail)
        contentTextView.textStorage?.setAttributedString(attributed)
        contentTextView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Notes face (design 1d): 17 pt semibold title, meta line
    /// ("Today, 9:00–9:42 AM · fused from 3 fragments"), inline validator
    /// warning cards, rendered note markdown with static checkbox glyphs.
    private func renderNotes(_ detail: SessionDetail) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let title = detail.displayTitle
        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]))
        out.append(NSAttributedString(string: metaLine(detail) + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))

        if let note = detail.note {
            // SPEC §4.5 validator: re-run on display — deterministic, no
            // model calls, no stored findings needed.
            let findings = NotesValidator.validate(markdown: note.markdown, segments: detail.segments)
            for finding in findings {
                out.append(validatorCard(finding))
            }
            out.append(MarkdownMiniRenderer.render(note.markdown, checkbox: HistoryGlyphs.checkbox))
        } else {
            out.append(statusLine(for: detail))
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
            } else if fusionFailures[detail.session.id] != nil {
                text += " · fusion failed"
            } else {
                text += " · fusing…"
            }
        }
        return text
    }

    /// Inline validator warning card (SPEC §4.5; design 1d): systemYellow 12%
    /// fill, ⚠ glyph, 12 pt text. TextKit per-run backgrounds cannot express
    /// the design's radius-7 card + border without TextKit block extras —
    /// rendered as highlighted ⚠ paragraphs instead (deliberate, SPEC §5
    /// "do not invest").
    private func validatorCard(_ finding: NotesValidator.Finding) -> NSAttributedString {
        let fill = NSColor.systemYellow.withAlphaComponent(0.12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 6
        paragraph.paragraphSpacing = 8
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.3

        let card = NSMutableAttributedString()
        card.append(NSAttributedString(string: "⚠ ", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(srgbRed: 0xE6 / 255, green: 0xA7 / 255, blue: 0, alpha: 1),
            .backgroundColor: fill,
        ]))
        card.append(NSAttributedString(string: "Validator: ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.75),
            .backgroundColor: fill,
        ]))
        card.append(NSAttributedString(string: finding.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.65),
            .backgroundColor: fill,
        ]))
        card.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: card.length))
        return card
    }

    /// No-note status line (fusing / failed / recording).
    private func statusLine(for detail: SessionDetail) -> NSAttributedString {
        let text: String
        switch detail.session.state {
        case .recording:
            text = "Meeting in progress — notes appear here after fusion."
        case .processing:
            if let message = fusionFailures[detail.session.id] {
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
        fusionFailures[session.id] = nil
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

    /// Empty-state Start Meeting (design 2d) — errors logged (start failures
    /// surface through the menu bar / setup wizard surfaces).
    @objc private func startMeetingTapped() {
        Task { @MainActor in
            do {
                try await coordinator.start()
            } catch {
                logger.error("Meeting start failed from History: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func modeChanged() {
        refreshDetailIfNeeded() // mode is part of the render key
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

    private func savePanel(defaultName: String, type: UTType, data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            logger.info("Exported \(url.lastPathComponent, privacy: .public)")
        } catch {
            presentError("Couldn't save \(url.lastPathComponent)", error)
        }
    }

    /// Filesystem-safe export name (≤60 chars before the extension).
    private static func fileName(for title: String, extension ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = title.components(separatedBy: invalid)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Session" : String(cleaned.prefix(60))
        return "\(base).\(ext)"
    }

    private func presentError(_ message: String, _ error: Error) {
        logger.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
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
            if window.isVisible { reload() }
        case .fusionFailed(let sessionId, let message):
            fusionFailures[sessionId] = message
            if window.isVisible { reload() }
        case .recoveredSessions:
            if window.isVisible { reload() }
        case .deviceEventLogged:
            break
        }
    }

    /// 1 s list refresh while a "fusing" row exists (spec'd data path for
    /// fusing rows; stopped when the window is closed or none remain).
    private func syncFusingTimer() {
        let needsTimer = window.isVisible && sessions.contains { rowState($0) == .fusing }
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
        let meta: String
        var metaColor = NSColor.secondaryLabelColor
        switch state {
        case .fused:
            meta = durationText(session) ?? ""
        case .recording:
            meta = "recording"
        case .fusing:
            meta = "fusing"
        case .failed:
            meta = "failed"
            metaColor = HistoryMeta.failureColor // design: #E0483E
        }
        cell.configure(
            title: session.title?.isEmpty == false ? session.title! : HistoryMeta.fallbackTitle(session),
            dateText: HistoryMeta.dateAndTime(session.startedAt),
            meta: meta,
            metaColor: metaColor,
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
        syncFusingTimer() // stops the fusing tick while closed
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
    let mode: Int
}

// MARK: - Sidebar rows

/// Selection fill for sidebar rows (design 1d: radius 6, black 7%).
private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.black.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// One sidebar row (design 1d): title 13 pt medium truncating + right meta
/// 11 pt ("42 min" | spinner + "fusing" | "failed" red; "recovered" yellow
/// capsule), second line date 11 pt.
private final class SessionCellView: NSTableCellView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let capsule = NSView()
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
        // The title yields to the right-hand meta (design: meta never truncates).
        titleLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(249), for: .horizontal
        )

        dateLabel.font = NSFont.systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor // design black 45%

        metaLabel.font = NSFont.systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor

        // "recovered" capsule (design 1d): 9 pt medium, systemYellow 22% fill,
        // #8A6A00 text, radius 4.
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 4
        capsule.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.22).cgColor
        capsule.isHidden = true
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
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.widthAnchor.constraint(equalToConstant: 10).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 10).isActive = true

        metaStack.orientation = .horizontal
        metaStack.alignment = .centerY
        metaStack.spacing = 4
        metaStack.setViews([capsule, spinner, metaLabel], in: .leading)

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
private enum HistoryMeta {
    /// Failure text #E0483E (design 1d).
    static let failureColor = NSColor(srgbRed: 0xE0 / 255, green: 0x48 / 255, blue: 0x3E / 255, alpha: 1)
    /// Recovered-capsule text #8A6A00 (design 1d).
    static let capsuleTextColor = NSColor(srgbRed: 0x8A / 255, green: 0x6A / 255, blue: 0x00, alpha: 1)

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

    /// Untitled-session fallback (SPEC §4.5): date/duration. Recovered
    /// sessions keep a nil `endedAt` (SPEC §4.4) → date only.
    static func fallbackTitle(_ session: SessionRecord) -> String {
        if let ended = session.endedAt {
            return "\(dateAndTime(session.startedAt)) · \(duration(ended.timeIntervalSince(session.startedAt)))"
        }
        return dateAndTime(session.startedAt)
    }
}

// MARK: - Glyph drawing

/// History glyphs (design 1d/2d) — drawn once; label-color based so they
/// follow light/dark at creation time (v0: "do not invest", SPEC §5).
private enum HistoryGlyphs {

    /// Static action-item checkbox (design 1d): 13 pt square, radius 4,
    /// 1.5 pt border black 25% — a GLYPH, never interactive (SPEC §5: v0
    /// stores no done-ness; this surface must not become a todo widget).
    static let checkbox: NSImage = {
        let image = NSImage(size: NSSize(width: 13, height: 13))
        image.lockFocus()
        NSColor.labelColor.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath(
            roundedRect: NSRect(x: 0.75, y: 0.75, width: 11.5, height: 11.5),
            xRadius: 4,
            yRadius: 4
        )
        path.lineWidth = 1.5
        path.stroke()
        image.unlockFocus()
        return image
    }()

    /// Gray waveform for the empty state (design 2d): 26×22, four rounded
    /// bars, black 18%.
    static let emptyWaveform: NSImage = {
        let size = NSSize(width: 26, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let heights: [CGFloat] = [6, 16, 10, 4]
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
        return image
    }()
}
