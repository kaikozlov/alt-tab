import Cocoa
import ApplicationServices

/// Tracks all windows across all running applications using Accessibility APIs.
/// No polling — uses AX observers for real-time updates.
final class WindowManager {
    static let shared = WindowManager()

    /// Windows sorted by last-focus order (index 0 = most recently focused).
    private(set) var windows: [WindowInfo] = []

    /// Per-app AX observers
    private var observers: [pid_t: AXObserver] = [:]
    private var appObservation: NSKeyValueObservation?

    private init() {}

    // MARK: - Public

    func start() {
        // Discover already-running apps
        for app in NSWorkspace.shared.runningApplications {
            addApp(app)
        }

        // Observe new launches / quits
        appObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            guard let self else { return }
            if let added = change.newValue {
                for app in added { self.addApp(app) }
            }
            if let removed = change.oldValue {
                for app in removed { self.removeApp(app) }
            }
        }

        // Do an initial z-order sort using CGWindowList
        sortByZOrder()
    }

    /// Returns windows in focus order, suitable for display in the switcher.
    func sortedWindows() -> [WindowInfo] {
        return windows
    }

    // MARK: - App tracking

    private func addApp(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        let appName = app.localizedName ?? "Unknown"
        let bundleId = app.bundleIdentifier
        let icon = app.icon

        // Create AX observer for this app
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let mgr = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            let notif = notification as String
            DispatchQueue.main.async {
                mgr.handleAXNotification(notif, element: element)
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        observers[pid] = observer

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Subscribe to notifications
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXApplicationActivatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        // Enumerate existing windows for this app
        discoverWindows(pid: pid, appName: appName, bundleId: bundleId, icon: icon)

        // Capture initial thumbnails for all discovered windows of this app
        for win in windows where win.pid == pid {
            ThumbnailCapture.cacheInBackground(win)
        }
    }

    private func removeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        windows.removeAll { $0.pid == pid }
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        reindex()
    }

    // MARK: - Window discovery

    private func discoverWindows(pid: pid_t, appName: String, bundleId: String?, icon: NSImage?) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return }

        for axWin in axWindows {
            addWindowIfNew(axWin, pid: pid, appName: appName, bundleId: bundleId, icon: icon)
        }
    }

    @discardableResult
    private func addWindowIfNew(_ axElement: AXUIElement, pid: pid_t, appName: String, bundleId: String?, icon: NSImage?) -> WindowInfo? {
        guard let wid = windowId(of: axElement) else { return nil }
        guard !windows.contains(where: { $0.windowId == wid }) else { return nil }

        // Filter out non-standard windows
        guard isStandardWindow(axElement) else { return nil }

        let title = WindowInfo.bestTitle(axElement: axElement, windowId: wid, appName: appName)
        let isMin = isMinimized(axElement)

        let info = WindowInfo(windowId: wid, axElement: axElement, pid: pid,
                              appName: appName, bundleId: bundleId, title: title, appIcon: icon)
        info.isMinimized = isMin
        info.lastFocusOrder = windows.count
        windows.append(info)
        return info
    }

    // MARK: - AX notification handling

    private func handleAXNotification(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            handleWindowCreated(element)

        case kAXUIElementDestroyedNotification:
            handleWindowDestroyed(element)

        case kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification:
            handleFocusChanged(element)

        case kAXWindowMiniaturizedNotification:
            if let wid = windowId(of: element), let win = windows.first(where: { $0.windowId == wid }) {
                win.isMinimized = true
                ThumbnailCapture.cacheInBackground(win)
            }

        case kAXWindowDeminiaturizedNotification:
            if let wid = windowId(of: element), let win = windows.first(where: { $0.windowId == wid }) {
                win.isMinimized = false
                ThumbnailCapture.cacheInBackground(win)
            }

        default:
            break
        }
    }

    private func handleWindowCreated(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0 else { return }

        let app = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        let appName = app?.localizedName ?? "Unknown"
        let bundleId = app?.bundleIdentifier
        let icon = app?.icon

        if let win = addWindowIfNew(element, pid: pid, appName: appName, bundleId: bundleId, icon: icon) {
            ThumbnailCapture.cacheInBackground(win)
        }
    }

    private func handleWindowDestroyed(_ element: AXUIElement) {
        if let wid = windowId(of: element) {
            windows.removeAll { $0.windowId == wid }
        } else {
            // Fallback: AX element might be invalid, try matching by reference
            windows.removeAll { CFEqual($0.axElement, element) }
        }
        reindex()
    }

    private func handleFocusChanged(_ element: AXUIElement) {
        // The element might be the app or the window — try to get the focused window
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let focusedElement: AXUIElement
        if let wid = windowId(of: element), wid != 0 {
            focusedElement = element
        } else {
            // It's an app element; get its focused window
            var value: AnyObject?
            let appEl = AXUIElementCreateApplication(pid)
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success else { return }
            focusedElement = (value as! AXUIElement)
        }

        guard let wid = windowId(of: focusedElement) else { return }

        if let idx = windows.firstIndex(where: { $0.windowId == wid }) {
            // Move to front of focus order
            let win = windows.remove(at: idx)
            win.title = WindowInfo.bestTitle(axElement: win.axElement, windowId: wid, appName: win.appName)
            windows.insert(win, at: 0)
            reindex()
            ThumbnailCapture.cacheInBackground(win)
        } else {
            // New window we hadn't seen — add it at front
            let app = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
            if let info = addWindowIfNew(focusedElement, pid: pid, appName: app?.localizedName ?? "Unknown",
                                         bundleId: app?.bundleIdentifier, icon: app?.icon) {
                if let idx = windows.firstIndex(where: { $0.windowId == info.windowId }) {
                    let w = windows.remove(at: idx)
                    windows.insert(w, at: 0)
                    reindex()
                }
            }
        }
    }

    // MARK: - Z-order sort (used once at startup)

    private func sortByZOrder() {
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        var zOrder: [CGWindowID: Int] = [:]
        for (i, info) in cgWindows.enumerated() {
            if let wid = info[kCGWindowNumber] as? CGWindowID {
                zOrder[wid] = i
            }
        }
        windows.sort { (zOrder[$0.windowId] ?? Int.max) < (zOrder[$1.windowId] ?? Int.max) }
        reindex()
    }

    private func reindex() {
        for (i, win) in windows.enumerated() {
            win.lastFocusOrder = i
        }
    }

    // MARK: - Helpers

    private func windowId(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        // _AXUIElementGetWindow is private but stable since 10.5
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return true // If we can't determine subrole, include it
        }
        let subrole = value as? String
        return subrole == "AXStandardWindow" || subrole == "AXDialog" || subrole == nil
    }

    private func isMinimized(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

// Private AX API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
