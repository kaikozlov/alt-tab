import Cocoa
import ScreenCaptureKit

enum Permissions {

    /// Block until both Accessibility and Screen Recording are granted.
    /// Shows alerts directing the user to System Settings if needed.
    static func ensureGranted() {
        ensureAccessibility()
        ensureScreenRecording()
    }

    // MARK: - Accessibility

    private static func ensureAccessibility() {
        // First check without prompt
        if AXIsProcessTrustedWithOptions(nil) { return }

        // Prompt the user
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)

        // Poll until granted
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
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            granted = (error == nil && content != nil)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)

        if granted { return }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "AltTab needs Screen Recording access to capture window thumbnails.\n\nPlease grant it in System Settings → Privacy & Security → Screen Recording, then click OK."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Continue Without Thumbnails")

        while !granted {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return }

            let sem2 = DispatchSemaphore(value: 0)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                granted = (error == nil && content != nil)
                sem2.signal()
            }
            _ = sem2.wait(timeout: .now() + 5)
        }
    }
}
