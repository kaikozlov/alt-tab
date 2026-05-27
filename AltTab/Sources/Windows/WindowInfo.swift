@preconcurrency import Cocoa

/// Lightweight model for a single window tracked by the switcher.
final class WindowInfo: @unchecked Sendable {
    let windowId: CGWindowID
    let axElement: AXUIElement
    let pid: pid_t
    let appName: String
    let bundleId: String?
    var title: String
    var appIcon: NSImage?
    var thumbnail: CGImage?
    var contentSize: CGSize?
    var lastFocusOrder: Int = 0
    var isMinimized: Bool = false
    private var thumbnailRevision: UInt64 = 0
    private var thumbnailCapturePending = false

    private static let commandQueue = DispatchQueue(label: "dev.kai.AltTab.ax.commands")

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

    /// Press the window's close button via AX, equivalent to clicking the red traffic-light button.
    func closeSoftly(completion: (@MainActor @Sendable () -> Void)? = nil) {
        let element = axElement
        WindowInfo.commandQueue.async {
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &value)
            let button = safeAXElement(from: value)
            let pressed = error == .success && button.map {
                AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
            } == true

            DispatchQueue.main.async {
                if !pressed { NSSound.beep() }
                completion?()
            }
        }
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

    static func contentSize(axElement: AXUIElement, windowId: CGWindowID) -> CGSize? {
        if let size = axSize(axElement) { return size }
        return cgBounds(windowId)
    }

    @discardableResult
    func refreshContentSize() -> Bool {
        let size = WindowInfo.contentSize(axElement: axElement, windowId: windowId)
        guard size != contentSize else { return false }
        contentSize = size
        invalidateThumbnail()
        return true
    }

    func beginThumbnailCapture(refreshCached: Bool) -> UInt64? {
        guard refreshCached || (thumbnail == nil && !thumbnailCapturePending) else { return nil }
        thumbnailRevision &+= 1
        thumbnailCapturePending = true
        return thumbnailRevision
    }

    func applyThumbnail(_ image: CGImage?, revision: UInt64) -> Bool {
        guard revision == thumbnailRevision else { return false }
        thumbnailCapturePending = false
        guard let image else { return false }
        thumbnail = image
        return true
    }

    func invalidateThumbnail() {
        thumbnailRevision &+= 1
        thumbnailCapturePending = false
        thumbnail = nil
    }

    private static func axSize(_ el: AXUIElement) -> CGSize? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private static func cgBounds(_ wid: CGWindowID) -> CGSize? {
        let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[CFString: Any]]
        guard let bounds = info?.first?[kCGWindowBounds] as? [String: Any],
              let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
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
