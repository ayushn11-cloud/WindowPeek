import Cocoa

/// Discovers regular (Dock-visible) running applications via `NSWorkspace`.
///
/// Kept separate from window enumeration so the Dock-hover layer can resolve
/// a hovered Dock item to a live `NSRunningApplication` without knowing about
/// Quartz window lists.
final class RunningApps {
    /// All currently running regular apps (those that appear in the Dock).
    /// WindowPeek itself is an agent (`LSUIElement`), so it never appears here.
    func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
    }

    /// The running app for a PID, if it is still alive.
    func app(forPID pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated
        else { return nil }
        return app
    }

    /// Best-effort match of a Dock item label (e.g. "Safari") to a running app.
    /// Dock labels are the app's display name, which usually equals
    /// `localizedName`. Matching is case-insensitive.
    func app(named name: String) -> NSRunningApplication? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return regularApps().first {
            $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }
}
