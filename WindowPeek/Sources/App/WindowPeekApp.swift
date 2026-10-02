import SwiftUI

/// Window Peek entry point.
///
/// The app is an agent (`LSUIElement`): no Dock icon, no main window. Its only
/// visible surfaces are the hover preview panel and a minimal menu-bar extra
/// (status + permissions + quit). All behaviour lives in `AppDelegate`.
@main
struct WindowPeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Window Peek", systemImage: "rectangle.on.rectangle") {
            MenuExtraView()
        }
    }
}
