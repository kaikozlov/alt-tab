import Cocoa
import ScreenCaptureKit

/// Window thumbnail capture with background caching.
///
/// Thumbnails are captured proactively whenever windows change (focus, create, deminiaturize)
/// and cached on WindowInfo.thumbnail. When the switcher opens, thumbnails are already ready.
///
/// Primary path: SCScreenCaptureKit (macOS 14+) via `desktopIndependentWindow` filter —
/// captures full window content regardless of on-screen position (critical for AeroSpace).
/// Fallback: CGSHWCaptureWindowList (private API) for minimized windows.
enum ThumbnailCapture {

    private static let captureQueue = DispatchQueue(label: "dev.kai.AltTab.capture", attributes: .concurrent)

    /// Cached SCShareableContent to avoid repeated expensive OS calls.
    /// Refreshed on each captureAll, and periodically by captureSingle.
    @available(macOS 14.0, *)
    private static var cachedSCWindows: [SCWindow] = []
    private static var lastSCContentFetch: Date = .distantPast

    /// How often to re-fetch SCShareableContent (seconds)
    private static let scContentTTL: TimeInterval = 2.0

    // MARK: - Single window capture (background caching)

    /// Capture a single window's thumbnail in the background. Result cached on window.thumbnail.
    /// Called by WindowManager on AX events. Fire-and-forget.
    static func cacheInBackground(_ window: WindowInfo) {
        if window.isMinimized {
            captureQueue.async {
                let image = captureWithPrivateAPI(window.windowId)
                DispatchQueue.main.async {
                    window.thumbnail = image
                }
            }
            return
        }

        if #available(macOS 14.0, *) {
            captureSingleWithSCKit(window)
        } else {
            captureQueue.async {
                let image = captureWithPrivateAPI(window.windowId)
                DispatchQueue.main.async {
                    window.thumbnail = image
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureSingleWithSCKit(_ window: WindowInfo) {
        // Use cached SCWindows if fresh enough
        let age = Date().timeIntervalSince(lastSCContentFetch)
        if age < scContentTTL, let scWindow = cachedSCWindows.first(where: { $0.windowID == window.windowId }) {
            captureSCWindow(scWindow, into: window)
            return
        }

        // Refresh cache
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            guard let content, error == nil else {
                // Fallback to private API
                captureQueue.async {
                    let image = captureWithPrivateAPI(window.windowId)
                    DispatchQueue.main.async { window.thumbnail = image }
                }
                return
            }
            DispatchQueue.main.async {
                cachedSCWindows = content.windows
                lastSCContentFetch = Date()
                if let scWindow = cachedSCWindows.first(where: { $0.windowID == window.windowId }) {
                    captureSCWindow(scWindow, into: window)
                }
            }
        }
    }

    // MARK: - Show-time fast fill

    /// Fill only missing thumbnails synchronously using the fast private capture path.
    /// This prevents icon-only placeholder tiles if lifecycle sync discovers windows right
    /// before the overlay opens. SCKit still refreshes asynchronously afterward for
    /// offscreen/AeroSpace-correct captures.
    static func fillMissingFastSync(_ windows: [WindowInfo]) {
        for window in windows where window.thumbnail == nil {
            window.thumbnail = captureWithPrivateAPI(window.windowId)
        }
    }

    // MARK: - Bulk capture (refresh all on switcher show)

    /// Capture thumbnails for all windows. Completion called on main thread.
    /// Uses cached SCShareableContent or fetches fresh if stale.
    static func captureAll(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        guard !windows.isEmpty else { completion(); return }

        let minimized = windows.filter { $0.isMinimized }
        let normal = windows.filter { !$0.isMinimized }
        let group = DispatchGroup()

        // Minimized: private API only
        for window in minimized {
            group.enter()
            captureQueue.async {
                let image = captureWithPrivateAPI(window.windowId)
                DispatchQueue.main.async {
                    window.thumbnail = image
                    group.leave()
                }
            }
        }

        // Normal: SCKit (or private API pre-macOS 14)
        if !normal.isEmpty {
            group.enter()
            if #available(macOS 14.0, *) {
                captureAllWithSCKit(normal) { group.leave() }
            } else {
                let inner = DispatchGroup()
                for window in normal {
                    inner.enter()
                    captureQueue.async {
                        let image = captureWithPrivateAPI(window.windowId)
                        DispatchQueue.main.async {
                            window.thumbnail = image
                            inner.leave()
                        }
                    }
                }
                inner.notify(queue: .main) { group.leave() }
            }
        }

        group.notify(queue: .main) { completion() }
    }

    @available(macOS 14.0, *)
    private static func captureAllWithSCKit(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            guard let content, error == nil else {
                // Fall back to private API
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
                group.notify(queue: .main) { completion() }
                return
            }

            DispatchQueue.main.async {
                cachedSCWindows = content.windows
                lastSCContentFetch = Date()
            }

            var scMap: [CGWindowID: SCWindow] = [:]
            for scWin in content.windows { scMap[scWin.windowID] = scWin }

            let group = DispatchGroup()
            for window in windows {
                group.enter()
                if let scWin = scMap[window.windowId] {
                    let filter = SCContentFilter(desktopIndependentWindow: scWin)
                    let config = captureConfig(for: scWin)

                    SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { buffer, err in
                        var image: CGImage?
                        if let buffer, err == nil, let pb = buffer.imageBuffer {
                            image = cgImageFromPixelBuffer(pb)
                        }
                        DispatchQueue.main.async {
                            window.thumbnail = image
                            group.leave()
                        }
                    }
                } else {
                    captureQueue.async {
                        let image = captureWithPrivateAPI(window.windowId)
                        DispatchQueue.main.async {
                            window.thumbnail = image
                            group.leave()
                        }
                    }
                }
            }
            group.notify(queue: .main) { completion() }
        }
    }

    // MARK: - Shared helpers

    @available(macOS 14.0, *)
    private static func captureSCWindow(_ scWindow: SCWindow, into window: WindowInfo) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = captureConfig(for: scWindow)

        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { buffer, error in
            var image: CGImage?
            if let buffer, error == nil, let pb = buffer.imageBuffer {
                image = cgImageFromPixelBuffer(pb)
            }
            DispatchQueue.main.async {
                window.thumbnail = image
            }
        }
    }

    @available(macOS 14.0, *)
    private static func captureConfig(for scWindow: SCWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let maxDim: CGFloat = 400
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let w = CGFloat(scWindow.frame.width)
        let h = CGFloat(scWindow.frame.height)
        if w > 0 && h > 0 {
            let fit = min(maxDim / w, maxDim / h, 1.0)
            config.width = max(1, Int(w * fit * scale))
            config.height = max(1, Int(h * fit * scale))
        }
        return config
    }

    private static func captureWithPrivateAPI(_ wid: CGWindowID) -> CGImage? {
        var windowId = wid
        let list = CGSHWCaptureWindowList(CGS_CONNECTION, &windowId, 1,
                                          [.ignoreGlobalClipShape, .bestResolution, .fullSize])
            .takeRetainedValue() as! [CGImage]
        return list.first
    }

    private static func cgImageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let context = CGContext(data: baseAddress,
                                width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue).rawValue)
        return context?.makeImage()
    }

    /// Release all thumbnails to free memory.
    static func releaseAll(_ windows: [WindowInfo]) {
        for window in windows { window.thumbnail = nil }
    }
}
