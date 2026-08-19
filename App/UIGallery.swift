import AppKit
import CaptureKit
import FusionKit
import Persistence
import ScratchpadKit
import SessionKit
import TranscribeKit
import os

/// UI gallery — DEV TOOLING ONLY (not a product surface).
///
/// Launch the app with `-uiGallery YES` (NSUserDefaults picks `-key value`
/// out of argv, so `UserDefaults.standard.bool(forKey: "uiGallery")` is the
/// switch) and `ScribeApp.applicationDidFinishLaunching` runs this instead of
/// the real wiring: no setup wizard, no Sparkle, no capture engine, no TCC
/// prompts. Every app surface is opened as its own window over a seeded
/// in-memory store, laid out so the harness can shoot each one, and the
/// window numbers are printed on stdout for `scripts/ui-gallery.sh`:
///
///     GALLERY<TAB><sceneName><TAB><windowNumber>
///     GALLERY<TAB>menubar-region<TAB>x,y,w,h   (screencapture -R coords)
///     GALLERY<TAB>menubar-states<TAB>file:<path>   (already-written PNG)
///
/// The point of the gallery is to screenshot the REAL views, so every scene
/// drives the production controllers (`HistoryWindowController`,
/// `ScratchpadPanelController`, `SettingsWindowController`,
/// `SetupWizardController`) — this file contains no view code of its own,
/// only fixtures, window placement and the stdout protocol. The one
/// exception is `menubar-states`: the status item is not a window and can
/// only be region-captured, which returns black whenever the menu bar
/// auto-hides, so that scene draws the REAL status-item artwork (via
/// `MenuBarController.galleryStateImages`) onto a simulated menu bar strip
/// and writes the PNG itself. The strip is scaffolding — the artwork on it
/// is production output. Where a
/// controller's state is only reachable from a live session (scratchpad
/// elapsed time, History's in-memory fusion failures) it exposes a narrow
/// `gallery…` test seam; those seams are documented at their definitions.
///
/// Fixture data mirrors design/README §3 (History).
@MainActor
enum UIGallery {

    /// `-uiGallery YES` on the command line.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "uiGallery") }

    /// Keeps every controller (and therefore every window) alive for the
    /// lifetime of the process — the gallery stays up until the harness
    /// kills it.
    private static var retained: [Any] = []

