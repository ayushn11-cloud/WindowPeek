import Cocoa
import ApplicationServices

/// Brings a specific window to the front.
///
/// Strategy (best effort, in order):
/// 1. Find the owning app; bail if it is gone.
/// 2. If the window is minimized, de-miniaturize it via Accessibility
///    (`kAXMinimizedAttribute = false`) so it has somewhere to appear.
/// 3. Raise the exact AX window that best matches the target
///    (`kAXRaiseAction` + make main). Matching reuses the same fuzzy
///    title/geometry scoring as `WindowMetadata` — there is no public
///    `CGWindowID` ↔ `AXUIElement` mapping, so this is documented as
///    approximate in the same way.
/// 4. Activate the app. This last step alone is the graceful fallback when
///    Accessibility is denied: the app comes forward even if we cannot
///    guarantee *which* of its windows lands on top.
final class WindowActivation {
    /// Activate `window`. Returns false only when the owning app is gone.
    @discardableResult
    func activate(_ window: WindowInfo) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.ownerPID),
              !app.isTerminated
        else { return false }

        raiseExactWindow(matching: window)
        app.activate(options: [.activateIgnoringOtherApps])
        return true
    }

    // MARK: - Private

    private func raiseExactWindow(matching target: WindowInfo) {
        let appRef = AXUIElementCreateApplication(target.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXWindowsAttribute as CFString, &value
        ) == .success, let elements = value as? [AXUIElement], !elements.isEmpty else {
            return
        }

        guard let best = elements.min(by: {
            score($0, target: target) < score($1, target: target)
        }) else { return }

        // De-minimize first so hidden windows can be raised.
        if target.isMinimized {
            AXUIElementSetAttributeValue(
                best, kAXMinimizedAttribute as CFString, kCFBooleanFalse
            )
        }
        AXUIElementPerformAction(best, kAXRaiseAction as CFString)
        // Best effort: also mark main so keyboard focus follows the click.
        AXUIElementSetAttributeValue(best, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Lower is better. Title match dominates; geometry breaks ties.
    private func score(_ element: AXUIElement, target: WindowInfo) -> CGFloat {
        var total: CGFloat = 0

        var titleValue: CFTypeRef?
        let title: String
        if AXUIElementCopyAttributeValue(
            element, kAXTitleAttribute as CFString, &titleValue
        ) == .success, let string = titleValue as? String {
            title = string
        } else {
            title = ""
        }

        let wanted = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wanted.isEmpty, title == wanted {
            total -= 1000
        } else if !wanted.isEmpty, title.localizedCaseInsensitiveContains(wanted)
            || wanted.localizedCaseInsensitiveContains(title), !title.isEmpty {
            total -= 200
        }

        if let frame = axFrame(of: element) {
            total += Self.centerDistance(frame, target.bounds)
        } else {
            total += 500
        }
        return total
    }

    private static func centerDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &posValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                  element, kAXSizeAttribute as CFString, &sizeValue
              ) == .success,
              let posAX = posValue, let sizeAX = sizeValue
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posAX as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeAX as! AXValue, .cgSize, &size)
        else { return nil }

        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: position.x,
            y: mainHeight - position.y - size.height,
            width: size.width,
            height: size.height
        )
    }
}
