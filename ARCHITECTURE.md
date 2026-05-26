# Architecture — AltTab (minimal)

A minimal, fast window-switcher for macOS. Zero dependencies. Zero background CPU. Instant activation.

## Goals

- Replace `Cmd+Tab` with a switcher that shows **window thumbnails** (not just app icons)
- Near-zero resource usage when idle (no polling, no background timers, no analytics)
- Single-binary, no external frameworks, no Sparkle, no ShortcutRecorder, no AppCenter
- ~800–1200 lines of Swift total

## Non-goals

- Settings UI / preferences window (hardcode sane defaults; tweak via `defaults write` if needed)
- Multiple shortcut configurations
- Search / filtering
- Drag-and-drop onto tiles
- Window close/minimize/fullscreen buttons in the overlay
- Tab grouping
- Space-aware filtering
- App exceptions / blocklists
- Auto-update
- Pro/license/paywall anything

---

## How the reference implementation (alt-tab-macos) works

The reference is ~27k lines across 162 Swift files. Here's the critical path:

### 1. Hotkey interception

- **Disable native Cmd+Tab**: Calls private SkyLight API `CGSSetSymbolicHotKeyEnabled` to suppress the system switcher for `commandTab`, `commandShiftTab`, and `commandKeyAboveTab`.
- **Register global hotkey**: Uses Carbon `RegisterEventHotKey` via `GetEventDispatcherTarget()` to listen for the Cmd+Tab keypress. This fires a "hotkey pressed" event.
- **Flag monitoring**: Installs a `CGEventTap` (at `.cghidEventTap` level) to watch `flagsChanged` events. This is how they detect when Cmd is **released** — which triggers window focus.
- **Local key monitor**: `NSEvent.addLocalMonitorForEvents` catches arrow keys, Tab repeats, Escape, etc. while the panel is open.

### 2. Window discovery

- Observes `NSWorkspace.shared.runningApplications` via KVO to track app launches/quits.
- For each app, creates an `AXObserver` and subscribes to accessibility notifications: `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXTitleChangedNotification`, etc.
- Maintains a `Windows.list: [Window]` sorted by `lastFocusOrder` (most recently focused first).
- Each `Window` tracks: `cgWindowId`, `axUiElement`, title, app icon, thumbnail, space IDs, fullscreen/minimized state.
- On every switcher trigger, calls `CGSCopySpacesForWindows` to refresh which space each window is on.

### 3. Thumbnail capture

- Uses `SCScreenshotManager.captureSampleBuffer` (macOS 14+) or the private `CGSHWCaptureWindowList` API (older macOS / macOS 15 workaround).
- Screenshots are taken on a background `OperationQueue` with concurrency 8.
- Captured as `CVPixelBuffer` or `CGImage`, stored as `CALayerContents` on each `Window`.
- Thumbnails are refreshed continuously in the background if `captureWindowsInBackground` is enabled, or on-demand when the switcher is shown.

### 4. Overlay UI

- `TilesPanel` — an `NSPanel` with `.nonactivatingPanel` style mask, `.popUpMenu` window level, `.canJoinAllSpaces` collection behavior. Borderless, transparent background.
- `TilesView` — contains an `NSVisualEffectView` (vibrancy blur) as background, an `NSScrollView` with a flip-view document, and a pool of 20 recycled `TileView` instances.
- `TileView` — each tile has a `LightImageLayer` for the thumbnail (CALayer-based), another for the app icon, an `NSTextField` for the title, and status icons.
- Layout is done manually (no Auto Layout) — iterates tiles, wraps rows when width exceeds screen percentage.
- The highlight (selected window) is drawn via a `CALayer` (`TileUnderLayer`) positioned behind the selected tile.

### 5. Activation flow (critical path)

```
User presses Cmd+Tab
  → Carbon hotkey fires → handleKeyboardEvent()
  → triggerMatchingShortcuts() → ShortcutActions.execute("nextWindowShortcut0")
  → App.showUiOrCycleSelection(0, false)
    → Creates SwitcherSession
    → Disables native Cmd+Tab via CGSSetSymbolicHotKeyEnabled
    → Windows.updatesBeforeShowing() — refresh spaces, filter, sort
    → Windows.setInitialSelectedAndHoveredWindowIndex() — select 2nd window (index 1)
    → App.buildUiAndShowPanel()
      → Appearance.update()
      → TilesPanel.updateContents() — layout tiles
      → TilesPanel.show() — makeKeyAndOrderFront
      → WindowThumbnails.refreshAsync() — capture screenshots
```

```
User presses Tab again (while holding Cmd)
  → Local key monitor or Carbon hotkey repeat
  → App.showUiOrCycleSelection() — now !isFirstSummon
  → Windows.cycleSelectedWindowIndex(1)
  → TilesView.highlight() — move highlight layer
```

