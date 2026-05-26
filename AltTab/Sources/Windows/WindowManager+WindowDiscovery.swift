import Cocoa
import ApplicationServices

// MARK: - Window discovery and AX event handling

extension WindowManager {

    func handleAXNotification(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            handleWindowCreated(element)
        case kAXUIElementDestroyedNotification:
            handleWindowDestroyed(element)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXApplicationActivatedNotification:
            handleFocusChanged(element)
        case kAXWindowMiniaturizedNotification:
            if let wid = windowId(of: element), let win = windows.first(where: { $0.windowId == wid }) {
                win.isMinimized = true
            }
        case kAXWindowDeminiaturizedNotification:
            if let wid = windowId(of: element), let win = windows.first(where: { $0.windowId == wid }) {
                win.isMinimized = false
            }
        default:
            break
        }
    }

    // MARK: - Window lifecycle

    private func handleWindowCreated(_ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != 0 else { return }
        let app = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        if addWindowIfNew(element, pid: pid, appName: app?.localizedName ?? "Unknown",
                          bundleId: app?.bundleIdentifier, icon: app?.icon) != nil {
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
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
              app.isActive else { return }
        let focusedElement: AXUIElement
        if let wid = windowId(of: element), wid != 0 {
            focusedElement = element
        } else {
            var value: AnyObject?
            let appEl = AXUIElementCreateApplication(pid)
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let axEl = safeAXElement(from: value) else { return }
            focusedElement = axEl
        }
        guard let wid = windowId(of: focusedElement) else { return }
        if let idx = windows.firstIndex(where: { $0.windowId == wid }) {
            let win = windows[idx]
            win.title = WindowInfo.bestTitle(axElement: win.axElement, windowId: wid, appName: win.appName)
            notifyFocusChangeIfNeeded(updateLastFocusOrder(windowId: wid))
        } else if addWindowIfNew(focusedElement, pid: pid, appName: app.localizedName ?? "Unknown",
                                 bundleId: app.bundleIdentifier, icon: app.icon) != nil {
            _ = updateLastFocusOrder(windowId: wid)
            notifyFocusChangeIfNeeded(true)
        }
    }

    private func notifyFocusChangeIfNeeded(_ changed: Bool) {
        guard changed, suppressFocusRefresh?() != true else { return }
        onChange?()
    }

    @discardableResult
    func syncFocusedWindowFromSystem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let axEl = safeAXElement(from: value),
              let wid = windowId(of: axEl) else { return false }
        if windows.contains(where: { $0.windowId == wid }) {
            return updateLastFocusOrder(windowId: wid)
        }
        if addWindowIfNew(axEl, pid: pid, appName: app.localizedName ?? "Unknown",
                          bundleId: app.bundleIdentifier, icon: app.icon) != nil {
            return updateLastFocusOrder(windowId: wid)
        }
        return false
    }

    // MARK: - Discovery

    func discoverWindows(pid: pid_t, appName: String, bundleId: String?, icon: NSImage?) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return }
        for axWin in axWindows {
            addWindowIfNew(axWin, pid: pid, appName: appName, bundleId: bundleId, icon: icon)
        }
    }

    @discardableResult
    func addWindowIfNew(_ axElement: AXUIElement, pid: pid_t, appName: String, bundleId: String?, icon: NSImage?) -> WindowInfo? {
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

    // MARK: - AX helpers

    func windowId(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
        return wid
    }

    func isStandardWindow(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else { return true }
        let subrole = value as? String
        return subrole == "AXStandardWindow" || subrole == "AXDialog" || subrole == nil
    }

    func isMinimized(_ element: AXUIElement) -> Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

// Private AX API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
