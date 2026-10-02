import Cocoa
import ScreenCaptureKit

/// Captures per-window thumbnail images.
///
/// Two backends, preferred first:
/// 1. **ScreenCaptureKit**: `SCScreenshotManager` captures a single
///    desktop-independent window. This is the modern, supported path and never
///    touches other windows' pixels.
/// 2. **Quartz fallback**: `CGWindowListCreateImage` with
///    `.optionIncludingWindow` captures only the requested window. It is
///    deprecated but still functional, so it stays as the fallback when
///    ScreenCaptureKit throws (e.g. permissions in flux).
///
/// Important: we never screenshot the whole screen and crop. Every capture
/// targets exactly one window ID.
///
/// Capture is the most expensive step, so callers should go through
/// `captureThumbnails(for:)` (one shared `SCShareableContent` lookup per
/// hover) and front it with `ThumbnailCache`.
final class ThumbnailCapture {
    /// Longest pixel edge of a produced thumbnail. Keeps captures cheap and
    /// the preview strip lightweight.
    var maxPixelWidth: CGFloat = 440

    /// Capture thumbnails for a batch of windows concurrently.
    /// Returns only the windows that produced an image (minimized/off-screen
    /// windows and capture failures are simply absent).
    func captureThumbnails(for windows: [WindowInfo]) async -> [CGWindowID: NSImage] {
        let visible = windows.filter { $0.isOnScreen && !$0.isMinimized }
        guard !visible.isEmpty else { return [:] }

        if let viaKit = await captureBatchWithScreenCaptureKit(visible),
           !viaKit.isEmpty {
            return viaKit
        }
        return await captureBatchWithQuartz(visible)
    }

    /// Convenience single-window capture.
    func capture(window: WindowInfo) async -> NSImage? {
        await captureThumbnails(for: [window])[window.windowID]
    }

    // MARK: - ScreenCaptureKit

    private enum CaptureError: Error {
        case noContent
        case noImage
    }

    private func captureBatchWithScreenCaptureKit(
        _ windows: [WindowInfo]
    ) async -> [CGWindowID: NSImage]? {
        // One content lookup per hover — not per window.
        guard let content = try? await Self.shareableContentOnScreenOnly() else {
            return nil
        }

        var scWindows: [CGWindowID: SCWindow] = [:]
        for scWindow in content.windows {
            // `SCWindow.windowID` is the same Quartz window number used by
            // `CGWindowList`, so the two enumerations join directly.
            scWindows[CGWindowID(scWindow.windowID)] = scWindow
        }

        var results: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in windows {
                guard let scWindow = scWindows[window.windowID] else { continue }
                group.addTask {
                    let image = try? await Self.captureOneWithScreenshotManager(
                        scWindow: scWindow,
                        sourceBounds: window.bounds,
                        maxPixelWidth: self.maxPixelWidth
                    )
                    return (window.windowID, image)
                }
            }
            for await (id, image) in group {
                if let image { results[id] = image }
            }
        }
        return results
    }

    private static func shareableContentOnScreenOnly() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            ) { content, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: CaptureError.noContent)
                }
            }
        }
    }

    private static func captureOneWithScreenshotManager(
        scWindow: SCWindow,
        sourceBounds: CGRect,
        maxPixelWidth: CGFloat
    ) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let aspect: CGFloat = sourceBounds.height > 0
            ? sourceBounds.width / sourceBounds.height : 16 / 10
        let width = Int(min(max(sourceBounds.width, 64), maxPixelWidth))
        let height = max(Int(CGFloat(width) / max(aspect, 0.2)), 1)
        config.width = width
        config.height = height
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.capturesAudio = false

        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.noImage)
                }
            }
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Quartz fallback

    private func captureBatchWithQuartz(
        _ windows: [WindowInfo]
    ) async -> [CGWindowID: NSImage] {
        var results: [CGWindowID: NSImage] = [:]
        await withTaskGroup(of: (CGWindowID, NSImage?).self) { group in
            for window in windows {
                group.addTask {
                    (window.windowID, Self.captureOneWithQuartz(
                        windowID: window.windowID,
                        maxPixelWidth: self.maxPixelWidth
                    ))
                }
            }
            for await (id, image) in group {
                if let image { results[id] = image }
            }
        }
        return results
    }

    /// Single-window capture via Quartz. `.optionIncludingWindow` restricts
    /// the image to exactly `windowID` — this is not a screen crop.
    private static func captureOneWithQuartz(
        windowID: CGWindowID,
        maxPixelWidth: CGFloat
    ) -> NSImage? {
        // Deprecated in favor of ScreenCaptureKit, kept as the fallback for
        // macOS 14 where SCScreenshotManager is unavailable.
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }

        let sourceWidth = CGFloat(cgImage.width)
        let sourceHeight = CGFloat(cgImage.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, maxPixelWidth / sourceWidth)
        let target = NSSize(
            width: max(1, sourceWidth * scale),
            height: max(1, sourceHeight * scale)
        )
        let image = NSImage(cgImage: cgImage, size: target)
        image.isTemplate = false
        return image
    }
}