```
User releases Cmd
  → CGEventTap receives flagsChanged with no Cmd
  → handleKeyboardEvent() → holdShortcut state flips to .up
  → ShortcutActions.execute("holdShortcut0") → App.focusTarget()
    → Windows.selectedWindow()?.focus()
    → App.hideUi()
    → _SLPSSetFrontProcessWithOptions + SLPSPostEventRecordTo (make window key)
    → AXUIElement.focusWindow()
```

### 6. Window focusing (private APIs)

The reference uses private SkyLight APIs for reliable window activation:
- `_SLPSSetFrontProcessWithOptions(&psn, windowId, .userGenerated)` — tells the window server to bring the process + specific window to front
- `SLPSPostEventRecordTo(&psn, &bytes)` — sends raw event bytes to make the window key (ported from Hammerspoon)
- Falls back to `AXUIElement.setAttribute(kAXFocusedWindowAttribute)` and `NSRunningApplication.activate()`

---

## Our minimal architecture

### System requirements

- macOS 13+ (Ventura) — we can use `SCScreenshotManager` for thumbnails, no need for the private `CGSHWCaptureWindowList` fallback
- Accessibility permission (required for AX window tracking)
- Screen Recording permission (required for window thumbnails)

### File structure

```
Sources/
  main.swift              — Entry point, NSApplication setup
  App.swift               — App delegate, lifecycle, permission checks
  Hotkey.swift            — CGEventTap + Carbon hotkey registration
  WindowManager.swift     — Window discovery via AX, maintains window list
  WindowInfo.swift        — Single window model (wid, title, icon, thumbnail, app)
  Thumbnail.swift         — SCScreenshotManager capture (on-demand only)
  OverlayPanel.swift      — NSPanel (the floating switcher window)
  OverlayView.swift       — Layout + drawing of window tiles
  TileView.swift          — Individual tile (thumbnail + icon + title)
  SkyLight.swift          — Private API declarations (CGS*, SLPs*, etc.)
  Permissions.swift       — AX + Screen Recording permission checks
```

~11 files. No `preferences/`, no `pro/`, no `vendors/`, no `events/` sprawl.

### Component design

#### Hotkey (Hotkey.swift)

Two mechanisms, both essential:

1. **Carbon `RegisterEventHotKey`** — Intercepts Cmd+Tab globally. Fires on keyDown. This is how we know the user wants to switch. We also call `CGSSetSymbolicHotKeyEnabled` to disable the native Cmd+Tab.

2. **`CGEventTap` on `.cghidEventTap`** — Monitors `flagsChanged` events to detect Cmd release. Also monitors `keyDown` for Tab repeats while the panel is open. Must be `.defaultTap` (not `.listenOnly`) so we can absorb events.

3. **`NSEvent.addLocalMonitorForEvents`** — Catches Tab presses, arrow keys, and Escape while the panel is focused. Returns `nil` to absorb handled events.

Flow:
```
Cmd+Tab down  → Carbon hotkey → show panel, select window[1]
Tab down      → local monitor → cycle selection forward
Shift+Tab     → local monitor → cycle selection backward
Escape        → local monitor → dismiss without switching
Cmd up        → CGEventTap flagsChanged → focus selected window, hide panel
```

#### WindowManager (WindowManager.swift + WindowInfo.swift)

Tracks all windows using the Accessibility API:

- On launch: enumerate `NSWorkspace.shared.runningApplications`, filter to those with `activationPolicy == .regular`
- For each app: create `AXUIElement(application: pid)`, query `kAXWindowsAttribute` to get windows
- Subscribe to `kAXWindowCreatedNotification` and `kAXUIElementDestroyedNotification` per-app via `AXObserverCreate` + `AXObserverAddNotification`
- Each window gets a `CGWindowID` via `_AXUIElementGetWindow()` (private but stable)

The window list is kept sorted by focus order. When an `kAXFocusedWindowChangedNotification` or `kAXApplicationActivatedNotification` fires, we move that window to index 0.

**We do NOT poll.** The AX observer callbacks keep the list in sync. Zero CPU when idle.

Minimal `WindowInfo`:
```swift
struct WindowInfo {
    let windowId: CGWindowID
    let axElement: AXUIElement
    let pid: pid_t
    var title: String
    var appName: String
    var appIcon: CGImage?
    var thumbnail: CGImage?  // captured on-demand only
    var lastFocusOrder: Int
}
```

#### Thumbnail capture (Thumbnail.swift)

- **On-demand only** — no background capture polling. Thumbnails are captured when the switcher is shown.
- Uses `SCScreenshotManager.captureSampleBuffer` with `SCContentFilter(desktopIndependentWindow:)`.
- Captures happen on a background queue, results dispatched to main thread.
- For minimized windows: `CGSHWCaptureWindowList` (private API) is the only option that works. We include this fallback.
- Thumbnail images are released when the panel is hidden.

#### Overlay (OverlayPanel.swift + OverlayView.swift + TileView.swift)

