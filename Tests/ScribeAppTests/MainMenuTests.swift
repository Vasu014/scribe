import AppKit
import XCTest

/// `NSApp.mainMenu` (design 3b).
///
/// An `LSUIElement` app has no Dock icon but it DOES become the active app
/// whenever one of its windows is key, and while it is active the system draws
/// whatever `mainMenu` holds. Scribe held nothing, so every key equivalent its
/// own UI advertised was dead while a Scribe window was frontmost — and with
/// no Edit menu, **⌘V could not paste an API key** into Settings or the setup
/// wizard, which is a hard stop on first run.
///
/// These read the menu the app installs. What they cannot see is the
/// installation itself — see the suite's gap notes.
@MainActor
final class MainMenuTests: XCTestCase {

    private func makeMenu() -> (main: NSMenu, window: NSMenu) {
        ScribeApp.makeMainMenu(
            appName: "Scribe",
            settingsTarget: nil,
            settingsAction: NSSelectorFromString("openSettingsFromMainMenu")
        )
    }

    private func submenu(_ title: String) throws -> NSMenu {
        let menus = makeMenu().main.items.compactMap(\.submenu)
        return try XCTUnwrap(menus.first { $0.title == title }, "no \(title) menu; have \(menus.map(\.title))")
    }

    private func item(_ selector: String, in menu: NSMenu) throws -> NSMenuItem {
        let wanted = NSSelectorFromString(selector)
        return try XCTUnwrap(menu.items.first { $0.action == wanted }, "no \(selector) in \(menu.title)")
    }

    /// THE regression: ⌘V, with the standard responder-chain selector and a
    /// nil target so AppKit's automatic validation enables it exactly when the
    /// focused text view can service it.
    func testPasteIsReachableWithCommandV() throws {
        let paste = try item("paste:", in: try submenu("Edit"))
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.keyEquivalentModifierMask, .command)
        XCTAssertNil(paste.target, "a bound target would bypass the focused text view")
    }

    /// The rest of the Edit menu, with the same contract. Copy is how a
    /// transcript leaves History; Select All is how it is picked up first.
    func testEditMenuCarriesTheFullClipboardSet() throws {
        let edit = try submenu("Edit")
        let expected: [(String, String, NSEvent.ModifierFlags)] = [
            ("undo:", "z", .command),
            ("redo:", "z", [.command, .shift]),
            ("cut:", "x", .command),
            ("copy:", "c", .command),
            ("paste:", "v", .command),
            ("selectAll:", "a", .command),
        ]
        for (selector, key, modifiers) in expected {
            let found = try item(selector, in: edit)
            XCTAssertEqual(found.keyEquivalent, key, selector)
            XCTAssertEqual(found.keyEquivalentModifierMask, modifiers, selector)
            XCTAssertNil(found.target, selector)
        }
    }

    /// ⌘Z and ⇧⌘Z must not collide — a shared modifier mask makes one of them
    /// unreachable.
    func testUndoAndRedoAreDistinctShortcuts() throws {
        let edit = try submenu("Edit")
        let undo = try item("undo:", in: edit)
        let redo = try item("redo:", in: edit)
        XCTAssertNotEqual(undo.keyEquivalentModifierMask, redo.keyEquivalentModifierMask)
    }

    /// design 3b: "Every window closes with ⌘W".
    func testWindowMenuClosesAndMinimizes() throws {
        let window = try submenu("Window")
        let close = try item("performClose:", in: window)
        XCTAssertEqual(close.keyEquivalent, "w")
        XCTAssertEqual(close.keyEquivalentModifierMask, .command)
        XCTAssertNil(close.target)
        XCTAssertEqual(try item("performMiniaturize:", in: window).keyEquivalent, "m")
    }

    /// The Window submenu is returned separately because it is what
    /// `NSApp.windowsMenu` wants — every window registers itself there, and
    /// it is the only discovery path a VoiceOver user has to the scratchpad
    /// panel (review finding 27).
    func testTheReturnedWindowMenuIsTheOneInTheMenuBar() {
        let (main, window) = makeMenu()
        XCTAssertTrue(main.items.compactMap(\.submenu).contains { $0 === window })
    }

    /// Quit routes through the responder chain to
    /// `NSApplication.terminate` — which is what runs the quit-while-recording
    /// confirmation. A bound target would skip it.
    func testQuitIsCommandQAndUnbound() throws {
        let app = try submenu("Scribe")
        let quit = try item("terminate:", in: app)
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertNil(quit.target)
        XCTAssertTrue(quit.title.contains("Scribe"), quit.title)
    }

    /// ⌘, from the app menu, bound to the delegate — the same handler the
    /// status-item menu invokes, so both entry points behave identically.
    func testSettingsIsCommandCommaAndBoundToItsTarget() throws {
        let target = NSObject()
        let (main, _) = ScribeApp.makeMainMenu(
            appName: "Scribe",
            settingsTarget: target,
            settingsAction: NSSelectorFromString("openSettingsFromMainMenu")
        )
        let appMenu = try XCTUnwrap(main.items.compactMap(\.submenu).first { $0.title == "Scribe" })
        let settings = try item("openSettingsFromMainMenu", in: appMenu)
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertTrue(settings.target === target)
    }

    /// The app menu is drawn under the app's name, so the submenu title has
    /// to follow it — that title is what VoiceOver announces.
    func testTheAppMenuIsNamedForTheApp() {
        let (main, _) = ScribeApp.makeMainMenu(
            appName: "Renamed", settingsTarget: nil, settingsAction: NSSelectorFromString("noop")
        )
        XCTAssertEqual(main.items.first?.submenu?.title, "Renamed")
    }

    /// No shortcut may be claimed twice across the whole main menu — a
    /// duplicate silently disables one of the two.
    func testNoDuplicateKeyEquivalentsAcrossTheMainMenu() {
        var seen: Set<String> = []
        for submenu in makeMenu().main.items.compactMap(\.submenu) {
            for item in submenu.items where !item.keyEquivalent.isEmpty {
                let key = "\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
                XCTAssertTrue(seen.insert(key).inserted, "\(item.title) re-uses \(key)")
            }
        }
    }
}
