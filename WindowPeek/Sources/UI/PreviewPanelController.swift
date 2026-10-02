import Cocoa
import SwiftUI

/// Floating, borderless panel that hosts the SwiftUI preview strip.
///
/// Window configuration (the important bits):
/// - `nonactivatingPanel` + `popUpMenu` level: floats above the Dock without
///   stealing focus from the app being previewed.
/// - `canJoinAllSpaces` + `stationary`: follows the user across Spaces.
/// - Transparent background with shadow; the SwiftUI content draws its own
///   material + rounded corners.
///
/// Positioned relative to the hovered Dock tile (`anchor`, in Cocoa screen
/// coordinates) on the opposite side of the Dock edge, clamped to the
/// visible frame of the screen containing the anchor. Handles bottom/left/
/// right Dock placements and multiple displays.
///
/// Appearance/disappearance is a short fade + slide so it feels attached to
/// the Dock rather than popping in.
final class PreviewPanelController {
    /// Called when the user clicks a preview. The coordinator activates the
    /// window and hides the panel.
    var onSelect: ((WindowInfo) -> Void)?

    /// Called when the cursor moves within/between preview tiles. The
    /// coordinator uses this to extend the dismiss grace period.
    var onPreviewHover: ((CGWindowID?) -> Void)?

    private var panel: NSPanel?
    private var hostingView: NSHostingView<PreviewView>?

    var isVisible: Bool { panel?.isVisible == true }

    /// Panel frame in Cocoa screen coordinates (for dismiss hit-testing).
    var panelFrame: CGRect { panel?.frame ?? .zero }

    /// Show (or refresh) the preview strip for already-resolved items.
    /// `labelFrame` is the Dock's app-name label (Cocoa coordinates), if
    /// visible — the panel tucks down to cover it. Nil falls back to the
    /// anchor icon frame with a small overlap.
    @MainActor
    func show(
        items: [PreviewItem],
        anchor: CGRect,
        edge: DockEdge,
        labelFrame: CGRect? = nil
    ) {
        guard !items.isEmpty else {
            hide(animated: true)
            return
        }

        let panel = ensurePanel()
        let view = PreviewView(
            items: items,
            onHoverItem: { [weak self] id in self?.onPreviewHover?(id) },
            onSelect: { [weak self] window in self?.onSelect?(window) }
        )
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hosted = NSHostingView(rootView: view)
            // Fill the panel and follow its resizes; the panel frame is
            // sized explicitly in `position(panel:size:anchor:edge:)`.
            panel.contentView = hosted
            hosted.frame = panel.contentView?.bounds ?? hosted.frame
            hosted.autoresizingMask = [.width, .height]
            hostingView = hosted
        }

        let size = fittingSize(forItemCount: items.count)
        position(panel: panel, size: size, anchor: anchor, edge: edge, labelFrame: labelFrame)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Hide the panel. `animated: false` for teardown / Space changes where
    /// the panel must vanish immediately.
    @MainActor
    func hide(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
            })
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Private

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let fresh = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        fresh.level = .popUpMenu
        fresh.backgroundColor = .clear
        fresh.isOpaque = false
        // No AppKit window shadow: it follows the square window frame and
        // shows as a hard outline past the rounded corners. The SwiftUI
        // content draws its own shadow on the rounded shape instead.
        fresh.hasShadow = false
        fresh.hidesOnDeactivate = false
        fresh.ignoresMouseEvents = false
        fresh.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        fresh.isMovable = false
        fresh.isMovableByWindowBackground = false
        self.panel = fresh
        return fresh
    }

    private func fittingSize(forItemCount count: Int) -> CGSize {
        // Tile: 220pt thumbnail + 12pt tile padding; 12pt inter-tile spacing;
        // 24pt strip padding. Height: 140 thumbnail + 6 spacing + ~16 title +
        // 12 tile padding + 24 strip padding.
        let tileWidth: CGFloat = PreviewView.thumbnailSize.width + 12
        let stripWidth = CGFloat(count) * tileWidth + CGFloat(max(count - 1, 0)) * 12 + 24
        let width = min(max(stripWidth, 200), 1048)
        let height: CGFloat = PreviewView.thumbnailSize.height + 6 + 16 + 12 + 24
        return CGSize(width: width, height: height)
    }

    private func position(
        panel: NSPanel,
        size: CGSize,
        anchor: CGRect,
        edge: DockEdge,
        labelFrame: CGRect?
    ) {
        let screen = screen(containing: anchor.center)
        let visible = screen.visibleFrame
        // The Dock draws its own app-name label just outside the hovered icon
        // and there is no public API (or defaults key) to hide it, so the
        // panel sits low and covers it. The panel's level (.popUpMenu) paints
        // above Dock-level windows.
        let sideGap: CGFloat = 12

        var origin: CGPoint
        switch edge {
        case .left:
            // Side-Dock labels appear beside the icon; a vertically centered
            // strip naturally overlaps and covers them.
            origin = CGPoint(
                x: anchor.maxX + sideGap,
                y: anchor.midY - size.height / 2
            )
        case .right:
            origin = CGPoint(
                x: anchor.minX - size.width - sideGap,
                y: anchor.midY - size.height / 2
            )
        case .bottom, .unknown:
            // Tuck the strip's bottom edge to the label's bottom edge so the
            // pill stays hidden without the panel eating into the icon. A few
            // points higher shows the label; lower overlaps the icon — this
            // is the balance. Fallback overlaps the AX icon frame (which can
            // sit a little above the visible icon).
            let coverLine = (labelFrame?.minY ?? (anchor.maxY - 10)) + 3
            origin = CGPoint(
                x: anchor.midX - size.width / 2,
                y: coverLine
            )
        }

        // Clamp to the visible frame so the strip never runs off-screen
        // (edge icons, small displays, notch area). On very short screens
        // this may lift the panel above the label — staying on-screen wins.
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
