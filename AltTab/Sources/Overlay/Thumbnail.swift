import Cocoa
@preconcurrency import ScreenCaptureKit

enum ThumbnailCapture {
    enum Source { case afterShowUi, externalEvent }

    @MainActor static var switcherIsActive: () -> Bool = { false }
    @MainActor static var onThumbnailUpdated: (CGWindowID) -> Void = { _ in }

    private static let captureInBackground = true
    private static let screenshotsQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "screenshots"
        queue.maxConcurrentOperationCount = 8
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    @available(macOS 14.0, *)
    private static let cachedSCWindows = LockedArray<SCWindow>()

    @MainActor
    static func refreshAsync(_ windows: [WindowInfo], source: Source = .externalEvent, prioritizedIds: Set<CGWindowID>? = nil) {
        guard captureInBackground || switcherIsActive() else { return }
        let eligible = windows.filter { $0.windowId != 0 }
        guard !eligible.isEmpty else { return }
        let prioritized = prioritizedIds ?? []
        let sorted = eligible.sorted { prioritized.contains($0.windowId) && !prioritized.contains($1.windowId) }
        let requests = sorted.map { CaptureRequest(windowId: $0.windowId, contentSize: $0.contentSize, window: $0) }
        if #available(macOS 14.0, *) {
            refreshWithSCKit(requests, source: source)
        } else {
            refreshWithPrivateAPI(requests, source: source)
        }
    }

    // MARK: - SCKit

    @available(macOS 14.0, *)
    private static func refreshWithSCKit(_ requests: [CaptureRequest], source: Source) {
        screenshotsQueue.addOperation {
            let (cached, missing) = sortCachedAndNotCached(requests)
            let byId = Dictionary(uniqueKeysWithValues: requests.map { ($0.windowId, $0) })
            for scWindow in cached {
                guard let request = byId[scWindow.windowID] else { continue }
                if request.window?.isMinimized == true { enqueuePrivateAPI(request, source: source) }
                else { capture(scWindow, request: request, source: source) }
            }
            guard !missing.isEmpty else { return }
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                guard let content, error == nil else {
                    refreshWithPrivateAPI(missing, source: source)
                    return
                }
                screenshotsQueue.addOperation {
                    cachedSCWindows.withLock { $0 = content.windows }
                    for request in missing {
                        if let scWindow = content.windows.first(where: { $0.windowID == request.windowId }) {
                            if request.window?.isMinimized == true { enqueuePrivateAPI(request, source: source) }
                            else { capture(scWindow, request: request, source: source) }
                        } else {
                            enqueuePrivateAPI(request, source: source)
                        }
                    }
                }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func sortCachedAndNotCached(_ requests: [CaptureRequest]) -> ([SCWindow], [CaptureRequest]) {
        cachedSCWindows.withLock { cache in
            let byId = Dictionary(uniqueKeysWithValues: cache.map { ($0.windowID, $0) })
            var cached = [SCWindow]()
            var missing = [CaptureRequest]()
            for request in requests {
                if let scWindow = byId[request.windowId], cachedFrameMatches(scWindow, request: request) {
                    cached.append(scWindow)
                } else {
                    missing.append(request)
                }
            }
            return (cached, missing)
        }
    }

    @available(macOS 14.0, *)
    private static func cachedFrameMatches(_ scWindow: SCWindow, request: CaptureRequest) -> Bool {
        guard let expected = request.contentSize else { return true }
        let actual = scWindow.frame.size
        return abs(actual.width - expected.width) <= 2 && abs(actual.height - expected.height) <= 2
    }

    @available(macOS 14.0, *)
    private static func capture(_ scWindow: SCWindow, request: CaptureRequest, source: Source) {
        screenshotsQueue.addOperation { [weak window = request.window] in
            guard let window else { return }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = captureConfig(for: scWindow)
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { buffer, error in
                var image: CGImage?
                if let buffer, error == nil, let pixelBuffer = buffer.imageBuffer {
                    image = cgImageFromPixelBuffer(pixelBuffer)
                }
                let finalImage = image ?? captureWithPrivateAPI(request.windowId)
                DispatchQueue.main.async { applyThumbnail(finalImage, to: window, source: source) }
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
        if w > 0, h > 0 {
            let fit = min(maxDim / w, maxDim / h, 1.0)
            config.width = max(1, Int(w * fit * scale))
            config.height = max(1, Int(h * fit * scale))
        }
        return config
    }

    // MARK: - Private API

    private static func refreshWithPrivateAPI(_ requests: [CaptureRequest], source: Source) {
        for request in requests { enqueuePrivateAPI(request, source: source) }
    }

    private static func enqueuePrivateAPI(_ request: CaptureRequest, source: Source) {
        screenshotsQueue.addOperation { [weak window = request.window] in
            guard let window else { return }
            let image = captureWithPrivateAPI(request.windowId)
            DispatchQueue.main.async { applyThumbnail(image, to: window, source: source) }
        }
    }

    private static func captureWithPrivateAPI(_ wid: CGWindowID) -> CGImage? {
        var windowId = wid
        let value = CGSHWCaptureWindowList(CGS_CONNECTION, &windowId, 1,
                                           [.ignoreGlobalClipShape, .bestResolution, .fullSize])
            .takeRetainedValue()
        guard let list = value as? [CGImage] else { return nil }
        return list.first
    }

    // MARK: - Shared

    private struct CaptureRequest {
        let windowId: CGWindowID
        let contentSize: CGSize?
        weak var window: WindowInfo?
    }

    @MainActor
    private static func applyThumbnail(_ image: CGImage?, to window: WindowInfo, source: Source) {
        if source == .afterShowUi, !switcherIsActive() { return }
        if window.thumbnail === image { return }
        window.thumbnail = image
        onThumbnailUpdated(window.windowId)
    }

    private static func cgImageFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue).rawValue)
        return context?.makeImage()
    }
}

private final class LockedArray<T>: @unchecked Sendable {
    private var items = [T]()
    private let lock = NSLock()
    func withLock<R>(_ body: (inout [T]) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&items)
    }
}