    private static let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "uigallery")

    // MARK: - Entry point

    static func run() {
        let seeded: MeetingStore
        let empty: MeetingStore
        do {
            seeded = try MeetingStore.inMemory()
            empty = try MeetingStore.inMemory()
            try Fixtures.seed(into: seeded)
        } catch {
            FileHandle.standardError.write(Data("GALLERY-ERROR\tfixture seeding failed: \(error)\n".utf8))
            exit(1)
        }

        let composer = FragmentComposer()
        let seededCoordinator = makeCoordinator(store: seeded)
        let emptyCoordinator = makeCoordinator(store: empty)
        seededCoordinator.attach(composer)
        retained.append(contentsOf: [composer, seededCoordinator, emptyCoordinator] as [Any])

        // Status item — the menu-bar surface (idle glyph); its screen frame
        // is what the `menubar-region` line reports.
        let menuBar = MenuBarController(coordinator: seededCoordinator)
        retained.append(menuBar)

        var scenes: [(name: String, window: NSWindow)] = []

        // MARK: History (design 1d) — Notes and Transcript faces over the
        // seeded store, plus the 2d empty state over an empty one.
        let notesHistory = HistoryWindowController(store: seeded, coordinator: seededCoordinator)
        notesHistory.galleryConfigure(
            select: Fixtures.acmeId, tab: 0, failed: Fixtures.fusionFailures
        )
        scenes.append(("history-notes", notesHistory.galleryWindow))

        let transcriptHistory = HistoryWindowController(store: seeded, coordinator: seededCoordinator)
        transcriptHistory.galleryConfigure(
            select: Fixtures.acmeId, tab: 1, failed: Fixtures.fusionFailures
        )
        scenes.append(("history-transcript", transcriptHistory.galleryWindow))

        let emptyHistory = HistoryWindowController(store: empty, coordinator: emptyCoordinator)
        emptyHistory.galleryConfigure(select: nil, tab: 0, failed: [:])
        scenes.append(("history-empty", emptyHistory.galleryWindow))

        retained.append(contentsOf: [notesHistory, transcriptHistory, emptyHistory])

        // MARK: Settings (design 1e).
        let settings = SettingsWindowController()
        settings.show()
        retained.append(settings)
        if let window = window(titled: "Settings") {
            scenes.append(("settings", window))
        } else {
            warn("settings window not found")
        }

        // MARK: Scratchpad panel (designs 1b/2a) — three faces.
        let recordingPad = ScratchpadPanelController(coordinator: seededCoordinator, composer: composer)
        recordingPad.galleryPresent(
            recording: true,
            elapsed: 24 * 60 + 16, // design 1b shows 24:16
            body: """
            ask about the SOC 2 report — infosec is the long pole
            240 seats vs 200 contracted, needs the volume tier
            legal wants the redlines back before the quarter closes
            """
        )
        scenes.append(("scratchpad-recording", recordingPad.galleryWindow))

        let emptyPad = ScratchpadPanelController(coordinator: seededCoordinator, composer: composer)
        emptyPad.galleryPresent(recording: true, elapsed: 24 * 60 + 16, body: "")
        scenes.append(("scratchpad-empty", emptyPad.galleryWindow))

        let noMeetingPad = ScratchpadPanelController(coordinator: seededCoordinator, composer: composer)
        noMeetingPad.galleryPresent(recording: false, elapsed: 0, body: "")
        scenes.append(("scratchpad-no-meeting", noMeetingPad.galleryWindow))

        retained.append(contentsOf: [recordingPad, emptyPad, noMeetingPad])

        // MARK: Recording chip (design 4a) — the artboard's two specimens.
        // The real chip only exists while a session is live AND the status
        // item is off screen, neither of which this harness can arrange, so
        // both scenes go through the controller's `galleryPresent` seam.
        let restingChip = RecordingChipController(coordinator: seededCoordinator)
        restingChip.galleryPresent(elapsed: 24 * 60 + 16, hovered: false) // design 4a: 24:16
        scenes.append(("recording-chip", restingChip.galleryWindow))

        let hoverChip = RecordingChipController(coordinator: seededCoordinator)
        hoverChip.galleryPresent(elapsed: 24 * 60 + 16, hovered: true)
        scenes.append(("recording-chip-hover", hoverChip.galleryWindow))

        retained.append(contentsOf: [restingChip, hoverChip])

        // MARK: Setup wizard, first step (T8).
        let wizard = SetupWizardController()
        wizard.show(at: .welcome)
        retained.append(wizard)
        if let window = window(titled: "Scribe Setup") {
            scenes.append(("wizard-welcome", window))
        } else {
            warn("setup wizard window not found")
        }

        layout(scenes.map(\.window))
        for scene in scenes {
            scene.window.orderFrontRegardless()
            scene.window.displayIfNeeded()
        }

        // One run-loop pass (plus a beat for vibrancy/first draw) before the
        // window numbers go out: the harness starts capturing the moment it
        // reads them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            for scene in scenes {
                print("GALLERY\t\(scene.name)\t\(scene.window.windowNumber)")
            }
            if let path = writeMenuBarStates(menuBar) {
                print("GALLERY\tmenubar-states\tfile:\(path)")
            } else {
                warn("menubar-states could not be composed")
            }
            print("GALLERY\tmenubar-region\t\(menubarRegion(menuBar))")
            fflush(stdout)
        }
    }

    // MARK: - Support

    /// A coordinator with nothing real behind it: the gallery never starts a
    /// session, and the stub engine + unimplemented transcriber guarantee no
    /// TCC prompt and no model load. `fusionRunner` is never invoked.
    private static func makeCoordinator(store: MeetingStore) -> SessionCoordinator {
        SessionCoordinator(
            store: store,
            captureEngine: StubCaptureEngine(),
            transcriber: UnimplementedTranscriber(),
            fusionRunner: { _ in .failure(.provider("ui gallery — fusion is never run")) }
        )
    }

    private static func window(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.title == title && $0.isVisible }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("GALLERY-WARN\t\(message)\n".utf8))
    }

    /// Shelf-packs the windows into the main screen's visible frame, top-left
    /// first, so scenes don't overlap. The full set is larger than a laptop
    /// display, so when a row no longer fits the packer restarts at the top
    /// with a cascade offset: `screencapture -l` shoots each window's own
    /// image, so a partial overlap costs nothing but keeps every window fully
    /// on screen (an off-screen window has no capturable backing store).
    private static func layout(_ windows: [NSWindow]) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let margin: CGFloat = 8
        let gap: CGFloat = 8
        var cascade: CGFloat = 0
        var x = visible.minX + margin
        var rowTop = visible.maxY - margin
        var rowHeight: CGFloat = 0

        for window in windows {
            let size = window.frame.size
            if x + size.width > visible.maxX - margin, rowHeight > 0 {
                x = visible.minX + margin + cascade
                rowTop -= rowHeight + gap
                rowHeight = 0
            }
            if rowTop - size.height < visible.minY + margin {
                cascade += 32
                x = visible.minX + margin + cascade
                rowTop = visible.maxY - margin - cascade
                rowHeight = 0
            }
            window.setFrameOrigin(NSPoint(x: x, y: rowTop - size.height))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// The status item's screen rect in `screencapture -R` coordinates
    /// (top-left origin, primary screen). Padded a little so the capsule's
    /// shadow and the menu-bar background around the item are included.
    private static func menubarRegion(_ menuBar: MenuBarController) -> String {
        let primaryHeight = (NSScreen.screens.first?.frame.height) ?? 0
        guard let frame = menuBar.galleryStatusItemFrame else {
            warn("status item has no window — falling back to a top-right menu bar strip")
            let width = (NSScreen.screens.first?.frame.width) ?? 1_440
            return "\(Int(width) - 320),0,320,32"
        }
        let padding: CGFloat = 4
        let x = Int((frame.minX - padding).rounded(.down))
        let y = Int((primaryHeight - frame.maxY).rounded(.down))
        let width = Int((frame.width + padding * 2).rounded(.up))
        let height = Int(frame.height.rounded(.up))
        return "\(x),\(y),\(width),\(height)"
    }

    // MARK: - menubar-states (composed, not captured)

    /// Draws every status-item state onto a simulated dark menu bar strip
    /// and writes it as a PNG, returning the path.
    ///
    /// Why this exists: `menubar-region` shoots the live status item, which
    /// is the ground truth — but only when the menu bar is on screen. With
    /// "Automatically hide and show the menu bar" on it is a black
    /// rectangle, and even at its best it shows ONE state (whatever the item
    /// happens to be in). This composes all five, side by side with design
    /// 1a's own geometry: 26 pt strip, radius 7, `rgba(30,30,34,.55)` over
    /// the artboard's wallpaper gradient, items right-aligned with a 14 pt
    /// gap before the (macOS-owned, simulated) clock.
    ///
    /// Only the strip, the wallpaper and the row labels are drawn here; each
    /// glyph is the production image the status button is given.
    private static func writeMenuBarStates(_ menuBar: MenuBarController) -> String? {
        let states = menuBar.galleryStateImages(elapsedText: "24:16", dark: true)
        guard !states.isEmpty else { return nil }

        let width: CGFloat = 460 // design 1a artboard
        let sidePadding: CGFloat = 20
        let topPadding: CGFloat = 20
        let footerHeight: CGFloat = 30
        let labelWidth: CGFloat = 76
        let labelGap: CGFloat = 12
        let stripHeight: CGFloat = 26
        let stripRadius: CGFloat = 7
        let stripPadding: CGFloat = 12
        let itemGap: CGFloat = 14
        let rowGap: CGFloat = 14
        let rows = CGFloat(states.count)
        let height = topPadding + rows * stripHeight + (rows - 1) * rowGap + footerHeight
        let scale = 2 // retina — the strip is 26 pt tall, the glyphs 13–18 pt

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width) * scale,
            pixelsHigh: Int(height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Simulated desktop wallpaper (design 1a artboard backdrop).
        let backdrop = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(
            colors: [
                NSColor(srgbRed: 0x3D / 255, green: 0x4A / 255, blue: 0x63 / 255, alpha: 1),
                NSColor(srgbRed: 0x5C / 255, green: 0x56 / 255, blue: 0x70 / 255, alpha: 1),
                NSColor(srgbRed: 0x8F / 255, green: 0x6A / 255, blue: 0x72 / 255, alpha: 1),
            ],
            atLocations: [0, 0.45, 1],
            colorSpace: .sRGB
        )?.draw(in: backdrop, angle: -65)

        let labelFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
            .kern: 0.72, // .08em
        ]
        let clockFont = NSFont.systemFont(ofSize: 12)
        let clockAttributes: [NSAttributedString.Key: Any] = [
            .font: clockFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let clock = "Mon 9:41 AM" as NSString // macOS-owned, simulated
        let clockSize = clock.size(withAttributes: clockAttributes)

        for (index, state) in states.enumerated() {
            let stripTop = height - topPadding - CGFloat(index) * (stripHeight + rowGap)
            let strip = NSRect(
                x: sidePadding + labelWidth + labelGap,
                y: stripTop - stripHeight,
                width: width - sidePadding * 2 - labelWidth - labelGap,
                height: stripHeight
            )

            let label = state.state.uppercased() as NSString
            let labelSize = label.size(withAttributes: labelAttributes)
            label.draw(
                at: NSPoint(x: sidePadding, y: strip.midY - labelSize.height / 2),
                withAttributes: labelAttributes
            )

            NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 34 / 255, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: strip, xRadius: stripRadius, yRadius: stripRadius).fill()

            clock.draw(
                at: NSPoint(
                    x: strip.maxX - stripPadding - clockSize.width,
                    y: strip.midY - clockSize.height / 2
                ),
                withAttributes: clockAttributes
            )

            let glyph = tintedIfTemplate(state.image)
            let glyphRect = NSRect(
                x: strip.maxX - stripPadding - clockSize.width - itemGap - glyph.size.width,
                y: (strip.midY - glyph.size.height / 2).rounded(),
                width: glyph.size.width,
                height: glyph.size.height
            )
            glyph.draw(in: glyphRect)
        }

        let footnote = "status-item artwork drawn directly — no screen capture" as NSString
        footnote.draw(
            at: NSPoint(x: sidePadding, y: footerHeight / 2 - 5),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.45),
            ]
        )

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scribe-gallery-menubar-states.png")
        do {
            try data.write(to: url)
        } catch {
            warn("menubar-states write failed: \(error)")
            return nil
        }
        return url.path
    }

    /// Template images (the idle waveform) reach the system uncolored — the
    /// menu bar tints them. Painted here at design 1a's `white 92%`.
    private static func tintedIfTemplate(_ image: NSImage) -> NSImage {
        guard image.isTemplate else { return image }
        let tinted = NSImage(size: image.size)
        let bounds = NSRect(origin: .zero, size: image.size)
        tinted.lockFocus()
        image.draw(in: bounds)
        NSColor.white.withAlphaComponent(0.92).setFill()
        bounds.fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}

