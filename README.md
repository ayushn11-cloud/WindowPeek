# Window Peek

A small, native macOS utility. Hover over an app's Dock icon to see previews
of its open windows — then click one to switch to it.

> Hover Dock icon → see windows → click one.

No dashboard, no settings screens, no accounts, no cloud, no analytics.
Everything stays on your Mac.

## How it works

1. You hover an application tile in the Dock.
2. Window Peek resolves the hovered tile to a running app.
3. It enumerates that app's windows and captures a thumbnail **per window**.
4. A floating panel appears above/near the Dock with one tile per window:
   thumbnail + title.
5. Hovering tiles highlights them; clicking one brings that exact window
   to the front.
6. Moving the cursor away from the icon and the panel dismisses it.

Single-window apps show a one-tile preview. Apps with no usable windows show
nothing.

## Permissions

Two macOS permissions, both standard for this kind of utility:

| Permission | Used for | Without it |
|---|---|---|
| **Accessibility** | Reading Dock tile positions, window titles, raising the exact window | Hover detection can't work; the app stays idle |
| **Screen Recording** | Per-window thumbnails | Titles + app-icon placeholders still show; clicking still switches windows |

You are prompted on first run by a small permissions window (also available
anytime from the menu-bar extra → Show Permissions…), which deep-links to the
right System Settings panes and shows live status. Grant them in
System Settings → Privacy & Security. Window Peek never collects, uploads,
or transmits window contents — there is no networking code at all.

## Build & run

Requirements: Xcode 16+, macOS 14.0+ SDK, running on macOS 14.0+.

```sh
open WindowPeek.xcodeproj
# ⌘R, or:
xcodebuild -project WindowPeek.xcodeproj -scheme WindowPeek -configuration Release build
```

The app is an agent (`LSUIElement`): no Dock icon, no main window. It lives
in the menu bar (permissions status + Quit) and in the Dock-hover panel.

## Architecture

```
WindowPeek/Sources/
├── App/
│   ├── WindowPeekApp.swift        # @main, MenuBarExtra only
│   ├── AppDelegate.swift          # coordinator: hover → discover → capture → show → activate → dismiss
│   └── MenuExtraView.swift        # minimal status view (permissions + Quit)
├── Core/
│   ├── Models/WindowInfo.swift    # plain value type; views never touch system APIs
│   ├── RunningApps.swift          # NSWorkspace discovery
│   ├── WindowDiscovery.swift      # CGWindowList enumeration (layer/size filtered, z-ordered)
│   ├── WindowMetadata.swift       # Accessibility title/minimized enrichment
│   ├── ThumbnailCapture.swift     # ScreenCaptureKit primary, Quartz fallback — per-window only
│   ├── ThumbnailCache.swift       # brief TTL cache so re-hovers feel instant
│   ├── WindowActivation.swift     # AX raise + app activate, with graceful fallback
│   └── Permissions.swift          # Accessibility + Screen Recording checks/prompts
├── Dock/
│   └── DockObserver.swift         # hover detection + Dock label lookup (see below)
└── UI/
    ├── PreviewPanelController.swift # borderless non-activating NSPanel, placement + animation
    ├── PreviewView.swift            # SwiftUI thumbnail strip
    ├── PermissionsView.swift        # first-run permissions window content
    └── PermissionsWindowController.swift # hosts the permissions window
```

The app icon lives in `Sources/Assets.xcassets/AppIcon.appiconset/`
(three window cards, middle one selected — drawn from the app's own UI).

System APIs live in `Core/` and `Dock/` only — never in SwiftUI views.

### Dock-hover detection (the honest part)

There is **no public API** for "the cursor is hovering Dock icon X". The
closest reliable native approach, isolated behind the `DockHoverDetecting`
protocol in `Dock/DockObserver.swift`:

1. Read the Dock's Accessibility hierarchy (`com.apple.dock` → `AXList` →
   `AXDockItem`s with subrole `AXApplicationDockItem`) for each app tile's
   label and frame.
2. Hit-test the global mouse position against those frames (cached ~0.5s,
   debounced ~0.22s so sweeping the Dock doesn't flash previews).

If Apple ever ships a real Dock-hover API, only that file needs to change.

### Thumbnails

- Primary: `SCScreenshotManager.captureImage` with an
  `SCContentFilter(desktopIndependentWindow:)` — captures exactly one window.
- Fallback: `CGWindowListCreateImage(..., .optionIncludingWindow, windowID, ...)`
  — likewise restricted to one window.
- Never a full-screen screenshot. Captures happen **only on hover**, batched
  per hover with one shared `SCShareableContent` lookup, and cached ~2.5s.

### Edge cases (V1 stance)

Handled: single-window apps, minimized windows (placeholder tile, click
de-minimizes), apps with no windows (show nothing), permission denied
(graceful placeholders/idle), app quitting or Space switching while visible
(panel hides), multiple displays + left/right/bottom Dock (panel anchors to
the tile's screen and edge), Dock auto-hide (no hover while hidden).

Known limits: AX↔Quartz window matching is fuzzy (title + geometry — no
public `CGWindowID` ↔ `AXUIElement` mapping exists); very large window counts
are capped at 20 with horizontal scrolling. Both are structured to improve
later without reshaping the app.

## Signing & distribution

The project builds ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`) so anyone can
build and run locally. For distribution (Developer ID + notarization), set
your Team in Xcode and sign normally — no code changes needed.

## License

MIT. See [LICENSE](LICENSE).
