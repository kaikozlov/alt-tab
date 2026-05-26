import Cocoa
import ScreenCaptureKit

private final class PermissionProbe: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result = false

    func finish(_ granted: Bool) {
        lock.lock(); result = granted; lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime = .now() + 5) -> Bool {
        _ = semaphore.wait(timeout: timeout)
        lock.lock(); let value = result; lock.unlock()
        return value
    }
}

@MainActor
enum Permissions {

    /// Block until both Accessibility and Screen Recording are granted.
    /// Shows alerts directing the user to System Settings if needed.
    static func ensureGranted() {
        ensureAccessibility()
        ensureScreenRecording()
    }

    // MARK: - Accessibility

    private static func ensureAccessibility() {
        if AXIsProcessTrustedWithOptions(nil) { return }
        let opts = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "AltTab needs Accessibility access to track windows.\n\nPlease grant it in System Settings → Privacy & Security → Accessibility, then click OK."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Quit")

        while !AXIsProcessTrustedWithOptions(nil) {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSApp.terminate(nil)
                return
            }
        }
    }

    // MARK: - Screen Recording

    private static func ensureScreenRecording() {
        var granted = hasScreenRecordingAccess()
        if granted { return }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "AltTab needs Screen Recording access to capture window thumbnails.\n\nPlease grant it in System Settings → Privacy & Security → Screen Recording, then click OK."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Continue Without Thumbnails")

        while !granted {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }
            granted = hasScreenRecordingAccess()
        }
    }

    private static func hasScreenRecordingAccess() -> Bool {
        let probe = PermissionProbe()
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            probe.finish(error == nil && content != nil)
        }
        return probe.wait()
    }
}
