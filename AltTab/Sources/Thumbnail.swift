import Cocoa
import ScreenCaptureKit

/// On-demand thumbnail capture. No caching between overlay sessions.
///
/// Cmd+Tab captures the current window list, then the overlay is shown once thumbnails are ready.
/// While the overlay is visible, thumbnails stay on WindowInfo so refreshes after W/Q don't
/// degrade surviving tiles to app icons. Dismissal releases them.
/// SCKit is the primary path because `desktopIndependentWindow` captures full content for
/// offscreen/AeroSpace-managed windows. Private CGSHWCaptureWindowList is only a fallback.
enum ThumbnailCapture {

    private static let captureQueue = DispatchQueue(label: "dev.kai.AltTab.capture", attributes: .concurrent)

    /// Capture thumbnails for all windows, then call completion on main thread.
    /// Does not clear existing thumbnails; callers decide when a fresh session should release.
    static func captureAll(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        capture(windows, completion: completion)
    }

    /// Capture only windows that don't currently have a thumbnail.
    static func captureMissing(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        capture(windows.filter { $0.thumbnail == nil }, completion: completion)
    }

    /// Release thumbnails. Called before a new overlay session and when the panel closes.
    static func releaseAll(_ windows: [WindowInfo]) {
        for window in windows { window.thumbnail = nil }
    }

    private static func capture(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        guard !windows.isEmpty else { completion(); return }
        if #available(macOS 14.0, *) {
            captureAllWithSCKit(windows, completion: completion)
        } else {
            captureAllWithPrivateAPI(windows, completion: completion)
        }
    }

    // MARK: - SCKit primary path

    @available(macOS 14.0, *)
    private static func captureAllWithSCKit(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            guard let content, error == nil else {
                captureAllWithPrivateAPI(windows, completion: completion)
                return
            }

            var scMap: [CGWindowID: SCWindow] = [:]
            for scWindow in content.windows {
                scMap[scWindow.windowID] = scWindow
            }

            let group = DispatchGroup()
            for window in windows {
                group.enter()
                if !window.isMinimized, let scWindow = scMap[window.windowId] {
                    capture(scWindow, into: window) { group.leave() }
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
            group.notify(queue: .main, execute: completion)
        }
    }

    @available(macOS 14.0, *)
    private static func capture(_ scWindow: SCWindow, into window: WindowInfo, completion: @escaping () -> Void) {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = captureConfig(for: scWindow)
        SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { buffer, error in
            var image: CGImage?
            if let buffer, error == nil, let pixelBuffer = buffer.imageBuffer {
                image = cgImageFromPixelBuffer(pixelBuffer)
            }
            let finalImage = image ?? captureWithPrivateAPI(window.windowId)
            DispatchQueue.main.async {
                window.thumbnail = finalImage
                completion()
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

    // MARK: - Private fallback

    private static func captureAllWithPrivateAPI(_ windows: [WindowInfo], completion: @escaping () -> Void) {
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
        group.notify(queue: .main, execute: completion)
    }

    private static func captureWithPrivateAPI(_ wid: CGWindowID) -> CGImage? {
        var windowId = wid
        let list = CGSHWCaptureWindowList(CGS_CONNECTION, &windowId, 1,
                                          [.ignoreGlobalClipShape, .bestResolution, .fullSize])
            .takeRetainedValue() as! [CGImage]
        return list.first
    }

    // MARK: - Pixel buffer → CGImage

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
}
