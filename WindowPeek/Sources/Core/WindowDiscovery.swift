import Cocoa
import ApplicationServices

/// Enumerates the windows of a single application using Quartz Window Services
/// (`CGWindowListCopyWindowInfo`).
///
/// Design notes:
/// - Only "usable" windows are returned: layer 0 (normal document windows),
///   non-transparent, with a non-trivial size. Menu-bar extras, tooltips,
///   the Dock itself, and other chrome are filtered out.
/// - Results preserve front-to-back z-order so the preview strip matches what
///   the user sees on screen.
/// - Minimized windows are *not* in the on-screen list. They are appended at
///   the end (marked `isOnScreen == false`); `WindowMetadata` later refines
///   the minimized flag via Accessibility. Their thumbnails cannot be
///   captured, so the UI renders a placeholder tile for them.
/// - The caller is expected to exclude WindowPeek itself; as a safety net we
///   also filter out our own PID here.
final class WindowDiscovery {
    /// Maximum windows returned per app. Keeps the preview strip manageable
    /// for apps like Safari with dozens of windows (the UI scrolls).
    var maxWindows = 20

    /// Windows smaller than this are treated as popovers/tooltips, not documents.
    private let minSize = CGSize(width: 80, height: 60)

    /// Returns the usable windows of `pid`, front-to-back.
    func windows(forPID pid: pid_t) -> [WindowInfo] {
        guard pid != getpid() else { return [] }

        guard let onScreenList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        // Full list (ordered arbitrarily) so we can also find minimized /
        // off-screen windows belonging to the app.
        let allList = (CGWindowListCopyWindowInfo(
            CGWindowListOption(rawValue: 0),
            kCGNullWindowID
        ) as? [[String: Any]]) ?? []

        let app = NSRunningApplication(processIdentifier: pid)
        let bundleID = app?.bundleIdentifier
        let appName = app?.localizedName ?? ""

        var onScreenIDs = Set<CGWindowID>()
        var ordered: [WindowInfo] = []
        ordered.reserveCapacity(16)

        // Pass 1: visible windows, in z-order.
        for entry in onScreenList {
            guard let info = makeWindowInfo(
                from: entry,
                ownerPID: pid,
                ownerName: appName,
                bundleID: bundleID,
                isOnScreen: true
            ) else { continue }
            onScreenIDs.insert(info.windowID)
            ordered.append(info)
            if ordered.count >= maxWindows { return ordered }
        }

        // Pass 2: remaining windows of this app (minimized, on other Spaces).
        // These have no live pixels to capture; the UI shows a placeholder.
        for entry in allList {
            if ordered.count >= maxWindows { break }
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  !onScreenIDs.contains(CGWindowID(number))
            else { continue }
            guard let info = makeWindowInfo(
                from: entry,
                ownerPID: pid,
                ownerName: appName,
                bundleID: bundleID,
                isOnScreen: false
            ) else { continue }
            onScreenIDs.insert(info.windowID)
            ordered.append(info)
        }

        return ordered
    }

    // MARK: - Private

    private func makeWindowInfo(
        from entry: [String: Any],
        ownerPID pid: pid_t,
        ownerName: String,
        bundleID: String?,
        isOnScreen: Bool
    ) -> WindowInfo? {
        guard let owner = entry[kCGWindowOwnerPID as String] as? Int,
              owner == Int(pid)
        else { return nil }

        // Only normal windows. Higher layers are menu bar, Dock, tooltips, etc.
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { return nil }

        // Fully transparent entries (shadows, animation artifacts) are useless.
        if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 {
            return nil
        }

        guard let number = entry[kCGWindowNumber as String] as? Int else { return nil }

        // Bounds come in Quartz coordinates (origin top-left); convert to Cocoa.
        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              var bounds = Self.cocoaRect(from: boundsDict)
        else { return nil }

        // Round sub-pixel jitter so AX matching is stable.
        bounds = bounds.integral
        guard bounds.width >= minSize.width, bounds.height >= minSize.height else {
            return nil
        }

        let title = (entry[kCGWindowName as String] as? String) ?? ""
        let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ownerName

        return WindowInfo(
            windowID: CGWindowID(number),
            ownerPID: pid,
            ownerName: ownerName,
            bundleID: bundleID,
            title: title,
            bounds: bounds,
            isMinimized: false, // refined by WindowMetadata via Accessibility
            isOnScreen: isOnScreen
        )
    }

    /// Converts a Quartz `kCGWindowBounds` dictionary (top-left origin) to
    /// Cocoa screen coordinates (bottom-left origin of the primary display).
    static func cocoaRect(from dict: [String: Any]) -> CGRect? {
        guard let x = cgFloat(dict["X"]),
              let y = cgFloat(dict["Y"]),
              let w = cgFloat(dict["Width"]),
              let h = cgFloat(dict["Height"])
        else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // Quartz y grows downward from the top of the primary display;
        // Cocoa y grows upward from the bottom.
        return CGRect(x: x, y: mainHeight - y - h, width: w, height: h)
    }

    /// Quartz window dictionaries bridge numbers as `NSNumber`; accept any
    /// numeric representation.
    private static func cgFloat(_ value: Any?) -> CGFloat? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        if let double = value as? Double { return CGFloat(double) }
        return nil
    }
}
