import Cocoa
import ApplicationServices

/// Which screen edge the Dock is attached to. Used to place the preview panel
/// on the correct side of the hovered icon, on the correct display.
enum DockEdge {
    case bottom
    case left
    case right
    case unknown
}

/// A single application tile in the Dock, in Cocoa screen coordinates.
struct DockAppItem {
    /// Display name as shown by the Dock (usually the app's localized name).
    let name: String
    /// Icon frame in Cocoa screen coordinates (origin bottom-left).
    let frame: CGRect
}

/// Detects which application tile the cursor is hovering in the macOS Dock.
///
/// How it works (and why this is isolated behind a protocol):
/// There is **no public API** for "the user is hovering Dock icon X". The
/// closest reliable native approach is:
/// 1. Read the Dock's own Accessibility hierarchy (`com.apple.dock` →
///    `AXList` → `AXDockItem`s with subrole `AXApplicationDockItem`) to learn
///    each app tile's label and frame.
/// 2. Track the global mouse position and hit-test it against those frames.
///
/// Everything Dock-specific lives here. If Apple ever ships a real Dock-hover
/// API — or a better heuristic emerges — only this file (plus its protocol)
/// needs to change. The rest of the app consumes `onHover` and
/// `itemFrame(for:)` and stays untouched.
///
/// Reliability notes:
/// - AX frames arrive in top-left-origin coordinates; they are converted to
///   Cocoa coordinates once, centrally, in `axRectToCocoa`.
/// - Tile frames are cached briefly (`tileCacheTTL`) so every mouse-moved
///   event is a cheap hit-test, not an IPC round-trip to the Dock.
/// - Requires Accessibility permission; without it `dockItems()` returns
///   empty and no hover events fire (the app surfaces this via `Permissions`).
/// - Dock auto-hide: while hidden the Dock reports off-screen/empty frames,
///   so no hover fires — correct behavior. When the user reveals the Dock at
///   a screen edge, the cache refresh picks up the new frames within ~0.5s.
protocol DockHoverDetecting: AnyObject {
    /// Called on the main thread whenever the hovered app changes.
    /// `nil` means the cursor left all app tiles.
    var onHover: ((NSRunningApplication?) -> Void)? { get set }

    /// Currently hovered app, if any.
    var hoveredApp: NSRunningApplication? { get }

    /// Last-known frame of the given app's Dock tile (for panel anchoring).
    func itemFrame(for app: NSRunningApplication) -> CGRect?

    /// Screen edge the Dock is currently attached to.
    func dockEdge() -> DockEdge

    func start()
    func stop()
}

final class DockObserver: DockHoverDetecting {
    var onHover: ((NSRunningApplication?) -> Void)?

    private(set) var hoveredApp: NSRunningApplication?

    /// Delay before a hover "commits", so sweeping across the Dock doesn't
    /// flash previews for every icon passed.
    var hoverDelay: TimeInterval = 0.22

    /// How long tile frames are cached before re-reading the Dock hierarchy.
    var tileCacheTTL: TimeInterval = 0.5

    /// How often the fallback timer re-checks (covers drags / missed events).
    private let pollInterval: TimeInterval = 1.0 / 30

    private let runningApps = RunningApps()
    private var eventMonitors: [Any] = []
    private var timer: Timer?

    private var cachedTiles: [DockAppItem] = []
    private var tilesFetchedAt: Date = .distantPast

    private var pendingApp: NSRunningApplication?
    private var pendingSince: Date = .distantPast

    private var lastFiredPID: pid_t?

    // MARK: - Lifecycle

