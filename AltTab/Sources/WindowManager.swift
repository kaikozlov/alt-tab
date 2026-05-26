import Cocoa
import ApplicationServices

/// Tracks all windows across all running applications using Accessibility APIs.
/// No polling — uses AX observers + KVO for real-time updates.
final class WindowManager {
    static let shared = WindowManager()

    /// Windows sorted by last-focus order (index 0 = most recently focused).
    private(set) var windows: [WindowInfo] = []

    /// Called on main thread whenever the window list changes (add/remove/reorder).
    /// Wired by AppDelegate to refresh the switcher panel if it's open.
    var onChange: (() -> Void)?

    /// Tracked app identities. Removals use NSRunningApplication.isEqual like the reference;
    /// pid can be unreliable once an app is terminating.
    private var trackedApps: [pid_t: NSRunningApplication] = [:]

    /// Per-app AX observers
    private var observers: [pid_t: AXObserver] = [:]

    /// Per-app KVO observations for activationPolicy (to catch apps that aren't ready yet)
    private var policyObservations: [pid_t: NSKeyValueObservation] = [:]

    /// KVO observation on NSWorkspace.runningApplications
    private var appObservation: NSKeyValueObservation?

    private init() {}

    // MARK: - Public

    func start() {
        // Discover already-running apps
        for app in NSWorkspace.shared.runningApplications {
            addApp(app)
        }

        // Observe new launches / quits.
        // For ordered-to-many KVO, newValue/oldValue contain only the inserted/removed items,
        // not the full array. This matches how the reference implementation handles it.
        appObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            guard let self else { return }

            if let launched = change.newValue {
                for app in launched {
                    self.addApp(app)
                }
            }
            if let terminated = change.oldValue {
                for app in terminated {
                    self.removeApp(app)
                }
            }
        }

