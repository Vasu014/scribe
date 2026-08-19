import AppKit
import XCTest

/// The scratchpad's primary input path (SPEC §4.3).
///
/// `NSTextView(frame:textContainer:)` with a `nil` container leaves the view
/// with NO text system at all: `textContainer`, `layoutManager` and
/// `textStorage` all stay nil, assignments to `string` are silently dropped,
/// and nothing typed can reach the composer or the screen. The app's main
/// input surface shipped that way and had never worked.
@MainActor
final class ScratchpadTextStackTests: XCTestCase {

    func testBodyTextViewBuildsACompleteTextKitStack() {
        let view = BodyTextView()
        XCTAssertNotNil(view.textContainer, "no text container — keystrokes have nowhere to lay out")
        XCTAssertNotNil(view.layoutManager)
        XCTAssertNotNil(view.textStorage)
        XCTAssertTrue(view.textContainer?.widthTracksTextView == true, "the body must wrap to the panel width")
    }

    /// The assertion that actually catches the defect: text set on the view
    /// has to arrive in the storage the composer and the renderer read.
    func testTextAssignedToTheViewReachesTheStorage() {
        let view = BodyTextView()
        view.string = "budget freeze until Q1"
        XCTAssertEqual(view.string, "budget freeze until Q1")
        XCTAssertEqual(view.textStorage?.string, "budget freeze until Q1")
    }

    /// The keystroke path proper — `insertText` is what a typed character
    /// goes through, and it is a no-op on a view with no text system.
    func testInsertedTextAccumulatesLikeTyping() {
        let view = BodyTextView()
        view.isEditable = true
        for character in "hire" {
            view.insertText(String(character), replacementRange: NSRange(location: view.string.count, length: 0))
        }
        XCTAssertEqual(view.string, "hire")
        XCTAssertEqual(view.textStorage?.string, "hire")
    }

    /// A control for the two tests above: this is the initializer the app used
    /// to call, and it is still exactly as broken. If this ever starts
    /// passing, AppKit changed and the custom initializer can be revisited —
    /// but until then it documents why the initializer exists.
    func testTheNilContainerInitializerIsStillTheDefectItAlwaysWas() {
        let broken = NSTextView(frame: .zero, textContainer: nil)
        XCTAssertNil(broken.textContainer)
        broken.string = "this goes nowhere"
        XCTAssertNotEqual(broken.string, "this goes nowhere")
    }

    /// The hand-drawn placeholder is invisible to VoiceOver unless it is also
    /// published as the accessibility placeholder (UX review finding 11).
    func testPlaceholderIsPublishedToAccessibility() {
        let view = BodyTextView()
        view.placeholderText = "Jot a thought…"
        XCTAssertEqual(view.accessibilityPlaceholderValue() as? String, "Jot a thought…")
    }
}