// MARK: - Fixtures (design/README §3)

@MainActor
private enum Fixtures {

    static let acmeId = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let designCritId = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    static let priyaId = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
    static let infraId = UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!

    /// The `failed` row state is derived from `processing` + a
    /// `fusionFailed` event or the persisted column; the gallery
    /// hands History the same map the event handler would have built.
    static let fusionFailures: [UUID: String] = [
        infraId: "The Anthropic API returned 529 (overloaded).",
    ]

    static func seed(into store: MeetingStore) throws {
        try seedAcme(into: store)

        // "Design crit — panels" — yesterday 2:30 PM, still fusing
        // (processing, no note, no end time).
        try insert(
            into: store, id: designCritId, title: "Design crit — panels",
            start: at(dayOffset: -1, hour: 14, minute: 30), duration: nil,
            state: .processing, recovered: false
        )

        // "1:1 with Priya" — yesterday 11:00 AM, 28 min, fused.
        try insert(
            into: store, id: priyaId, title: "1:1 with Priya",
            start: at(dayOffset: -1, hour: 11, minute: 0), duration: 28 * 60,
            state: .complete, recovered: false
        )
        try store.insertCanonicalNote(NoteRecord(
            sessionId: priyaId,
            markdown: """
            ## Summary
            Career-track check-in. Priya wants more time on the capture path and less on release chores; we agreed to swap her off the on-call rotation next cycle.

            ## Action items
            - Move Priya off the release rotation for one cycle — me, this week
            - Draft the capture-path ownership note for the team — Priya
            """,
            model: "claude-sonnet-4-6",
            promptVersion: "v1"
        ))

        // "Infra standup" — Aug 14 9:30 AM, crash-recovered, fusion failed.
        // Recovered sessions keep a nil endedAt on purpose (SPEC §4.4).
        try insert(
            into: store, id: infraId, title: "Infra standup",
            start: at(month: 8, day: 14, hour: 9, minute: 30), duration: nil,
            state: .processing, recovered: true
        )
    }

