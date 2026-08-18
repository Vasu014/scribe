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
/// `deinit`.
final class GlobalHotkey: @unchecked Sendable {

    /// Summon/dismiss the scratchpad panel. Set by the app; the panel itself
    /// lands in T6 — until then a press logs a no-op instead of crashing the
    /// closure contract.
    var onSummon: (() -> Void)?

    /// 'SCRB' — distinguishes our hotkey IDs from any other installer's.
    private static let signature: OSType = 0x53_43_52_42
    private static let summonID: UInt32 = 1

    private let logger = Logger(subsystem: "com.example.scribe", category: "hotkey")
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Registers ⌥⌘N by default (SPEC §5 default hotkey; user-remappable later).
    init(keyCode: UInt32 = UInt32(kVK_ANSI_N), modifiers: UInt32 = UInt32(cmdKey | optionKey)) {
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
            EventHotKeyID(signature: Self.signature, id: Self.summonID),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if installStatus != noErr || registerStatus != noErr {
            logger.error("Hotkey registration failed (install \(installStatus), register \(registerStatus)) — ⌥⌘N will not work this launch.")
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
        guard status == noErr, id.signature == signature, id.id == summonID else { return noErr }
        let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
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
            // TODO(T6): ScribeApp sets `onSummon` to the scratchpad panel
            // toggle. Logged as a no-op until then.
            logger.debug("⌥⌘N pressed but no summon handler is registered (scratchpad panel lands in T6).")
        }
    }
}
