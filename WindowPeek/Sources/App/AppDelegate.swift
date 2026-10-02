import Cocoa

/// Coordinates the whole V1 flow: Dock hover → window discovery → thumbnails
/// → floating preview → click-to-activate → dismiss.
///
/// The coordinator owns no system-API details itself; it delegates to the
/// focused collaborators (`DockObserver`, `WindowDiscovery`,
/// `WindowMetadata`, `ThumbnailCapture`/`ThumbnailCache`, `WindowActivation`,
/// `PreviewPanelController`) and only sequences them, on demand — nothing is
/// polled and no thumbnails are captured until a hover commits.
///
/// Dismiss rule: the panel stays while the cursor is over the hovered Dock
/// tile *or* over the panel itself (plus a short grace period so moving
/// between the two doesn't flicker). Otherwise it fades out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockObserver = DockObserver()
    private let discovery = WindowDiscovery()
    private let metadata = WindowMetadata()
    private let thumbnails = ThumbnailCapture()
    private let thumbnailCache = ThumbnailCache()
    private let activation = WindowActivation()
    private let panelController = PreviewPanelController()
    private let permissionsWindow = PermissionsWindowController()

    private var currentApp: NSRunningApplication?
    private var currentAnchor = CGRect.zero
    private var hoverTask: Task<Void, Never>?
    private var lastInsideZones = Date()
    private var dismissTimer: Timer?
    private var screenRecordingPrompted = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility is required for Dock inspection and Screen Recording
        // for thumbnails. Rather than firing bare system prompts at launch,
        // show the friendly permissions window while anything is missing.
        // The menu-bar extra can reopen it anytime.
        if !Permissions.isAccessibilityTrusted() || !Permissions.isScreenRecordingGranted() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.showPermissionsWindow()
            }
        }

        panelController.onSelect = { [weak self] window in
            self?.handleSelect(window)
        }
        panelController.onPreviewHover = { [weak self] _ in
            // Any movement across tiles keeps the panel alive.
            self?.lastInsideZones = Date()
        }

        dockObserver.onHover = { [weak self] app in
            self?.handleHover(app)
        }
        dockObserver.start()
        startDismissTracking()
        observeWorkspaceChanges()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockObserver.stop()
        dismissTimer?.invalidate()
        hoverTask?.cancel()
    }

    // MARK: - Permissions window

    /// Opens the first-run permissions window (also available from the
    /// menu-bar extra).
    @MainActor
    func showPermissionsWindow() {
        permissionsWindow.show()
    }

    // MARK: - Hover → preview

    private func handleHover(_ app: NSRunningApplication?) {
        hoverTask?.cancel()
        hoverTask = nil

        guard let app, !app.isTerminated else {
            // Cursor left the Dock tiles; the dismiss timer will fade the
            // panel once the grace period elapses (lets the user travel from
            // the icon up into the panel).
            currentApp = nil
            return
        }

        // Same app re-reported (e.g. tile cache refresh): keep showing.
        if app.processIdentifier == currentApp?.processIdentifier,
           panelController.isVisible {
            lastInsideZones = Date()
            return
        }

        currentApp = app
        lastInsideZones = Date()

        guard let anchor = dockObserver.itemFrame(for: app) else { return }
        currentAnchor = anchor

        hoverTask = Task { [weak self] in
            await self?.showPreviews(for: app, anchor: anchor)
        }
    }

    private func showPreviews(for app: NSRunningApplication, anchor: CGRect) async {
        // Bail early for common dead ends before spending on captures.
        guard !app.isTerminated else { return }

        var windows = discovery.windows(forPID: app.processIdentifier)
        guard !Task.isCancelled else { return }
        // No usable windows → show nothing (per spec).
        guard !windows.isEmpty else {
            hidePanel()
            return
        }

        windows = metadata.enrich(windows)
        guard !Task.isCancelled else { return }

        // App may have quit mid-flight; never show a stale panel.
        guard let liveApp = NSRunningApplication(processIdentifier: app.processIdentifier),
              !liveApp.isTerminated
        else { return }

        // Screen Recording consent, asked once, at the moment we first need it.
        if !screenRecordingPrompted {
            screenRecordingPrompted = true
            if !Permissions.isScreenRecordingGranted() {
                Permissions.requestScreenRecording()
            }
        }

        let (cached, missing) = thumbnailCache.partition(windows)
        var images = cached
        if !missing.isEmpty {
            let fresh = await thumbnails.captureThumbnails(for: missing)
            guard !Task.isCancelled else { return }
            thumbnailCache.store(fresh)
            for (id, image) in fresh { images[id] = image }
        }
        thumbnailCache.invalidate(notIn: Set(windows.map(\.windowID)))

        // Still hovering the same app? Otherwise this result is stale.
        guard !Task.isCancelled,
              currentApp?.processIdentifier == app.processIdentifier
        else { return }

        let appIcon = liveApp.icon
        let items = windows.map { window in
            PreviewItem(window: window, image: images[window.windowID], appIcon: appIcon)
        }
        let edge = dockObserver.dockEdge()
        let anchorNow = dockObserver.itemFrame(for: liveApp) ?? anchor
        currentAnchor = anchorNow
        // Look up the Dock's app-name label while the hover is live so the
        // panel can tuck down over it.
        let labelFrame = dockObserver.appNameLabelFrame(near: CGPoint(
            x: anchorNow.midX,
            y: anchorNow.maxY
        ))

        await MainActor.run {
            // Re-check: a dismiss may have been requested while capturing.
            guard self.currentApp?.processIdentifier == app.processIdentifier else { return }
            self.lastInsideZones = Date()
            self.panelController.show(
                items: items,
                anchor: anchorNow,
                edge: edge,
                labelFrame: labelFrame
            )
        }
    }

    // MARK: - Selection

    private func handleSelect(_ window: WindowInfo) {
        activation.activate(window)
        currentApp = nil
        hidePanel()
    }

    /// Hide the panel from any thread; the actual AppKit call hops to main.
    private func hidePanel(animated: Bool = true) {
        Task { @MainActor in
            self.panelController.hide(animated: animated)
        }
    }

    // MARK: - Dismiss tracking

    private func startDismissTracking() {
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkDismiss()
        }
        if let dismissTimer {
            RunLoop.main.add(dismissTimer, forMode: .common)
        }
    }

    private func checkDismiss() {
        guard panelController.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let inPanel = panelController.panelFrame.insetBy(dx: -6, dy: -6).contains(mouse)
        let inAnchor = currentAnchor.insetBy(dx: -10, dy: -10).contains(mouse)
        let stillOnSameIcon = currentApp != nil
            && dockObserver.hoveredApp?.processIdentifier == currentApp?.processIdentifier
        if inPanel || inAnchor || stillOnSameIcon {
            lastInsideZones = Date()
            return
        }
        // Cursor is over neither zone: hide after the grace period.
        if Date().timeIntervalSince(lastInsideZones) > 0.35 {
            currentApp = nil
            hidePanel()
        }
    }

    // MARK: - Workspace changes

    private func observeWorkspaceChanges() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        if app.processIdentifier == currentApp?.processIdentifier {
            currentApp = nil
            hoverTask?.cancel()
            hidePanel(animated: false)
        }
        thumbnailCache.clear()
    }

    @objc private func handleSpaceChanged(_ note: Notification) {
        // Window frames/visibility change across Spaces; drop the panel and
        // let the next hover rebuild it.
        currentApp = nil
        hoverTask?.cancel()
        hidePanel(animated: false)
    }
}
