import Cocoa
import SwiftUI

/// Owns the standalone permissions window (see `PermissionsView`).
///
/// A plain centered `NSWindow` — deliberately not an alert or a settings
/// screen. Shown automatically on launch while any permission is missing,
/// and on demand from the menu-bar extra.
final class PermissionsWindowController {
    private var window: NSWindow?

    /// Show the window, creating it on first use. Safe to call repeatedly.
    @MainActor
    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: PermissionsView())
            let fresh = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            fresh.title = "Window Peek"
            fresh.contentView = hosting
            // Let the SwiftUI content decide the height; keep a fixed width
            // so text wraps predictably.
            let fittingHeight = max(hosting.fittingSize.height, 400)
            fresh.setContentSize(NSSize(width: 460, height: fittingHeight))
            fresh.center()
            fresh.isReleasedWhenClosed = false
            window = fresh
        }
        // Agent apps (`LSUIElement`) don't activate on their own — without
        // this the window would open behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