Panel configuration:
```swift
NSPanel(styleMask: .nonactivatingPanel)  // doesn't steal focus from current app
  .isFloatingPanel = true
  .level = .popUpMenu                    // above everything
  .collectionBehavior = .canJoinAllSpaces // works across spaces
  .backgroundColor = .clear
  .hasShadow = true
```

The content view is an `NSVisualEffectView` with `.hudWindow` material for the frosted-glass look.

Layout:
- Tiles arranged in a horizontal row (single row for ≤~8 windows, wrapping for more)
- Each tile: thumbnail image (CALayer), app icon (small, bottom-left corner), title text (NSTextField, single line, truncated)
- Selected tile has a rounded-rect highlight (accent color with alpha)
- Manual frame-based layout (no Auto Layout overhead)

#### Window focusing

When the user releases Cmd:
1. `hideUi()` — order out the panel
2. Look up the selected `WindowInfo`
3. `_SLPSSetFrontProcessWithOptions(&psn, windowId, .userGenerated)` — bring process to front
4. Send `SLPSPostEventRecordTo` key-window event bytes
5. `AXUIElement.performAction(kAXRaiseAction)` as fallback
6. Re-enable native Cmd+Tab via `CGSSetSymbolicHotKeyEnabled`

#### Permissions (Permissions.swift)

On launch:
1. Check `AXIsProcessTrustedWithOptions` — if not granted, show a simple `NSAlert` directing user to System Settings, then poll every 1s until granted.
2. Check `SCShareableContent.getExcludingDesktopWindows` — if it errors, prompt for Screen Recording permission similarly.
3. Once both are granted, proceed with `App.start()`.

No fancy permission window. Just alerts.

### Threading model

- **Main thread**: All UI (panel show/hide/layout), hotkey callbacks, AX observer callbacks, window list mutations
- **Background queue** (1 concurrent): Thumbnail capture only
- No timers. No polling. No background work when the panel is hidden.

### Memory model

- When panel is hidden: only the window list metadata in memory (~1KB per window). No thumbnails, no tile views.
- When panel is shown: thumbnails captured and held. Tile views created (recycled pool of ~20).
- When panel is hidden again: thumbnails released immediately.

### Build

Swift Package Manager, single target, no dependencies:

```
Package.swift
Sources/
  ...
```

The app needs an `Info.plist` (for the bundle identifier, accessibility usage description) and an entitlements file. We'll generate an `.app` bundle via a build script or Xcode project.

Actually — since we need a proper `.app` bundle with `Info.plist`, entitlements, and code signing, an **Xcode project** is the simplest path. SPM alone can't produce a signed macOS `.app` bundle with the right structure.

### Build approach

**Xcode project** (minimal):
- Single target: `AltTab.app`
- No storyboards, no XIBs, no asset catalogs (icon set from a PNG)
- `@main` entry point or `main.swift` with `NSApplication.shared.run()`
- Entitlements: `com.apple.security.app-sandbox = NO` (we need unsandboxed for CGEventTap + private APIs)

### What we're cutting vs the reference

| Reference (27k lines) | Ours (~1k lines) | Why |
|---|---|---|
| ShortcutRecorder framework | Hardcoded Cmd+Tab | Only one shortcut needed |
| Sparkle auto-updater | Nothing | Build from source |
| AppCenter crash reporting | Nothing | Check Console.app |
| 200+ preferences | 0 preferences | Sane defaults |
| Settings window (6 tabs) | Nothing | `defaults write` if needed |
| Pro licensing/paywall | Nothing | Lol |
| Day1-Day35 nag scheduler | Nothing | LOL |
| Search in switcher | Nothing | Not needed for <20 windows |
| Context menus on tiles | Nothing | Just switch |
| Drag-and-drop on tiles | Nothing | Just switch |
| Window close/min/fullscreen buttons | Nothing | Just switch |
| 20 event observer classes | 3 (AX, hotkey, CGEventTap) | We only need window lifecycle |
| Tab group detection | Nothing | Rare edge case |
| Space-aware filtering | Nothing | Show all windows |
| Preview panel (side preview) | Nothing | Thumbnail in tile is enough |
| VoiceOver support | Nothing | Future if needed |
| Multiple appearance styles | One (thumbnails) | The whole point |
| Background thumbnail capture | On-demand only | Zero idle CPU |
| Mission Control integration | Nothing | Don't need it |

### Estimated size

| File | Lines (est.) |
|---|---|
| main.swift | 20 |
| App.swift | 100 |
| Hotkey.swift | 120 |
| WindowManager.swift | 200 |
| WindowInfo.swift | 40 |
| Thumbnail.swift | 80 |
| OverlayPanel.swift | 60 |
| OverlayView.swift | 200 |
| TileView.swift | 120 |
| SkyLight.swift | 40 |
| Permissions.swift | 60 |
| **Total** | **~1040** |