    // MARK: Acme renewal call — the fully-populated session

    private static func seedAcme(into store: MeetingStore) throws {
        try insert(
            into: store, id: acmeId, title: "Acme renewal call",
            start: at(dayOffset: 0, hour: 9, minute: 0), duration: 42 * 60,
            state: .complete, recovered: false
        )

        for segment in transcript {
            try store.upsertSegment(SegmentRecord(
                sessionId: acmeId,
                channel: segment.channel,
                text: segment.text,
                startOffset: segment.start,
                endOffset: segment.end,
                isFinal: true
            ))
        }

        // Three fragments → the notes meta line reads "fused from 3 fragments".
        let fragments: [(TimeInterval, String)] = [
            (68, "240 seats vs 200 contracted — volume tier?"),
            (412, "SOC 2 + DPA addendum for their infosec review"),
            (726, "redlines date sounded made up, check the transcript"),
        ]
        for (offset, text) in fragments {
            try store.upsertFragment(FragmentRecord(
                sessionId: acmeId, text: text, anchorOffset: offset
            ))
        }

        // EXACTLY ONE warning card is intended here (design 1d): the `[12:04]`
        // citation deliberately quotes something nobody said, so
        // NotesValidator (SPEC §4.5) raises a quoteMismatch. The other two
        // action items carry citations that DO resolve against the seeded
        // transcript below — without them the validator's `missingCitation`
        // check (every Action item must cite) would raise two more cards and
        // bury the one this fixture exists to show.
        try store.insertCanonicalNote(NoteRecord(
            sessionId: acmeId,
            markdown: """
            ## Summary
            Renewal for the 2026 term. Acme is running 240 seats against a 200-seat contract and wants the volume tier applied before they sign. The security review is the long pole: their infosec team needs the updated SOC 2 report and a DPA addendum, and legal has the paperwork but no committed date.

            ## Action items
            - Send the revised quote with the 240-seat volume tier — Priya, by Wednesday: [01:20] "I'll send a revised quote with the two-forty tier in it"
            - Chase legal for the redlines: [12:04] "get the redlines back to us by Thursday"
            - Share the SOC 2 report and the DPA addendum with Acme infosec — Sam: [06:51] "I can share the report today"

            ## Notes
            Pricing pushback was about the *step* between tiers, not the headline number. No decision on the multi-year option — they revisit it after the security review.
            """,
            model: "claude-sonnet-4-6",
            promptVersion: "v1"
        ))
    }

