import Cocoa
import ApplicationServices

// MARK: - App lifecycle tracking

extension WindowManager {

    func addApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard trackedApps[pid] == nil else { return }
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
        installAXObserver(pid: pid)
        discoverWindows(pid: pid, appName: appName, bundleId: bundleId, icon: icon)
        retryDiscoveryIfEmpty(pid: pid, appName: appName, bundleId: bundleId, icon: icon)
    }

    func removeApp(_ app: NSRunningApplication) {
        let matchingPids = trackedApps.filter { _, tracked in tracked.isEqual(app) }.map(\.key)
        var changed = false
        for pid in matchingPids {
            changed = removeTrackedApp(pid, notify: false) || changed
        }
        let pid = app.processIdentifier
        policyObservations.removeValue(forKey: pid)
        if changed {
            reindex()
            onChange?()
        }
    }

    @discardableResult
    func removeTrackedApp(_ pid: pid_t, notify: Bool) -> Bool {
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

    // MARK: - AX observer setup

    private func installAXObserver(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let mgr = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            let notif = notification as String
            DispatchQueue.main.async { mgr.handleAXNotification(notif, element: element) }
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        observers[pid] = observer
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationActivatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]
        for notif in notifications {
            AXObserverAddNotification(observer, appElement, notif as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func retryDiscoveryIfEmpty(pid: pid_t, appName: String, bundleId: String?, icon: NSImage?) {
        guard !windows.contains(where: { $0.pid == pid }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.windows.contains(where: { $0.pid == pid }) else { return }
            self.discoverWindows(pid: pid, appName: appName, bundleId: bundleId, icon: icon)
            let added = self.windows.filter { $0.pid == pid }
            guard !added.isEmpty else { return }
            self.refreshThumbnails?(added)
            self.onChange?()
        }
    }
}
