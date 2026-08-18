import AppKit
import SessionKit

/// Scribe — menu bar app (thin shell, SPEC §3.1).
///
/// This entry point is deliberately minimal: the UI surfaces
/// (MenuBarController, ScratchpadPanel, HistoryWindow, SetupWizard) are
/// built out in TASKS.md tasks T4–T6 and land in App/ as they arrive.
/// All domain logic lives in Packages/MeetingKitCore.
@main
final class ScribeApp: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Placeholder bootstrap: keep the process alive as a background
        // (LSUIElement) app with no windows. Replaced by MenuBarController.
    }
}
