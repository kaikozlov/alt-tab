import Cocoa

/// The floating panel that displays the window switcher.
/// Non-activating so it doesn't steal focus from the current app.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(contentRect: NSRect) {
        self.init(contentRect: contentRect,
                  styleMask: .nonactivatingPanel,
                  backing: .buffered,
                  defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = .canJoinAllSpaces
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden

        // Filter this window out of our own thumbnail captures
        setAccessibilitySubrole(.unknown)
    }

    func showCentered() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY - panelSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 1
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        alphaValue = 0
        orderOut(nil)
    }
}
