import Cocoa
import ApplicationServices

/// Tracks all windows across all running applications using Accessibility APIs.
/// No polling — uses AX observers + KVO for real-time updates.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    /// Windows sorted by last-focus order (index 0 = most recently focused).
    var windows: [WindowInfo] = []

    /// Called on main thread whenever the window list changes (add/remove/reorder).
    /// Wired by AppDelegate to refresh the switcher panel if it's open.
    var onChange: (() -> Void)?

    /// Tracked app identities. Removals use NSRunningApplication.isEqual like the reference;
    /// pid can be unreliable once an app is terminating.
    var trackedApps: [pid_t: NSRunningApplication] = [:]

    /// Per-app AX observers
    var observers: [pid_t: AXObserver] = [:]

    /// Per-app KVO observations for activationPolicy (to catch apps that aren't ready yet)
    var policyObservations: [pid_t: NSKeyValueObservation] = [:]

    /// KVO observation on NSWorkspace.runningApplications
    private var appObservation: NSKeyValueObservation?

    private init() {}

    // MARK: - Public

    func start() {
        for app in NSWorkspace.shared.runningApplications {
            addApp(app)
        }
        appObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let launched = change.newValue {
                    for app in launched { self.addApp(app) }
                }
                if let terminated = change.oldValue {
                    for app in terminated { self.removeApp(app) }
                }
            }
        }
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
        for app in runningApps { addApp(app) }
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
            if windows.count != before { changed = true }
        }
        let focusChanged = syncFocusedWindowFromSystem()
        if changed || focusChanged {
            reindex()
            onChange?()
        }
    }

    /// Mark a window as most recently focused. Used after our own activation path because
    /// AX focus notifications may arrive late or be skipped for some apps.
    func markFocused(_ window: WindowInfo) {
        guard moveToFront(windowId: window.windowId) else { return }
        onChange?()
    }

    // MARK: - Ordering

    @discardableResult
    func moveToFront(windowId: CGWindowID) -> Bool {
        guard let idx = windows.firstIndex(where: { $0.windowId == windowId }) else { return false }
        guard idx != 0 else { return false }
        let win = windows.remove(at: idx)
        windows.insert(win, at: 0)
        reindex()
        return true
    }

    func reindex() {
        for (i, win) in windows.enumerated() {
            win.lastFocusOrder = i
        }
    }

    // MARK: - Cleanup

    private func sortByZOrder() {
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        var zOrder: [CGWindowID: Int] = [:]
        for (i, info) in cgWindows.enumerated() {
            if let wid = info[kCGWindowNumber] as? CGWindowID { zOrder[wid] = i }
        }
        windows.sort { (zOrder[$0.windowId] ?? Int.max) < (zOrder[$1.windowId] ?? Int.max) }
        reindex()
    }

    /// Reference-style GC: AX can miss destroyed-window notifications, so verify our
    /// tracked CGWindowIDs still exist in WindowServer before showing the panel.
    @discardableResult
    func removeZombieWindows() -> Bool {
        let ids = windows.map { $0.windowId }
        guard !ids.isEmpty else { return false }
        let descriptions = CGWindowListCreateDescriptionFromArray(ids as CFArray) as? [[CFString: Any]]
        let existing = Set(descriptions?.compactMap { $0[kCGWindowNumber] as? CGWindowID } ?? [])
        let before = windows.count
        windows.removeAll { !existing.contains($0.windowId) }
        return windows.count != before
    }
}
