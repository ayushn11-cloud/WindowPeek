import SwiftUI

/// One tile in the preview strip. `image` is nil for minimized windows,
/// capture failures, or when Screen Recording permission is denied — the UI
/// renders a placeholder instead of dropping the window.
struct PreviewItem: Identifiable {
    let window: WindowInfo
    let image: NSImage?
    let appIcon: NSImage?

    var id: CGWindowID { window.windowID }
}

/// Horizontal strip of window thumbnails, styled as a natural extension of
/// the Dock: ultra-thin material, rounded corners, small titles, and an
/// obvious hover/selection ring.
///
/// This view is deliberately dumb: all system/API work happens before items
/// are handed over. It reports hover + click events back to the coordinator
/// (`AppDelegate` via `PreviewPanelController`).
struct PreviewView: View {
    static let thumbnailSize = CGSize(width: 220, height: 140)

    let items: [PreviewItem]
    var onHoverItem: ((CGWindowID?) -> Void)?
    var onSelect: ((WindowInfo) -> Void)?

    @State private var hoveredID: CGWindowID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items) { item in
                    PreviewTile(
                        item: item,
                        isHovered: hoveredID == item.id,
                        onHover: { hovering in
                            hoveredID = hovering ? item.id : nil
                            onHoverItem?(hovering ? item.id : nil)
                        },
                        onSelect: { onSelect?(item.window) }
                    )
                }
            }
            .padding(12)
        }
        .frame(maxWidth: 1024)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
    }
}

private struct PreviewTile: View {
    let item: PreviewItem
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                    .frame(
                        width: PreviewView.thumbnailSize.width,
                        height: PreviewView.thumbnailSize.height
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                isHovered ? .white.opacity(0.85) : .white.opacity(0.14),
                                lineWidth: isHovered ? 2.5 : 1
                            )
                    )
                    .shadow(
                        color: isHovered ? .white.opacity(0.18) : .clear,
                        radius: isHovered ? 10 : 0
                    )
                    .scaleEffect(isHovered ? 1.03 : 1.0)

                Text(item.window.displayTitle)
                    .font(.system(size: 11, weight: isHovered ? .semibold : .regular))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: PreviewView.thumbnailSize.width, alignment: .leading)
                    .help(item.window.displayTitle)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovered ? .white.opacity(0.14) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [.secondary.opacity(0.25), .secondary.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 6) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: item.window.isMinimized ? "rectangle.bottomthird.inset.filled" : "macwindow")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                if item.window.isMinimized {
                    Text("Minimized")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
