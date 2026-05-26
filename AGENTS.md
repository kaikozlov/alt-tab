# Repository Guidelines

## What This Is

A minimal, zero-dependency macOS window switcher. Replaces Cmd+Tab with a thumbnail-based overlay. Target: ~1000 lines of Swift, instant activation, zero idle CPU.

Read `ARCHITECTURE.md` for the full design, component breakdown, and activation flow.

# macOS development
- Don't use xcode directly to develop
- Use pure swift code to make the app. No interface builder. No SwiftUI.
- Aim for compact code. Within methods, don't have groups of statements separated with newlines. No inline comments for simple code. Instead, split statements into sub-methods.
- Use guard closes as much as possible to separate the happy-path under them
- Organize source files into folders. Folders should group files that change together, at the same pace (e.g. one feature)
- Favor low latency and responsiveness. Reuse objects, avoid wasting memory or I/O.

## Project Structure

```
Sources/
  main.swift              — Entry point, NSApplication bootstrap
  App.swift               — App delegate, lifecycle, permission flow
  Hotkey.swift            — CGEventTap + Carbon hotkey (Cmd+Tab interception)
  WindowManager.swift     — AX-based window discovery and tracking
  WindowInfo.swift        — Single window model struct
  Thumbnail.swift         — On-demand SCScreenshotManager capture
  OverlayPanel.swift      — NSPanel (floating switcher window)
  OverlayView.swift       — Tile grid layout and background blur
  TileView.swift          — Individual tile (thumbnail + icon + title)
  SkyLight.swift          — Private API declarations (CGS*, SLPS*, etc.)
  Permissions.swift       — Accessibility + Screen Recording checks
```

## Build & Run

This is an Xcode project because we need a proper `.app` bundle with `Info.plist`, entitlements, and code signing for `CGEventTap` + private APIs.

```bash
# Build and run from Xcode
open AltTab.xcodeproj

# Or from command line
xcodebuild -scheme AltTab -configuration Debug build
```

The app requires:
- **Accessibility permission** — for AX window tracking and `CGEventTap`
- **Screen Recording permission** — for `SCScreenshotManager` thumbnails

Grant both in System Settings → Privacy & Security when prompted.

## Coding Style

- **Swift 6** with strict concurrency where practical.
- **4-space indent**, ~120-char soft line limit.
- **No Auto Layout** — all UI is manual frame-based layout for performance.
- **No external dependencies** — zero. No SPM packages, no CocoaPods, no Carthage.
- **No SwiftUI** — pure AppKit (`NSPanel`, `NSVisualEffectView`, `CALayer`).
- Prefer `CALayer` over `NSView` for image rendering (thumbnails, icons) — fewer redraws.
- Use `MARK: -` comments to organize sections within files.
- Keep files focused: one major type per file.

## Architecture Rules

- **Zero idle CPU**: No timers, no polling, no background work when the overlay is hidden. AX observer callbacks are the only event source.
- **On-demand thumbnails only**: Capture screenshots when the switcher is shown, release them when it's hidden. Never capture in the background.
- **Main thread for everything except thumbnails**: Window list mutations, UI updates, hotkey callbacks — all main thread. Only thumbnail capture goes to a background queue.
- **No preferences UI**: Hardcode sane defaults. If something needs to be tweakable, use `defaults write com.alt-tab.app <key> <value>`.
- **Private APIs are acceptable**: We use SkyLight/CGS APIs (`CGSSetSymbolicHotKeyEnabled`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `CGSHWCaptureWindowList`) because there is no public alternative for reliable window switching. Declare them in `SkyLight.swift` with `@_silgen_name`.

## Key Technical Details

### Hotkey Interception
- Disable native Cmd+Tab: `CGSSetSymbolicHotKeyEnabled(.commandTab, false)`
- Catch Cmd+Tab press: Carbon `RegisterEventHotKey`
- Detect Cmd release: `CGEventTap` on `.cghidEventTap` watching `flagsChanged`
- Catch Tab/arrow/Escape while panel is open: `NSEvent.addLocalMonitorForEvents`
- Re-enable native Cmd+Tab on app quit: `applicationWillTerminate`

### Window Tracking
- Observe `NSWorkspace.shared.runningApplications` via KVO for app launch/quit
- For each `.regular` activation policy app: `AXObserverCreate` + subscribe to window notifications
- Get `CGWindowID` from `AXUIElement` via `_AXUIElementGetWindow()` (private but stable)
- Keep `[WindowInfo]` sorted by `lastFocusOrder` — updated on `kAXFocusedWindowChangedNotification`

### Thumbnail Capture
- Primary: `SCScreenshotManager.captureSampleBuffer` (macOS 13+)
- Fallback for minimized windows: `CGSHWCaptureWindowList` (private API)
- Capture on a single background `DispatchQueue`, dispatch results to main

### Overlay Panel
- `NSPanel(styleMask: .nonactivatingPanel)` — doesn't steal focus
- `.level = .popUpMenu`, `.collectionBehavior = .canJoinAllSpaces`
- Background: `NSVisualEffectView` with `.hudWindow` material
- Tiles: `CALayer`-based thumbnail + small app icon + truncated title

### Window Activation
- `_SLPSSetFrontProcessWithOptions(&psn, windowId, .userGenerated)`
- `SLPSPostEventRecordTo(&psn, &bytes)` — make window key (Hammerspoon technique)
- Fallback: `AXUIElement.performAction(kAXRaiseAction)`

## Agent Notes

- When adding private API declarations to `SkyLight.swift`, include a comment noting the macOS version range and what the function does.
- The overlay must never become the key window of the frontmost app — use `.nonactivatingPanel` and never call `NSApp.activate()` while the panel is visible.
- `CGSSetSymbolicHotKeyEnabled` state persists after app quit. Always restore it in `applicationWillTerminate` — if we crash without restoring, the user loses native Cmd+Tab entirely.
- `CGEventTap` requires Accessibility permission. If it returns `nil` from `CGEvent.tapCreate`, the app cannot function — show an alert and exit.
- Keep the total line count under 1500. If a file grows past 200 lines, it probably needs splitting. If the project grows past 1500 lines total, something is wrong.