    private static let transcript: [(channel: Channel, start: TimeInterval, end: TimeInterval, text: String)] = [
        (.remote, 6, 13.4, "Thanks for making the time — we wanted to walk the renewal terms before the quarter closes."),
        (.local, 14.2, 19.8, "Happy to. I pulled the usage numbers this morning so we can talk about seats first."),
        (.remote, 21.0, 28.6, "That's the sticking point on our side. Finance flagged that we're well past what we signed for."),
        (.local, 62.5, 71.2, "You're at two hundred and forty active seats against a two hundred seat contract."),
        (.remote, 72.0, 79.5, "Right, and we'd want the volume tier applied rather than paying the overage rate."),
        (.local, 80.4, 88.1, "That's reasonable. I'll send a revised quote with the two-forty tier in it."),
        (.remote, 402.0, 410.7, "Before any of that, our infosec team needs the current SOC 2 report."),
        (.local, 411.5, 419.0, "I can share the report today. Do they also need the DPA addendum?"),
        (.remote, 420.2, 427.4, "They do, and that review has historically taken us about two weeks."),
        (.remote, 718.0, 726.9, "Legal has the paperwork now. I'll chase them and let you know where it lands."),
        (.local, 728.0, 734.6, "Understood — I'll keep the quote open on our side until then."),
        (.remote, 2_390.0, 2_398.2, "Let's reconvene once security signs off and we'll get signatures moving."),
    ]

    // MARK: Insert helper

    private static func insert(
        into store: MeetingStore,
        id: UUID,
        title: String,
        start: Date,
        duration: TimeInterval?,
        state: SessionState,
        recovered: Bool
    ) throws {
        var session = try store.createSession(id: id, startedAt: start)
        session.title = title
        session.endedAt = duration.map { start.addingTimeInterval($0) }
        session.state = state
        session.recovered = recovered
        try store.updateSession(session)
    }

    // MARK: Dates

    private static func at(dayOffset: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// A fixed calendar day in the current year (design/README's "Aug 14").
    private static func at(month: Int, day: Int, hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year], from: Date())
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date()
    }
}
