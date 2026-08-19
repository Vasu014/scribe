import AppKit
import SessionKit
import XCTest

/// The menu bar's derived presentation (SPEC §5, design 1a).
///
/// The controller itself needs a live `NSStatusItem` and a real
/// `SessionCoordinator`, so what is checked here is the pure mapping the
/// controller delegates to. See the suite's gap notes: the artwork, the pulse
/// timer and the menu's ATTACHMENT still need a running app.
final class MenuBarPresentationTests: XCTestCase {

    private let allStates: [SessionDisplayState] = [
        .idle, .recording, .processing, .done(sessionId: UUID()), .failed(sessionId: UUID()),
    ]

    // MARK: Retry Fusion (SPEC §5)

    /// "Failed → the menu gains Retry Fusion" — and no other state does.
    /// Offering it during `processing` invites a retry of a fusion that is
    /// still running; leaving it behind in `idle` offers a retry of nothing.
    func testRetryFusionAppearsInTheFailureStateOnly() {
        XCTAssertTrue(MenuBarPresentation.retryFusionIsVisible(in: .failed(sessionId: UUID())))
        XCTAssertFalse(MenuBarPresentation.retryFusionIsVisible(in: .idle))
        XCTAssertFalse(MenuBarPresentation.retryFusionIsVisible(in: .recording))
        XCTAssertFalse(MenuBarPresentation.retryFusionIsVisible(in: .processing))
        XCTAssertFalse(MenuBarPresentation.retryFusionIsVisible(in: .done(sessionId: UUID())))
    }

    /// Open Notes rides the done transient only — it is the keyboard and
    /// VoiceOver path to the badge's click target, and it points at one
    /// specific session id.
    func testOpenNotesAppearsInTheDoneTransientOnly() {
        XCTAssertTrue(MenuBarPresentation.openNotesIsVisible(in: .done(sessionId: UUID())))
        XCTAssertFalse(MenuBarPresentation.openNotesIsVisible(in: .idle))
        XCTAssertFalse(MenuBarPresentation.openNotesIsVisible(in: .recording))
        XCTAssertFalse(MenuBarPresentation.openNotesIsVisible(in: .processing))
        XCTAssertFalse(MenuBarPresentation.openNotesIsVisible(in: .failed(sessionId: UUID())))
    }

    /// The two transient items are mutually exclusive — one of them showing
    /// while the other does would put two conflicting calls-to-action in the
    /// same menu.
    func testRetryAndOpenNotesAreNeverBothVisible() {
        for state in allStates {
            XCTAssertFalse(
                MenuBarPresentation.retryFusionIsVisible(in: state)
                    && MenuBarPresentation.openNotesIsVisible(in: state),
                "\(state)"
            )
        }
    }

    // MARK: Start / Stop

    /// Stop while recording; Start everywhere else — including `processing`
    /// and `failed`, where a previous meeting is still being fused but a new
    /// one may begin.
    func testStartStopTitleTracksRecordingOnly() {
        XCTAssertEqual(MenuBarPresentation.startStopTitle(in: .recording), "Stop Meeting")
        for state in allStates where state != .recording {
            XCTAssertEqual(MenuBarPresentation.startStopTitle(in: state), "Start Meeting", "\(state)")
        }
    }

    /// ⌘. is the macOS stop idiom and a status-menu key equivalent only fires
    /// while the menu is tracking — so it must be advertised only when there
    /// is something to stop, or the menu shows a shortcut that does nothing.
    func testStopShortcutIsAdvertisedOnlyWhileRecording() {
        XCTAssertEqual(MenuBarPresentation.startStopKeyEquivalent(in: .recording), ".")
        for state in allStates where state != .recording {
            XCTAssertEqual(MenuBarPresentation.startStopKeyEquivalent(in: state), "", "\(state)")
        }
    }

    // MARK: The 4 s done transient

    /// The done badge reverts to idle after its hold.
    func testDoneRevertsToIdle() {
        XCTAssertEqual(MenuBarPresentation.stateAfterDoneHold(.done(sessionId: UUID())), .idle)
    }

    /// The revert is a 4 s timer, and 4 s is plenty of time for the user to
    /// have started the next meeting. A revert that fired unconditionally
    /// would drop a LIVE recording capsule back to the idle waveform with the
    /// microphone open — the one thing SPEC §5's consent posture forbids.
    func testDoneRevertDoesNotClobberAStateThatMovedOn() {
        for state in [SessionDisplayState.idle, .recording, .processing, .failed(sessionId: UUID())] {
            XCTAssertNil(MenuBarPresentation.stateAfterDoneHold(state), "\(state)")
        }
    }

    // MARK: Done-badge click routing (finding 9)

