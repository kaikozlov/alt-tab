import Cocoa
import ScreenCaptureKit

/// On-demand window thumbnail capture. No background polling.
///
/// Uses the private CGSHWCaptureWindowList as the primary fast path — it's synchronous,
/// ~2-5ms per window, and works for both normal and minimized windows.
/// SCScreenCaptureKit is available as a fallback but is slower due to async overhead.
enum ThumbnailCapture {

    private static let captureQueue = DispatchQueue(label: "dev.kai.AltTab.capture", attributes: .concurrent)

    /// Capture thumbnails for all windows in parallel, then call completion on main thread.
    /// Designed to be called BEFORE showing the panel so thumbnails are ready immediately.
    static func captureAll(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        let group = DispatchGroup()

        for window in windows {
            group.enter()
            captureQueue.async {
                let image = captureWithPrivateAPI(window.windowId)
                DispatchQueue.main.async {
                    window.thumbnail = image
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion()
        }
    }

    /// Synchronous single-window capture on current thread. Returns CGImage or nil.
    static func captureSingle(_ windowId: CGWindowID) -> CGImage? {
        return captureWithPrivateAPI(windowId)
    }

    // MARK: - Private API (primary fast path)

    /// CGSHWCaptureWindowList is synchronous, fast (~2-5ms), works for minimized windows,
    /// and captures at full resolution. This is the same API the reference implementation
    /// uses for its "legacy" path, but it's actually the fastest option.
    private static func captureWithPrivateAPI(_ wid: CGWindowID) -> CGImage? {
        var windowId = wid
        let list = CGSHWCaptureWindowList(CGS_CONNECTION, &windowId, 1,
                                          [.ignoreGlobalClipShape, .bestResolution, .fullSize])
            .takeRetainedValue() as! [CGImage]
        return list.first
    }

    /// Release all thumbnails to free memory when the panel is hidden.
    static func releaseAll(_ windows: [WindowInfo]) {
        for window in windows {
            window.thumbnail = nil
        }
    }
}
