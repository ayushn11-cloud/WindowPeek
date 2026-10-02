import SwiftUI

/// Content of the menu-bar extra. Compact by design: live permission status,
/// a shortcut to the full permissions window, and Quit. The detailed
/// explanations live in `PermissionsView`, not here.
struct MenuExtraView: View {
    @State private var accessibilityGranted = Permissions.isAccessibilityTrusted()
    @State private var screenRecordingGranted = Permissions.isScreenRecordingGranted()

    private var everythingGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    var body: some View {
        Section {
            Label {
                Text("Window Peek")
                    .fontWeight(.semibold)
            } icon: {
                Image(systemName: "rectangle.on.rectangle")
            }
            Text("Hover a Dock icon to preview its windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Permissions") {
            statusRow(
                title: "Accessibility",
                granted: accessibilityGranted
            )
            statusRow(
                title: "Screen Recording",
                granted: screenRecordingGranted
            )
            if !everythingGranted {
                Button("Show Permissions…") {
                    showPermissionsWindow()
                }
            }
        }

        Divider()

        Text("Runs locally. No accounts, no analytics.")
            .font(.caption)
            .foregroundStyle(.secondary)

        Button("Quit Window Peek") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func statusRow(title: String, granted: Bool) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(granted ? "On" : "Off")
                    .foregroundStyle(granted ? .green : .orange)
            }
        } icon: {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    private func showPermissionsWindow() {
        Task { @MainActor in
            (NSApplication.shared.delegate as? AppDelegate)?.showPermissionsWindow()
        }
    }
}
