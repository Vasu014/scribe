import Carbon.HIToolbox
import Foundation
import os

/// System-wide ⌥⌘N hotkey via Carbon `RegisterEventHotKey` (SPEC §5: the only
/// true global-shortcut API on macOS — no Accessibility permission, and
/// explicitly NOT `NSEvent.addGlobalMonitorForEvents`, which is read-only and
/// requires the app to be focused).
///
/// The Carbon callback may fire on any thread; it hops to the main queue
/// before invoking `onSummon`. Create and release on the main thread (Carbon
/// event-target installation is main-thread-only); unregistration happens in
/// `deinit`, so an instance's lifetime IS the registration's lifetime.
///
/// EVERY registration here is a system-wide grab: the key stops reaching the
/// front app for as long as the instance lives. That is the point for ⌥⌘N (a
/// modified chord no other app owns), and it is why the panel's Esc-to-dismiss
/// is NOT implemented here — see `ScratchpadPanelController.dismiss()`. Only
/// register modified chords, and only for the app's lifetime.
final class GlobalHotkey: @unchecked Sendable {

    /// Which shortcut an instance owns. Each kind carries its own Carbon
    /// hotkey id: every installed handler on the application event target
    /// sees EVERY hotkey press, so the id is what keeps two live instances
    /// from firing each other's closures.
    enum Kind: UInt32 {
        /// ⌥⌘N — summon/dismiss the scratchpad (SPEC §5). App-lifetime.
        case summon = 1
    }

    /// Fired on the main queue when the shortcut is pressed. Set by the app;
    /// a press with no handler logs a no-op instead of crashing the closure
    /// contract.
    var onSummon: (() -> Void)?

    /// 'SCRB' — distinguishes our hotkey IDs from any other installer's.
    private static let signature: OSType = 0x53_43_52_42

    private let kind: Kind
    private let logger = Logger(subsystem: "io.github.vasu014.scribe", category: "hotkey")
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers ⌥⌘N by default (SPEC §5 default hotkey; user-remappable later).
    init(
        keyCode: UInt32 = UInt32(kVK_ANSI_N),
        modifiers: UInt32 = UInt32(cmdKey | optionKey),
        kind: Kind = .summon
    ) {
        self.kind = kind
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Stored properties all have values (defaults) before `self` is used
        // here; the callback hops through the main queue, so it cannot run
        // before this init returns.
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                GlobalHotkey.handle(event: event, userData: userData)
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: kind.rawValue),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        logger.info("""
        Registered global hotkey \(String(describing: kind), privacy: .public) — keyCode \(keyCode), \
        modifiers \(modifiers). That combination is consumed system-wide for this instance's lifetime.
        """)
        if installStatus != noErr || registerStatus != noErr {
            logger.error("""
            Hotkey registration failed for \(String(describing: kind), privacy: .public) \
            (install \(installStatus), register \(registerStatus)) — that shortcut will not work.
            """)
        }
    }

    deinit {
        // Must run on the main thread (see class docs); the app owns the
        // hotkey for its entire lifetime, so this is release-time on main.
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// @convention(c) trampoline — no captures; `self` arrives via userData.
    private static func handle(event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
        guard let event, let userData else { return noErr }
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &id
        )
        guard status == noErr, id.signature == signature else { return noErr }
        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
        // Every installed handler receives every hotkey press; only the
        // instance that registered THIS id may act on it.
        guard id.id == hotkey.kind.rawValue else { return noErr }
        DispatchQueue.main.async {
            hotkey.fire()
        }
        return noErr
    }

    /// Main-queue delivery.
    private func fire() {
        if let onSummon {
            onSummon()
        } else {
            logger.debug("\(String(describing: self.kind), privacy: .public) hotkey pressed with no handler registered — ignored.")
        }
    }
}
