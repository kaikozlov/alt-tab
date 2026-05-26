import Cocoa

/// The app delegate. Wires everything together.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: OverlayPanel!
    private var overlayView: OverlayView!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Check permissions
        Permissions.ensureGranted()

        // 2. Start window tracking
        WindowManager.shared.start()

        // 3. Set up the overlay panel (hidden initially)
        overlayView = OverlayView(frame: .zero)
        panel = OverlayPanel(contentRect: .zero)
        panel.contentView = overlayView

        // 4. Wire up hotkey callbacks
        setupHotkeys()

        // 5. Start listening for Cmd+Tab
        Hotkey.shared.start()

        // 6. Menu bar icon (minimal — just shows we're running + quit)
        setupStatusItem()

        NSLog("[AltTab] Ready — Cmd+Tab to switch windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Hotkey.shared.stop()
    }

    // MARK: - Hotkey wiring

    private func setupHotkeys() {
        Hotkey.shared.onActivate = { [weak self] in
            self?.showSwitcher()
        }

        Hotkey.shared.onCycleForward = { [weak self] in
            self?.overlayView.cycleForward()
        }

        Hotkey.shared.onCycleBackward = { [weak self] in
            self?.overlayView.cycleBackward()
        }

        Hotkey.shared.onConfirm = { [weak self] in
            self?.confirmSelection()
        }

        Hotkey.shared.onCancel = { [weak self] in
            self?.dismissSwitcher()
        }
    }

    // MARK: - Switcher lifecycle

    private func showSwitcher() {
        let windows = WindowManager.shared.sortedWindows()
        guard !windows.isEmpty else { return }

        // Capture all thumbnails FIRST (parallel, ~5-10ms total), then show panel.
        // CGSHWCaptureWindowList is synchronous and fast, so this doesn't block perceptibly.
        Hotkey.shared.setPanelOpen(true)
        ThumbnailCapture.captureAll(windows) { [weak self] in
            guard let self, Hotkey.shared.panelIsOpen else { return }

            let initialIndex = windows.count > 1 ? 1 : 0
            self.overlayView.update(windows: windows, selectedIndex: initialIndex)
            self.panel.setContentSize(self.overlayView.frame.size)
            self.panel.showCentered()
        }
    }

    private func confirmSelection() {
        guard let window = overlayView.selectedWindow() else {
            dismissSwitcher()
            return
        }
        dismissSwitcher()
        window.focus()
    }

    private func dismissSwitcher() {
        panel.dismiss()
        Hotkey.shared.setPanelOpen(false)
        ThumbnailCapture.releaseAll(WindowManager.shared.sortedWindows())
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "AltTab")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About AltTab", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}
