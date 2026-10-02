import Cocoa

/// Tiny in-memory thumbnail store with time-based expiry.
///
/// Hovering a Dock icon fires repeated show requests (hover moves between
/// icons, mouse jitter re-triggers). Without caching, every request would
/// re-capture every window — visibly slow and wasteful. The cache keeps
/// thumbnails for a few seconds so re-hovers feel instant, while expiry
/// guarantees live content is never stale for long.
///
/// Thread-safe via a lock; capture happens off the main thread.
final class ThumbnailCache {
    /// How long a thumbnail is considered fresh.
    var timeToLive: TimeInterval = 2.5

    private struct Entry {
        let image: NSImage
        let expiresAt: Date
    }

    private var store: [CGWindowID: Entry] = [:]
    private let lock = NSLock()

    /// Fresh cached image for `windowID`, or nil on miss/expiry.
    func image(for windowID: CGWindowID) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = store[windowID] else { return nil }
        guard entry.expiresAt > Date() else {
            store.removeValue(forKey: windowID)
            return nil
        }
        return entry.image
    }

    /// Split a batch of windows into cache hits and misses.
    func partition(_ windows: [WindowInfo]) -> (cached: [CGWindowID: NSImage], missing: [WindowInfo]) {
        var cached: [CGWindowID: NSImage] = [:]
        var missing: [WindowInfo] = []
        for window in windows {
            if let image = image(for: window.windowID) {
                cached[window.windowID] = image
            } else {
                missing.append(window)
            }
        }
        return (cached, missing)
    }

    func store(_ image: NSImage, for windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        store[windowID] = Entry(image: image, expiresAt: Date().addingTimeInterval(timeToLive))
    }

    func store(_ images: [CGWindowID: NSImage]) {
        for (id, image) in images { store(image, for: id) }
    }

    /// Drop thumbnails for windows that no longer exist (app closed windows).
    func invalidate(notIn liveIDs: Set<CGWindowID>) {
        lock.lock()
        defer { lock.unlock() }
        for id in store.keys where !liveIDs.contains(id) {
            store.removeValue(forKey: id)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.removeAll()
    }
}
