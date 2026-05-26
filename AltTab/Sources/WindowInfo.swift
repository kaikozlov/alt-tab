import Cocoa

/// Lightweight model for a single window tracked by the switcher.
final class WindowInfo {
    let windowId: CGWindowID
    let axElement: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleId: String?
    var title: String
    var appIcon: NSImage?
    var thumbnail: CGImage?
    var lastFocusOrder: Int = 0
    var isMinimized: Bool = false

    init(windowId: CGWindowID, axElement: AXUIElement, pid: pid_t,
         appName: String, bundleId: String?, title: String, appIcon: NSImage?) {
        self.windowId = windowId
        self.axElement = axElement
        self.pid = pid
        self.appName = appName
        self.bundleId = bundleId
        self.title = title
        self.appIcon = appIcon
    }

    /// Bring this window to the front and make it key.
    func focus() {
        var psn = ProcessSerialNumber()
        GetProcessForPID(pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, windowId, SLPSMode.userGenerated.rawValue)
        makeKeyWindow(&psn)

        // AX fallback — raise the window
        AXUIElementPerformAction(axElement, kAXRaiseAction as CFString)
    }

    /// Ported from Hammerspoon: send raw event bytes to make a specific window key.
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber) {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        var wid = windowId
        memcpy(&bytes[0x3c], &wid, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    /// Best-effort title: AX title → CG title → app name
    static func bestTitle(axElement: AXUIElement, windowId: CGWindowID, appName: String) -> String {
        if let axTitle = axTitle(axElement), !axTitle.isEmpty { return axTitle }
        if let cgTitle = cgTitle(windowId), !cgTitle.isEmpty { return cgTitle }
        return appName
    }

    private static func axTitle(_ el: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func cgTitle(_ wid: CGWindowID) -> String? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[CFString: Any]]
        return info?.first?[kCGWindowName] as? String
    }
}
