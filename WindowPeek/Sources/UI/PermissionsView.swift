import Combine
import SwiftUI

/// First-run / publish-ready permissions window.
///
/// Window Peek is useless without Accessibility and half-useful without
/// Screen Recording, so instead of failing silently (or firing bare system
/// prompts at launch) we show one clean window: what the app does, which
/// permissions it needs and why, live status, and one-click actions.
/// Reopened anytime from the menu-bar extra.
struct PermissionsView: View {
    @State private var accessibilityGranted = Permissions.isAccessibilityTrusted()
    @State private var screenRecordingGranted = Permissions.isScreenRecordingGranted()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)

            Text("Window Peek shows an app's open windows when you hover its Dock icon, and switches to the one you click. It needs two macOS permissions to do that.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            permissionRow(
                icon: "person.crop.circle.badge.checkmark",
                title: "Accessibility",
                detail: "See Dock icons and window titles, raise the exact window you click.",
                granted: accessibilityGranted,
                actionLabel: "Enable…",
                action: {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                    refresh()
                }
            )

            Divider().padding(.vertical, 10)

            permissionRow(
                icon: "rectangle.on.rectangle",
                title: "Screen Recording",
                detail: "Capture per-window thumbnails. Without it you still get titles, but no previews.",
                granted: screenRecordingGranted,
                actionLabel: "Enable…",
                action: {
                    Permissions.requestScreenRecording()
                    Permissions.openScreenRecordingSettings()
                    refresh()
                }
            )

            if !screenRecordingGranted {
                Text("Note: after enabling Screen Recording, quit and reopen Window Peek for it to take effect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            Spacer(minLength: 12)

            Text("Everything runs on this Mac. Window Peek has no network code — nothing is uploaded or tracked.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            HStack {
                Button("Quit Window Peek") {
                    NSApplication.shared.terminate(nil)
                }
                Spacer()
                Button("Done") {
                    closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onReceive(
            Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
        ) { _ in refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("Window Peek")
                    .font(.system(size: 17, weight: .semibold))
                Text("Preview Dock apps' windows on hover")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 52, height: 52)
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    statusPill(granted: granted)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                Button(actionLabel, action: action)
                    .padding(.top, 2)
            }
        }
    }

    private func statusPill(granted: Bool) -> some View {
        Text(granted ? "On" : "Needed")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    (granted ? Color.green : Color.orange).opacity(0.15)
                )
            )
            .foregroundStyle(granted ? .green : .orange)
    }

    // MARK: - Helpers

    private func refresh() {
        accessibilityGranted = Permissions.isAccessibilityTrusted()
        screenRecordingGranted = Permissions.isScreenRecordingGranted()
    }

    private func closeWindow() {
        NSApplication.shared.keyWindow?.close()
    }
}
