import Cocoa
import ApplicationServices

/// Central place for the two runtime permissions Window Peek depends on.
///
/// - **Accessibility**: required for Dock-item inspection (hover detection),
///   window titles, and exact-window activation. Without it the utility cannot
///   function; the UI degrades to an explanatory state instead of failing
///   silently.
/// - **Screen Recording**: required for per-window thumbnails. Without it we
///   still show the preview strip with titles + app-icon placeholders, and
///   clicking still switches windows.
///
/// Everything stays on-device; no permission here involves the network.
enum Permissions {
    // MARK: - Accessibility

    /// True when the app is in the Accessibility allow-list right now.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt (once — macOS suppresses repeats) and returns
    /// the current trust state. Call from the main thread, sparingly.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    /// True when window capture is currently allowed.
    static func isScreenRecordingGranted() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    /// Shows the Screen Recording consent prompt if needed. Returns the
    /// pre-prompt state; if it returns false the user must grant access in
    /// System Settings and the app must be relaunched for capture to work.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        if #available(macOS 11.0, *) {
            return CGRequestScreenCaptureAccess()
        }
        return true
    }

    // MARK: - System Settings deep links

    static func openAccessibilitySettings() {
        openSettingsPane("Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        openSettingsPane("Privacy_ScreenCapture")
    }

    private static func openSettingsPane(_ pane: String) {
        // Works on macOS 13+ (Ventura) through current releases.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
