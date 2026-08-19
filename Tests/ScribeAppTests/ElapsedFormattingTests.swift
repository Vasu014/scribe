import AppKit
import XCTest

/// The elapsed clock, in both faces it has: the digits on the menu-bar capsule
/// (`Formatting.elapsedString`) and the words a screen reader speaks
/// (`MenuBarPresentation.spokenElapsed`). Both derive from wall clock, never
/// the session clock (SPEC §4.1).
final class ElapsedFormattingTests: XCTestCase {

    // MARK: Digits

    func testMinuteAndHourBoundaries() {
        XCTAssertEqual(Formatting.elapsedString(0), "00:00")
        XCTAssertEqual(Formatting.elapsedString(1), "00:01")
        XCTAssertEqual(Formatting.elapsedString(59), "00:59")
        XCTAssertEqual(Formatting.elapsedString(60), "01:00")
        XCTAssertEqual(Formatting.elapsedString(61), "01:01")
        XCTAssertEqual(Formatting.elapsedString(1_456), "24:16")
        XCTAssertEqual(Formatting.elapsedString(3_599), "59:59")
        // The hour rollover is where a %02d minute field would print "60:00".
        XCTAssertEqual(Formatting.elapsedString(3_600), "1:00:00")
        XCTAssertEqual(Formatting.elapsedString(3_661), "1:01:01")
        XCTAssertEqual(Formatting.elapsedString(36_000), "10:00:00")
    }

    /// The display is FLOORED, never rounded: a rounded clock shows "00:01"
    /// while the session is 0.6 s old, i.e. ahead of the tick it is meant to
    /// mirror.
    func testSubSecondValuesFloor() {
        XCTAssertEqual(Formatting.elapsedString(0.9), "00:00")
        XCTAssertEqual(Formatting.elapsedString(59.999), "00:59")
        XCTAssertEqual(Formatting.elapsedString(3_599.9), "59:59")
    }

    /// A clock skew or an early tick can hand this a negative interval; it
    /// must clamp, not print "-1:-1".
    func testNegativeIntervalsClampToZero() {
        XCTAssertEqual(Formatting.elapsedString(-1), "00:00")
        XCTAssertEqual(Formatting.elapsedString(-3_600), "00:00")
    }

    /// The capsule redraws at 30 Hz on top of itself, so every digit must
    /// occupy the same width or the clock visibly jitters. This is what the
    /// SF Mono / monospaced-digit fallback in `elapsedFont` buys.
    func testElapsedFontHasTabularDigits() {
        let font = Formatting.elapsedFont(ofSize: 12)
        let widths = (0...9).map { digit -> CGFloat in
            NSAttributedString(string: "\(digit)", attributes: [.font: font]).size().width
        }
        for width in widths {
            XCTAssertEqual(width, widths[0], accuracy: 0.01, "digit advances differ — the clock will jitter")
        }
    }

    // MARK: Words (VoiceOver)

    /// "24:16" is spoken "twenty-four sixteen" (or worse) by speech synthesis,
    /// so the accessibility label carries units.
    func testSpokenFormUsesUnitsNotDigits() {
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(0), "0 seconds")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(1), "1 second")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(59), "59 seconds")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(61), "1 minute 1 second")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(1_456), "24 minutes 16 seconds")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(3_661), "1 hour 1 minute 1 second")
    }

    /// Singular vs plural on every component — "1 minutes" is the kind of
    /// thing nobody hears until a screen reader says it out loud.
    func testUnitsArePluralizedIndependently() {
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(2), "2 seconds")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(60), "1 minute")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(120), "2 minutes")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(3_600), "1 hour")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(7_200), "2 hours")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(7_260), "2 hours 1 minute")
    }

    /// Zero-valued components are dropped, so "1 hour" never reads
    /// "1 hour 0 minutes 0 seconds" — but a total of zero must still say
    /// something rather than falling silent.
    func testZeroComponentsAreDroppedButZeroTotalIsNot() {
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(3_600), "1 hour")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(3_660), "1 hour 1 minute")
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(0), "0 seconds")
    }

    func testSpokenFormNeverContainsClockPunctuation() {
        for seconds in [0, 1, 59, 61, 1_456, 3_661] {
            let spoken = MenuBarPresentation.spokenElapsed(TimeInterval(seconds))
            XCTAssertFalse(spoken.contains(":"), spoken)
            XCTAssertFalse(spoken.contains("00"), spoken)
        }
    }

    func testSpokenFormClampsNegativeIntervals() {
        XCTAssertEqual(MenuBarPresentation.spokenElapsed(-5), "0 seconds")
    }
}