    /// While the badge is up the status item has no menu attached, so the
    /// button's own click has to route both ways: left opens the notes, right
    /// or Control opens the menu. Getting this wrong once made Quit, Settings
    /// and Start unreachable for 4 s after every meeting.
    func testClickRouting() {
        XCTAssertTrue(MenuBarPresentation.clickWantsMenu(mouseEvent(.rightMouseUp, [])))
        XCTAssertTrue(MenuBarPresentation.clickWantsMenu(mouseEvent(.rightMouseDown, [])))
        XCTAssertTrue(MenuBarPresentation.clickWantsMenu(mouseEvent(.leftMouseUp, .control)))
        XCTAssertFalse(MenuBarPresentation.clickWantsMenu(mouseEvent(.leftMouseUp, [])))
        XCTAssertFalse(MenuBarPresentation.clickWantsMenu(mouseEvent(.leftMouseUp, .shift)))
        XCTAssertFalse(MenuBarPresentation.clickWantsMenu(mouseEvent(.leftMouseUp, .command)))
    }

    /// A keyboard-driven `performClick` carries NO event. That must be the
    /// advertised action (open the notes), not a menu pop — a VoiceOver user
    /// activating the badge is asking for the notes.
    func testKeyboardActivationWithNoEventTakesTheAdvertisedAction() {
        XCTAssertFalse(MenuBarPresentation.clickWantsMenu(nil))
    }

    private func mouseEvent(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    // MARK: Accessibility (blocker 10 / findings 9, 21)

    /// SPEC §5's consent posture — "the recording indicator is ALWAYS
    /// visible" — only holds for a VoiceOver user if idle and recording are
    /// told apart by ear. Every state must say something different.
    func testEveryStateHasItsOwnDistinctLabel() {
        let labels = allStates.map { MenuBarPresentation.announcement(for: $0, elapsed: 90).label }
        XCTAssertEqual(Set(labels).count, labels.count, "two states read identically: \(labels)")
        for label in labels {
            XCTAssertFalse(label.isEmpty)
            XCTAssertTrue(label.hasPrefix("Scribe"), label)
        }
    }

    func testIdleSaysItIsNotRecording() {
        let idle = MenuBarPresentation.announcement(for: .idle, elapsed: 0)
        XCTAssertTrue(idle.label.contains("not recording"), idle.label)
        XCTAssertNil(idle.value)
    }

    /// The capsule's clock is pixels inside a bitmap; the label and the value
    /// are the only way it reaches an assistive client, and both must be the
    /// spoken form.
    func testRecordingLabelAndValueCarryTheSpokenElapsed() {
        let recording = MenuBarPresentation.announcement(for: .recording, elapsed: 1_456)
        XCTAssertTrue(recording.label.contains("recording"), recording.label)
        XCTAssertTrue(recording.label.contains("24 minutes 16 seconds"), recording.label)
        XCTAssertEqual(recording.value, "24 minutes 16 seconds")
        XCTAssertFalse(recording.label.contains("24:16"), "the digit form must not be spoken")
    }

    /// The ⚠ is colour alone (finding 21) and "Notes ready" is a drawn glyph,
    /// so both need help text that names the way forward.
    func testTransientAndFailureStatesExplainWhatToDo() {
        let done = MenuBarPresentation.announcement(for: .done(sessionId: UUID()), elapsed: 0)
        XCTAssertTrue(done.label.contains("notes ready"), done.label)
        let doneHelp = done.help ?? ""
        XCTAssertTrue(doneHelp.contains("History"), doneHelp)
        XCTAssertTrue(doneHelp.contains("Control-click"), doneHelp)

        let failed = MenuBarPresentation.announcement(for: .failed(sessionId: UUID()), elapsed: 0)
        XCTAssertTrue(failed.label.contains("failed"), failed.label)
        XCTAssertEqual(failed.help?.contains("Retry Fusion"), true, failed.help ?? "nil")
    }

    /// Help is for the states that need it. A permanent help string on idle
    /// or recording is read out on every focus and becomes noise.
    func testStatesWithNothingToExplainCarryNoHelp() {
        for state in [SessionDisplayState.idle, .recording, .processing] {
            XCTAssertNil(MenuBarPresentation.announcement(for: state, elapsed: 12).help, "\(state)")
        }
    }

    /// Only the done state offers a VoiceOver custom action, so its name has
    /// to match what the menu item says or the two paths read as two things.
    func testCustomActionNameMatchesTheMenuItem() {
        XCTAssertTrue(MenuBarPresentation.openNotesActionName.contains("notes"))
        XCTAssertTrue(MenuBarPresentation.openNotesActionName.contains("History"))
    }
}
