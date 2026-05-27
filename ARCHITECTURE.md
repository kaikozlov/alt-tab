# Architecture — AltTab (minimal)

A minimal, fast window-switcher for macOS. Zero dependencies. Zero continuous idle work. Instant activation.

## Goals

- Replace `Cmd+Tab` with a switcher that shows **window thumbnails** (not just app icons)
- Near-zero resource usage when idle (no polling, no background timers, bounded event-driven thumbnail refreshes)
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

- macOS 14+ (Sonoma) — `SCScreenshotManager.captureSampleBuffer` for thumbnails, with `CGSHWCaptureWindowList` private API fallback
- Accessibility permission (required for AX window tracking)
- Screen Recording permission (required for window thumbnails)

### File structure

```
AltTab/Sources/
  Core/
    main.swift, App.swift, Permissions.swift, SwitcherSession.swift, Throttler.swift
  Hotkey/
    Hotkey.swift, SkyLight.swift
  Windows/
    WindowInfo.swift, WindowManager*.swift, AXHelpers.swift, LifecycleReconciler.swift
  Overlay/
    OverlayPanel.swift, OverlayView.swift, TileLayout.swift, TileView.swift, Thumbnail.swift
```

Feature folders group files that change together while keeping each Swift file under ~200 lines.

### Component design

#### Hotkey (Hotkey.swift)

Two mechanisms, both essential:

1. **Carbon `RegisterEventHotKey`** — Intercepts Cmd+Tab globally. Fires on keyDown. This is how we know the user wants to switch. We also call `CGSSetSymbolicHotKeyEnabled` to disable the native Cmd+Tab.

2. **`CGEventTap` on `.cghidEventTap`** — Monitors `flagsChanged` events to detect Cmd release. Also monitors `keyDown` for Tab repeats while the panel is open. Must be `.defaultTap` (not `.listenOnly`) so we can absorb events.

3. **`NSEvent.addLocalMonitorForEvents`** — Catches Tab presses, arrow keys, and Escape while the panel is focused. Returns `nil` to absorb handled events.

Flow:
```
Cmd+Tab down (panel closed) → Carbon hotkey → show panel, select window[1]
Cmd+Tab down (panel open)   → Carbon hotkey → cycle selection forward
Shift+Cmd+Tab               → Carbon hotkey → cycle selection backward
Tab down                    → local monitor → cycle selection forward
Shift+Tab                   → local monitor → cycle selection backward
Left/Right arrow            → local monitor → cycle selection backward/forward
Escape                      → local monitor → dismiss without switching
Cmd+Q                       → local monitor → quit selected app (force-quit on repeat)
Cmd+W                       → local monitor → close selected window
Cmd up                      → CGEventTap flagsChanged → focus selected window, hide panel
```

#### Window tracking (Windows/)

Tracks all windows using the Accessibility API:

- On launch: observe `NSWorkspace.shared.runningApplications` via KVO for app launch/quit
- For each `.regular` activation policy app: create `AXUIElement(application: pid)`, query `kAXWindowsAttribute` to get windows
- Non-regular apps are observed for `activationPolicy` changes — tracked automatically when they switch to `.regular`
- Subscribe per-app via `AXObserverCreate` + `AXObserverAddNotification` to: `kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXFocusedWindowChangedNotification`, `kAXMainWindowChangedNotification`, `kAXApplicationActivatedNotification`, `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`
- Each window gets a `CGWindowID` via `_AXUIElementGetWindow()` (private but stable)

The window list is kept sorted by focus order. When an `kAXFocusedWindowChangedNotification` or `kAXApplicationActivatedNotification` fires, we move that window to index 0.

**We do NOT poll.** The AX observer callbacks keep the list in sync. Zero CPU when idle.

Minimal `WindowInfo`:
```swift
class WindowInfo {
    let windowId: CGWindowID
    let axElement: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleId: String?
    var title: String
    var appIcon: NSImage?
    var thumbnail: CGImage?
    var contentSize: CGSize?
    var lastFocusOrder: Int
    var isMinimized: Bool
}
```

#### Thumbnail capture (Thumbnail.swift)

- **Event-driven cache** — thumbnails are retained for instant summon and refreshed only on startup, window lifecycle changes, or when leaving a focused window.
- Uses `SCScreenshotManager.captureSampleBuffer` with `SCContentFilter(desktopIndependentWindow:)`.
- Captures happen on a background queue, results dispatched to main thread.
- For minimized windows: `CGSHWCaptureWindowList` (private API) is the only option that works. We include this fallback.
- Showing the switcher uses cached thumbnails immediately and captures missing tiles asynchronously, prioritizing the selection and its neighbors.

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

#### Live panel refresh (Throttler + mergeSwitcherWindows)

While the panel is open, AX observer callbacks may fire (windows created/destroyed, titles changed, focus shifted).
`WindowManager.onChange` triggers `Throttler.throttleOrProceed` (200ms) which calls `refreshSwitcherPanel()`.
This re-queries `sortedWindows()`, merges with the current switcher list preserving order and selection,
then re-layouts the panel and refreshes thumbnails. This keeps the overlay in sync with reality without
rapid re-layouts from bursty AX events.

#### Status bar item

A minimal `NSStatusItem` in the menu bar with the system symbol `rectangle.3.group`.
Its dropdown menu has "About AltTab" (disabled placeholder) and "Quit".

#### Window management shortcuts

While the panel is open:
- **Cmd+Q** — terminates the selected window's app. Pressing Cmd+Q again within the same session
  force-terminates via `forceTerminate()`. Finder is protected with a beep.
- **Cmd+W** — presses the window's close button via AX (`kAXCloseButtonAttribute` → `kAXPressAction`).
  After a 200ms delay, re-syncs with running applications and refreshes the panel.

#### Permissions (Permissions.swift)

On launch:
1. Check `AXIsProcessTrustedWithOptions` — if not granted, prompt via `AXTrustedCheckOptionPrompt`, then show a modal `NSAlert` with OK/Quit buttons. Loop re-checks on OK until granted.
2. Check `SCShareableContent.getExcludingDesktopWindows` via a blocking semaphore — if it errors, show a modal `NSAlert` with OK/"Continue Without Thumbnails" buttons. Loop re-checks on OK.
3. Once both are granted, proceed with `applicationDidFinishLaunching`.

No fancy permission window. Just modal alerts.

### Threading model

- **Main thread**: All UI (panel show/hide/layout), hotkey callbacks, AX observer callbacks, window list mutations
- **Background queue** (up to 8 concurrent): Thumbnail capture only
- No timers or polling. Hidden-state thumbnail work is bounded to meaningful window/focus events.

### Memory model

- When panel is hidden: window metadata and one scaled cached thumbnail per captured window remain in memory.
- When panel is shown: cached thumbnails display immediately; missing snapshots are captured asynchronously.
- When panel is hidden again: tile views remain reusable and cached thumbnails support the next instant summon.

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
| Continuous background thumbnail capture | Event-driven cache only | Instant summon without polling |
| Mission Control integration | Nothing | Don't need it |

### Estimated size

| File | Lines (est.) |
|---|---|
| Area | Lines (target) |
|---|---:|
| Core | ~250 |
| Hotkey | ~220 |
| Windows | ~500 |
| Overlay | ~500 |
| **Total source** | **≤1500** |
