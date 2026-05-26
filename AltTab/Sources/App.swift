import Cocoa

/// The app delegate. Wires everything together.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: OverlayPanel!
    private var overlayView: OverlayView!
    private var statusItem: NSStatusItem?
    private var isPreparingSwitcher = false
    private var isRefreshingSwitcher = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Check permissions
        Permissions.ensureGranted()

        // 2. Start window tracking
        WindowManager.shared.onChange = { [weak self] in
            self?.refreshSwitcherPanel()
        }
        WindowManager.shared.start()

        // 3. Set up the overlay panel (hidden initially)
        overlayView = OverlayView(frame: .zero)
        panel = OverlayPanel(contentRect: .zero)
        panel.contentView = overlayView

        // 4. Wire up hotkey + mouse callbacks
        setupHotkeys()
        overlayView.onClickedTile = { [weak self] in
            self?.confirmSelection()
        }

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

        Hotkey.shared.onQuit = { [weak self] in
            self?.quitSelectedApp()
        }

        Hotkey.shared.onClose = { [weak self] in
            self?.closeSelectedWindow()
        }
    }

    // MARK: - Switcher lifecycle

    private func showSwitcher() {
        guard !isPreparingSwitcher else { return }
        WindowManager.shared.syncWithRunningApplications()
        let windows = WindowManager.shared.sortedWindows()
        guard !windows.isEmpty else { return }

        ThumbnailCapture.releaseAll(windows)
        isPreparingSwitcher = true
        ThumbnailCapture.captureAll(windows) { [weak self] in
            guard let self else { return }
            self.isPreparingSwitcher = false
            guard NSEvent.modifierFlags.contains(.command) else {
                ThumbnailCapture.releaseAll(windows)
                return
            }

            Hotkey.shared.setPanelOpen(true)
            self.overlayView.update(windows: windows, selectedIndex: 0)
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

    /// Quit the app owning the selected window. First press = graceful terminate,
    /// second press on same app = force terminate (same as reference).
    private var lastQuitPid: pid_t = 0
    private func quitSelectedApp() {
        guard let window = overlayView.selectedWindow() else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }

        // Don't quit Finder
        if app.bundleIdentifier == "com.apple.finder" {
            NSSound.beep()
            return
        }

        if lastQuitPid == window.pid {
            app.forceTerminate()
        } else {
            app.terminate()
            lastQuitPid = window.pid
        }

        // The KVO observer on runningApplications will fire removeApp(),
        // which removes windows and calls onChange -> refreshSwitcherPanel()
    }

    /// Close the selected window, equivalent to pressing its red close button.
    private func closeSelectedWindow() {
        guard let window = overlayView.selectedWindow() else { return }
        window.closeSoftly { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                WindowManager.shared.syncWithRunningApplications()
                self?.refreshSwitcherPanel()
            }
        }
    }

    /// Refresh the switcher panel with current window list, or dismiss if empty.
    /// Called by WindowManager.onChange whenever windows are added/removed.
    private func refreshSwitcherPanel() {
        guard Hotkey.shared.panelIsOpen, !isRefreshingSwitcher else { return }
        let windows = WindowManager.shared.sortedWindows()
        if windows.isEmpty {
            dismissSwitcher()
            return
        }

        let idx = min(overlayView.getSelectedIndex(), windows.count - 1)
        if windows.contains(where: { $0.thumbnail == nil }) {
            isRefreshingSwitcher = true
            ThumbnailCapture.captureMissing(windows) { [weak self] in
                guard let self else { return }
                self.isRefreshingSwitcher = false
                guard Hotkey.shared.panelIsOpen else { return }
                self.overlayView.update(windows: windows, selectedIndex: idx)
                self.panel.setContentSize(self.overlayView.frame.size)
                self.panel.showCentered()
            }
        } else {
            overlayView.update(windows: windows, selectedIndex: idx)
            panel.setContentSize(overlayView.frame.size)
            panel.showCentered()
        }
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
