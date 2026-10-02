import Cocoa
import ApplicationServices

/// Enriches `WindowInfo` values with Accessibility data.
///
/// Quartz (`CGWindowList`) is fast and sufficient for geometry, but titles are
/// often missing (Finder is the classic case: most Finder windows have an
/// empty `kCGWindowName`). Accessibility exposes the real titles plus the
/// minimized state, so we merge the two sources here.
///
/// Matching strategy: for each `WindowInfo` we pick the AX window with the
/// closest frame (center distance + size similarity). This is fuzzy by design
/// — there is no public API mapping a `CGWindowID` to an `AXUIElement` — but
/// in practice title + geometry disambiguates correctly, and a wrong title is
/// merely cosmetic (activation uses the same scoring plus an app-level
/// fallback, see `WindowActivation`).
final class WindowMetadata {
    /// Fill in missing titles and minimized flags. Never removes windows.
    func enrich(_ windows: [WindowInfo]) -> [WindowInfo] {
        guard !windows.isEmpty else { return windows }
        // Group by PID so we query each app's AX hierarchy at most once.
        let byPID = Dictionary(grouping: windows) { $0.ownerPID }
        var result: [WindowInfo] = []
        result.reserveCapacity(windows.count)
        for (pid, group) in byPID {
            let axWindows = axWindows(forPID: pid)
            for window in group {
                result.append(enrich(window, using: axWindows))
            }
        }
        // Preserve the caller's (z-)order.
        let indexByID = Dictionary(
            uniqueKeysWithValues: windows.enumerated().map { ($1.windowID, $0) }
        )
        return result.sorted {
            (indexByID[$0.windowID] ?? Int.max) < (indexByID[$1.windowID] ?? Int.max)
        }
    }

    // MARK: - Private

    private struct AXWindow {
        let element: AXUIElement
        let title: String
        let frame: CGRect
        let minimized: Bool
    }

    private func enrich(_ window: WindowInfo, using candidates: [AXWindow]) -> WindowInfo {
        guard let match = bestMatch(for: window, in: candidates) else { return window }
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? match.title : window.title
        return WindowInfo(
            windowID: window.windowID,
            ownerPID: window.ownerPID,
            ownerName: window.ownerName,
            bundleID: window.bundleID,
            title: title,
            bounds: window.bounds,
            isMinimized: match.minimized,
            isOnScreen: window.isOnScreen
        )
    }

    /// Closest AX window by geometry. Requires meaningful overlap or
    /// proximity; returns nil when nothing plausibly corresponds.
    private func bestMatch(for window: WindowInfo, in candidates: [AXWindow]) -> AXWindow? {
        var best: AXWindow?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for candidate in candidates {
            let score = geometryDistance(window.bounds, candidate.frame)
            if score < bestScore {
                bestScore = score
                best = candidate
            }
        }
        // Reject matches that are nowhere near the Quartz frame (different
        // Spaces, stale AX entries). 250pt tolerance is generous on purpose.
        guard let match = best, bestScore < 250 else { return nil }
        return match
    }

    private func geometryDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let centerA = CGPoint(x: a.midX, y: a.midY)
        let centerB = CGPoint(x: b.midX, y: b.midY)
        let centerDistance = hypot(centerA.x - centerB.x, centerA.y - centerB.y)
        let sizePenalty = abs(a.width - b.width) / 4 + abs(a.height - b.height) / 4
        // Overlapping frames are strongly preferred.
        let overlapBonus: CGFloat = a.intersects(b) ? -100 : 0
        return centerDistance + sizePenalty + overlapBonus
    }

    private func axWindows(forPID pid: pid_t) -> [AXWindow] {
        let appRef = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &value
        ) == .success, let elements = value as? [AXUIElement] else {
            return []
        }
        return elements.compactMap { element in
            let title = (try? axString(element, attribute: kAXTitleAttribute)) ?? ""
            let minimized = (try? axBool(element, attribute: kAXMinimizedAttribute)) ?? false
            guard let frame = axFrame(of: element) else { return nil }
            return AXWindow(
                element: element,
                title: title,
                frame: frame,
                minimized: minimized
            )
        }
    }

    private enum AXReadError: Error { case failed }

    private func axString(_ element: AXUIElement, attribute: String) throws -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String
        else { throw AXReadError.failed }
        return string
    }

    private func axBool(_ element: AXUIElement, attribute: String) throws -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            throw AXReadError.failed
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        throw AXReadError.failed
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posAX = posValue, let sizeAX = sizeValue
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        let posOK = AXValueGetValue(posAX as! AXValue, .cgPoint, &position)
        let sizeOK = AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        guard posOK, sizeOK, size.width > 0, size.height > 0 else { return nil }

        // AX positions use top-left origin; convert to Cocoa coordinates.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: position.x,
            y: mainHeight - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
