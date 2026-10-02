import Cocoa

/// Describes a single on-screen (or minimized) window belonging to a running app.
///
/// `WindowInfo` is a plain value type on purpose: system APIs (`CGWindowList`,
/// Accessibility) are read in the Core layer and translated here, so SwiftUI
/// views never touch system APIs directly.
struct WindowInfo: Identifiable, Hashable {
    /// Quartz window number (`kCGWindowNumber`). Stable while the window lives.
    let windowID: CGWindowID
    /// PID of the owning process (`kCGWindowOwnerPID`).
    let ownerPID: pid_t
    /// Human-readable app name, e.g. "Safari".
    let ownerName: String
    /// Owning app's bundle identifier, if known.
    let bundleID: String?
    /// Best-known window title. May be empty when neither Quartz nor
    /// Accessibility exposes one (handled by `WindowMetadata`).
    let title: String
    /// Window frame in Cocoa screen coordinates (origin bottom-left).
    let bounds: CGRect
    /// True when Accessibility reports the window as minimized / demoted to the Dock.
    let isMinimized: Bool
    /// True when the window appeared in the on-screen window list.
    let isOnScreen: Bool

    var id: CGWindowID { windowID }

    /// Title safe to display in the UI. Falls back to the app name so a
    /// preview never shows a blank label.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ownerName : trimmed
    }
}
