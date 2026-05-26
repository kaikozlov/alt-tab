import Cocoa
import ScreenCaptureKit

/// On-demand window thumbnail capture. No background polling.
///
/// Primary path: SCScreenCaptureKit (macOS 14+) via `desktopIndependentWindow` filter.
/// This captures full window content regardless of on-screen position — critical for
/// AeroSpace and other tiling WMs that "hide" windows by parking them offscreen.
///
/// Fallback: CGSHWCaptureWindowList (private API) for minimized windows, which SCKit can't capture.
enum ThumbnailCapture {

    private static let captureQueue = DispatchQueue(label: "dev.kai.AltTab.capture", attributes: .concurrent)

    /// Capture thumbnails for all windows, then call completion on main thread.
    /// Fetches SCShareableContent once, then captures all windows from that snapshot.
    static func captureAll(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        guard !windows.isEmpty else { completion(); return }

        // Split minimized vs normal — different capture paths
        let minimized = windows.filter { $0.isMinimized }
        let normal = windows.filter { !$0.isMinimized }

        let group = DispatchGroup()

        // Minimized windows: private API (only thing that works)
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

        // Normal windows: SCScreenCaptureKit (captures full content regardless of position)
        if !normal.isEmpty {
            group.enter()
            if #available(macOS 14.0, *) {
                captureWithSCKit(normal) {
                    group.leave()
                }
            } else {
                // Pre-macOS 14: fall back to private API for everything
                let innerGroup = DispatchGroup()
                for window in normal {
                    innerGroup.enter()
                    captureQueue.async {
                        let image = captureWithPrivateAPI(window.windowId)
                        DispatchQueue.main.async {
                            window.thumbnail = image
                            innerGroup.leave()
                        }
                    }
                }
                innerGroup.notify(queue: .main) {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion()
        }
    }

    // MARK: - SCScreenCaptureKit (primary path for normal windows)

    /// Fetch SCShareableContent once, then capture all windows from that single snapshot.
    /// `desktopIndependentWindow` captures full window content regardless of screen position,
    /// which is why this works correctly for AeroSpace-managed offscreen windows.
    @available(macOS 14.0, *)
    private static func captureWithSCKit(_ windows: [WindowInfo], completion: @escaping () -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            guard let content, error == nil else {
                // Fall back to private API for all
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

            // Build lookup: windowId → SCWindow
            var scWindowMap: [CGWindowID: SCWindow] = [:]
            for scWin in content.windows {
                scWindowMap[scWin.windowID] = scWin
            }

            let group = DispatchGroup()
            for window in windows {
                group.enter()
                if let scWindow = scWindowMap[window.windowId] {
                    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                    let config = SCStreamConfiguration()
                    config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA

                    // Capture at reasonable thumbnail size
                    let maxDim: CGFloat = 400
                    let scale = NSScreen.main?.backingScaleFactor ?? 2
                    let w = CGFloat(scWindow.frame.width)
                    let h = CGFloat(scWindow.frame.height)
                    if w > 0 && h > 0 {
                        let fit = min(maxDim / w, maxDim / h, 1.0)
                        config.width = max(1, Int(w * fit * scale))
                        config.height = max(1, Int(h * fit * scale))
                    }

                    SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { buffer, captureError in
                        var image: CGImage?
                        if let buffer, captureError == nil, let pixelBuffer = buffer.imageBuffer {
                            image = cgImageFromPixelBuffer(pixelBuffer)
                        }
                        DispatchQueue.main.async {
                            window.thumbnail = image
                            group.leave()
                        }
                    }
                } else {
                    // Not found in SCShareableContent — try private API
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

    // MARK: - Private API (fallback for minimized windows)

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

    /// Release all thumbnails to free memory when the panel is hidden.
    static func releaseAll(_ windows: [WindowInfo]) {
        for window in windows {
            window.thumbnail = nil
        }
    }
}