    func start() {
        stop()
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.handleMouseMoved() }
        eventMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) as Any,
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
                handler(event); return event
            }) as Any,
        ].compactMap { $0 }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.handleMouseMoved()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Public queries

    /// PID of the Dock process, if it is running.
    private func dockPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        })?.processIdentifier
    }

    /// Frame of the Dock's floating app-name label near `point` (Cocoa
    /// coordinates), or nil when no label is visible.
    ///
    /// The label ("Safari", "Preview", …) is a small Dock-owned window that
    /// only exists while an icon is hovered. Finding its real frame lets the
    /// preview panel tuck down to cover it exactly, regardless of Dock size,
    /// magnification, or display scale. Returns nil when the label can't be
    /// found (e.g. a future macOS draws it inside the Dock window) — callers
    /// must fall back to anchor-based placement.
    func appNameLabelFrame(near point: CGPoint) -> CGRect? {
        guard let dockPID = dockPID(),
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }

        var best: (rect: CGRect, distance: CGFloat)?
        for entry in list {
            guard (entry[kCGWindowOwnerPID as String] as? Int) == Int(dockPID),
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = quartzDictToCocoa(boundsDict)
            else { continue }

            // A label is a small pill: clearly wider than tall, a few
            // thousand square points at most.
            let area = rect.width * rect.height
            guard area >= 800, area <= 40000,
                  rect.width >= rect.height * 1.5
            else { continue }

            // …floating just above the hovered icon.
            guard abs(rect.midX - point.x) < 180,
                  rect.minY > point.y - 40,
                  rect.minY < point.y + 180
            else { continue }

            let distance = hypot(rect.midX - point.x, rect.midY - point.y)
            if best == nil || distance < best!.distance {
                best = (rect, distance)
            }
        }
        return best?.rect
    }

    private func quartzDictToCocoa(_ dict: [String: Any]) -> CGRect? {
        guard let x = (dict["X"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              let y = (dict["Y"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              let w = (dict["Width"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              let h = (dict["Height"] as? NSNumber).map({ CGFloat($0.doubleValue) })
        else { return nil }
        return Self.axRectToCocoa(origin: CGPoint(x: x, y: y), size: CGSize(width: w, height: h))
    }

    func itemFrame(for app: NSRunningApplication) -> CGRect? {
        let tiles = dockTiles()
        guard let name = app.localizedName else { return nil }
        return tiles.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.frame
    }

    func dockEdge() -> DockEdge {
        let tiles = dockTiles()
        guard !tiles.isEmpty else { return .unknown }
        let union = tiles.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard let screen = screen(containing: union.center) else { return .bottom }
        let frame = screen.frame
        // The Dock hugs one edge: find which inset is smallest.
        let bottomGap = union.minY - frame.minY
        let leftGap = union.minX - frame.minX
        let rightGap = frame.maxX - union.maxX
        let topGap = frame.maxY - union.maxY
        let smallest = min(min(bottomGap, leftGap), min(rightGap, topGap))
        if smallest == bottomGap { return .bottom }
        if smallest == leftGap { return .left }
        if smallest == rightGap { return .right }
        return .unknown
    }

    // MARK: - Mouse handling

    private func handleMouseMoved() {
        guard Permissions.isAccessibilityTrusted() else {
            setHovered(nil)
            return
        }
        let mouse = NSEvent.mouseLocation
        let tiles = dockTiles()
        let hit = tiles.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(mouse) })

        guard let hit else {
            pendingApp = nil
            setHovered(nil)
            return
        }

        // Same tile as the committed hover: nothing to do.
        if let current = hoveredApp,
           current.localizedName?.caseInsensitiveCompare(hit.name) == .orderedSame {
            pendingApp = nil
            return
        }

        // New tile: debounce before committing.
        if pendingApp?.localizedName?.caseInsensitiveCompare(hit.name) != .orderedSame {
            pendingApp = runningApps.app(named: hit.name)
            // Unknown tile (separator? unresolvable name): treat as no hover.
            // Note: runningApps.app(named:) returns nil for non-apps, so
            // separators naturally fall through to the guard below.
            pendingSince = Date()
        }
        guard pendingApp != nil,
              Date().timeIntervalSince(pendingSince) >= hoverDelay
        else { return }

        setHovered(pendingApp)
        pendingApp = nil
    }

    private func setHovered(_ app: NSRunningApplication?) {
        let newPID = app?.processIdentifier
        if newPID == lastFiredPID { return }
        lastFiredPID = newPID
        hoveredApp = app
        onHover?(app)
    }

    // MARK: - Dock Accessibility inspection

    private func dockTiles() -> [DockAppItem] {
        if Date().timeIntervalSince(tilesFetchedAt) < tileCacheTTL {
            return cachedTiles
        }
        let tiles = readDockTiles()
        cachedTiles = tiles
        tilesFetchedAt = Date()
        return tiles
    }

    private func readDockTiles() -> [DockAppItem] {
        guard let dockPID = dockPID() else { return [] }

        let dockRef = AXUIElementCreateApplication(dockPID)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockRef, kAXChildrenAttribute as CFString, &childrenValue
        ) == .success, let children = childrenValue as? [AXUIElement] else {
            return []
        }

        // The Dock's children include an AXList whose children are the tiles.
        var items: [AXUIElement] = []
        for child in children {
            var roleValue: CFTypeRef?
            var listChildren: CFTypeRef?
            let role = (AXUIElementCopyAttributeValue(
                child, kAXRoleAttribute as CFString, &roleValue
            ) == .success) ? (roleValue as? String) : nil
            if role == "AXList",
               AXUIElementCopyAttributeValue(
                   child, kAXChildrenAttribute as CFString, &listChildren
               ) == .success, let listItems = listChildren as? [AXUIElement] {
                items.append(contentsOf: listItems)
            } else {
                items.append(child)
            }
        }

        return items.compactMap { element in
            // Only real application tiles — skips Trash, separators,
            // minimized-window icons, folders, and status items.
            var subroleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXSubroleAttribute as CFString, &subroleValue
            ) == .success,
                  let subrole = subroleValue as? String,
                  subrole == "AXApplicationDockItem"
            else { return nil }

            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXTitleAttribute as CFString, &titleValue
            ) == .success, let name = titleValue as? String, !name.isEmpty else {
                return nil
            }

            guard let axFrame = axFrame(of: element),
                  axFrame.width > 0, axFrame.height > 0
            else { return nil }

            return DockAppItem(name: name, frame: axFrame)
        }
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

        return Self.axRectToCocoa(origin: position, size: size)
    }

    /// Converts an Accessibility rect (top-left origin, primary display) to
    /// Cocoa screen coordinates (bottom-left origin). Both spaces span the
    /// same virtual desktop, mirrored around the primary display's height.
    static func axRectToCocoa(origin: CGPoint, size: CGSize) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: origin.x,
            y: mainHeight - origin.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
