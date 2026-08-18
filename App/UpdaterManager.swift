import AppKit
import Combine
import Sparkle

/// Sparkle 2 auto-update wrapper (SPEC §6: Sparkle 2, appcast feed; T9).
///
/// Follows the macos-auto-update skill pattern:
/// - `SPUStandardUpdaterController` is created early — `ScribeApp` holds
///   `UpdaterManager.shared` as a stored property, so the controller exists
///   before `applicationDidFinishLaunching` returns (Sparkle's requirement) —
///   with `startingUpdater: false`; `start()` is called explicitly at launch.
/// - DEBUG builds never start the updater nor answer manual checks: a debug
///   build must never be "updated" with a release build.
/// - `ObservableObject` + `@Published` (not `@Observable`) because
///   `canCheckForUpdates` bridges from Sparkle's KVO via Combine.
///
/// Feed URL + Ed25519 public key live in Info.plist (`SUFeedURL` /
/// `SUPublicEDKey`), substituted at build time from the `SUFEED_URL` /
/// `SUPUBLIC_ED_KEY` build settings — placeholders in project.yml, real
/// values injected by scripts/release.sh (see scripts/README.md).
@MainActor
final class UpdaterManager: NSObject, ObservableObject {

    static let shared = UpdaterManager()

    private let controller: SPUStandardUpdaterController

    /// True once the updater is started and idle — drives the menu-bar
    /// item's enablement. Never becomes true in DEBUG (the updater never
    /// starts there).
    @Published var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    private override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Begins the automatic update schedule. Called from
    /// `applicationDidFinishLaunching`. No-op in DEBUG.
    func start() {
        #if DEBUG
        return
        #else
        controller.startUpdater()
        #endif
    }

    /// Manual check (menu-bar "Check for Updates…"). Scribe is an accessory
    /// app (LSUIElement), so temporarily switch to `.regular` or Sparkle's
    /// update window cannot come forward and take keyboard focus.
    func checkForUpdates() {
        #if DEBUG
        return
        #else
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        // TODO(signing week, SPEC §6 "Sparkle update tested"): revert to
        // .accessory when the update window closes (needs a Sparkle
        // window-close observation / user-driver delegate). Unexercised
        // until release builds ship.
        #endif
    }
}
