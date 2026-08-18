import AVFAudio
import CoreGraphics
import Foundation

/// Microphone TCC status (SPEC §4.1 permissions & first-run flow).
/// macOS distinguishes all three states for the mic.
public enum MicrophonePermissionStatus: String, Sendable {
    case undetermined
    case granted
    case denied
}

/// Screen Recording TCC status. CoreGraphics exposes only a boolean
/// preflight, so `denied` covers both "never asked" and "explicitly denied" —
/// the distinction is unobservable without actually prompting. Either way a
/// grant takes effect only after an app relaunch (SPEC §4.1), which the
/// SetupWizard (App/, T8) owns; nothing here shows UI.
public enum ScreenRecordingPermissionStatus: String, Sendable {
    case granted
    case denied
}

/// Pure-ish permission queries + async request wrappers (no UI, no engine).
/// The engine and the SetupWizard both read these; keeping them in CaptureKit
/// means TCC state is observable from tests and headless tooling.
public enum CapturePermissions {

    /// Current microphone permission. Read-only — call
    /// `requestMicrophone()` to prompt when `undetermined`.
    public static var microphone: MicrophonePermissionStatus {
        // AVAudioApplication is macOS 14+ — exactly the SPEC §6 baseline,
        // so no availability guard is needed (target = macOS 14.0).
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .denied
        }
    }

    /// Current Screen Recording permission (CGPreflightScreenCaptureAccess —
    /// synchronous, no prompt, safe from any thread).
    public static var screenRecording: ScreenRecordingPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Prompts on first call (macOS mic TCC alert); resolves immediately when
    /// permission is already determined. A grant is effective at once — no
    /// relaunch needed for the microphone.
    @discardableResult
    public static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Surfaces the Screen Recording TCC prompt if permission is
    /// undetermined. Returns the CURRENT grant state — even if the user
    /// grants in the dialog, capture only works after relaunch (SPEC §4.1),
    /// so treat a `false` return as "degrade now, capture next session".
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