        // Do an initial z-order sort using CGWindowList
        sortByZOrder()
    }

    /// Returns windows in focus order, suitable for display in the switcher.
    func sortedWindows() -> [WindowInfo] {
        return windows
    }

    /// Reference-style manual sync before showing the panel: remove dead apps/windows,
    /// add any running apps KVO missed, then query each tracked app for missing windows.
    func syncWithRunningApplications() {
        let runningApps = NSWorkspace.shared.runningApplications
        let runningPids = Set(runningApps.map { $0.processIdentifier })
        var changed = false

        for app in runningApps {
            addApp(app)
        }

        changed = removeZombieWindows() || changed

        let staleByIdentity = trackedApps.filter { _, tracked in
            !runningApps.contains { $0.isEqual(tracked) }
        }.map(\.key)
        let staleByPid = LifecycleReconciler.staleWindowPids(windowPids: windows.map(\.pid), runningPids: runningPids)
        for pid in Set(staleByIdentity).union(staleByPid) {
            changed = removeTrackedApp(pid, notify: false) || changed
        }

        for (pid, app) in trackedApps where app.activationPolicy == .regular {
            let before = windows.count
            discoverWindows(pid: pid, appName: app.localizedName ?? "Unknown", bundleId: app.bundleIdentifier, icon: app.icon)
            if windows.count != before {
                for win in windows where win.pid == pid {
                    ThumbnailCapture.cacheInBackground(win)
                }
                changed = true
            }
        }

        if changed {
            reindex()
            onChange?()
        }
    }

    // MARK: - App tracking

    private func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Already tracking this app
        guard trackedApps[pid] == nil else { return }

        // App not ready yet — observe activationPolicy and retry when it becomes .regular
        if app.activationPolicy != .regular {
            if policyObservations[pid] == nil {
                policyObservations[pid] = app.observe(\.activationPolicy, options: [.new]) { [weak self] app, _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        if app.activationPolicy == .regular {
                            self.policyObservations.removeValue(forKey: pid)
                            self.addApp(app)
                        }
                    }
                }
            }
            return
        }

        trackedApps[pid] = app

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

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if AXObserverCreate(pid, callback, &observer) == .success, let observer {
            observers[pid] = observer
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
        }

        // Discover existing windows for this app
        discoverWindows(pid: pid, appName: appName, bundleId: bundleId, icon: icon)

        // If no windows found, the app may still be launching. Retry after a short delay.
        // This handles apps that are slow to create their initial window.
        if !windows.contains(where: { $0.pid == pid }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if !self.windows.contains(where: { $0.pid == pid }) {
                    self.discoverWindows(pid: pid, appName: appName, bundleId: bundleId, icon: icon)
                    if self.windows.contains(where: { $0.pid == pid }) {
                        for win in self.windows where win.pid == pid {
                            ThumbnailCapture.cacheInBackground(win)
                        }
                        self.onChange?()
                    }
                }
            }
        }

        // Capture initial thumbnails
        for win in windows where win.pid == pid {
            ThumbnailCapture.cacheInBackground(win)
        }
    }

    private func removeApp(_ app: NSRunningApplication) {
        let matchingPids = trackedApps.filter { _, tracked in tracked.isEqual(app) }.map(\.key)
        var changed = false
        for pid in matchingPids {
            changed = removeTrackedApp(pid, notify: false) || changed
        }

        // Fallback for apps we observed before they became regular.
        let pid = app.processIdentifier
        if policyObservations[pid] != nil {
            policyObservations.removeValue(forKey: pid)
        }

        if changed {
            reindex()
            onChange?()
        }
    }

    @discardableResult
    private func removeTrackedApp(_ pid: pid_t, notify: Bool) -> Bool {
        let hadWindows = windows.contains { $0.pid == pid }
        let wasTracked = trackedApps.removeValue(forKey: pid) != nil
        policyObservations.removeValue(forKey: pid)
        windows.removeAll { $0.pid == pid }

        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        let changed = hadWindows || wasTracked
        if changed && notify {
            reindex()
            onChange?()
        }
        return changed
    }

    /// Reference-style GC: AX can miss destroyed-window notifications, so verify our
    /// tracked CGWindowIDs still exist in WindowServer before showing the panel.
    private func removeZombieWindows() -> Bool {
        let ids = windows.map { $0.windowId }
        guard !ids.isEmpty else { return false }
        let descriptions = CGWindowListCreateDescriptionFromArray(ids as CFArray) as? [[CFString: Any]]
        let existing = Set(descriptions?.compactMap { $0[kCGWindowNumber] as? CGWindowID } ?? [])
        let before = windows.count
        windows.removeAll { !existing.contains($0.windowId) }
        return windows.count != before
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
            onChange?()
        }
    }

    private func handleWindowDestroyed(_ element: AXUIElement) {
        let countBefore = windows.count
        if let wid = windowId(of: element) {
            windows.removeAll { $0.windowId == wid }
        } else {
            windows.removeAll { CFEqual($0.axElement, element) }
        }
        if windows.count != countBefore {
            reindex()
            onChange?()
        }
    }

    private func handleFocusChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let focusedElement: AXUIElement
        if let wid = windowId(of: element), wid != 0 {
            focusedElement = element
        } else {
            var value: AnyObject?
            let appEl = AXUIElementCreateApplication(pid)
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success else { return }
            focusedElement = (value as! AXUIElement)
        }

        guard let wid = windowId(of: focusedElement) else { return }

        if let idx = windows.firstIndex(where: { $0.windowId == wid }) {
            let win = windows.remove(at: idx)
            win.title = WindowInfo.bestTitle(axElement: win.axElement, windowId: wid, appName: win.appName)
            windows.insert(win, at: 0)
            reindex()
            ThumbnailCapture.cacheInBackground(win)
        } else {
            let app = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
            if let info = addWindowIfNew(focusedElement, pid: pid, appName: app?.localizedName ?? "Unknown",
                                         bundleId: app?.bundleIdentifier, icon: app?.icon) {
                if let idx = windows.firstIndex(where: { $0.windowId == info.windowId }) {
                    let w = windows.remove(at: idx)
                    windows.insert(w, at: 0)
                    reindex()
                }
                ThumbnailCapture.cacheInBackground(info)
                onChange?()
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
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else {
            return true
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
