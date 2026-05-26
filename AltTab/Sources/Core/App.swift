import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var overlayView: OverlayView!
    private var statusItem: NSStatusItem?
    private let session = SwitcherSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.ensureGranted()
        WindowManager.shared.onChange = { [weak self] in self?.refreshSwitcherPanel() }
        WindowManager.shared.start()
        overlayView = OverlayView(frame: .zero)
        panel = OverlayPanel(contentRect: .zero)
        panel.contentView = overlayView
        setupHotkeys()
        overlayView.onClickedTile = { [weak self] in self?.confirmSelection() }
        Hotkey.shared.start()
        setupStatusItem()
        NSLog("[AltTab] Ready — Cmd+Tab to switch windows")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Hotkey.shared.stop()
    }

    // MARK: - Hotkey wiring

    private func setupHotkeys() {
        Hotkey.shared.onActivate = { [weak self] in self?.showSwitcher() }
        Hotkey.shared.onCycleForward = { [weak self] in self?.overlayView.cycleForward() }
        Hotkey.shared.onCycleBackward = { [weak self] in self?.overlayView.cycleBackward() }
        Hotkey.shared.onConfirm = { [weak self] in self?.confirmSelection() }
        Hotkey.shared.onCancel = { [weak self] in self?.dismissSwitcher() }
        Hotkey.shared.onQuit = { [weak self] in self?.quitSelectedApp() }
        Hotkey.shared.onClose = { [weak self] in self?.closeSelectedWindow() }
    }

    // MARK: - Switcher lifecycle

    private func showSwitcher() {
        guard session.beginPreparing() else { return }
        WindowManager.shared.syncWithRunningApplications()
        let windows = WindowManager.shared.sortedWindows()
        guard !windows.isEmpty else { session.endPreparing(); return }
        ThumbnailCapture.releaseAll(windows)
        ThumbnailCapture.captureAll(windows) { [weak self] in
            guard let self else { return }
            self.session.endPreparing()
            guard NSEvent.modifierFlags.contains(.command) else { ThumbnailCapture.releaseAll(windows); return }
            Hotkey.shared.setPanelOpen(true)
            self.updatePanel(windows: windows, selectedIndex: 0)
        }
    }

    private func confirmSelection() {
        guard let window = overlayView.selectedWindow() else { dismissSwitcher(); return }
        dismissSwitcher()
        WindowManager.shared.markFocused(window)
        window.focus()
    }

    private func dismissSwitcher() {
        panel.dismiss()
        Hotkey.shared.setPanelOpen(false)
        ThumbnailCapture.releaseAll(WindowManager.shared.sortedWindows())
    }

    private func quitSelectedApp() {
        guard let window = overlayView.selectedWindow() else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        guard app.bundleIdentifier != "com.apple.finder" else { NSSound.beep(); return }
        if session.shouldForceQuit(pid: window.pid) { app.forceTerminate() } else { app.terminate() }
    }

    private func closeSelectedWindow() {
        guard let window = overlayView.selectedWindow() else { return }
        window.closeSoftly { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                WindowManager.shared.syncWithRunningApplications()
                self?.refreshSwitcherPanel()
            }
        }
    }

    private func refreshSwitcherPanel() {
        guard Hotkey.shared.panelIsOpen else { return }
        let windows = WindowManager.shared.sortedWindows()
        guard !windows.isEmpty else { dismissSwitcher(); return }
        let index = min(overlayView.getSelectedIndex(), windows.count - 1)
        if windows.contains(where: { $0.thumbnail == nil }) {
            refreshPanelAfterCapturingMissing(windows: windows, selectedIndex: index)
        } else {
            updatePanel(windows: windows, selectedIndex: index)
        }
    }

    private func refreshPanelAfterCapturingMissing(windows: [WindowInfo], selectedIndex: Int) {
        guard session.beginRefreshing() else { return }
        ThumbnailCapture.captureMissing(windows) { [weak self] in
            guard let self else { return }
            self.session.endRefreshing()
            guard Hotkey.shared.panelIsOpen else { return }
            self.updatePanel(windows: windows, selectedIndex: selectedIndex)
        }
    }

    private func updatePanel(windows: [WindowInfo], selectedIndex: Int) {
        overlayView.update(windows: windows, selectedIndex: selectedIndex)
        panel.setContentSize(overlayView.frame.size)
        panel.showCentered()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "AltTab")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "About AltTab", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}
