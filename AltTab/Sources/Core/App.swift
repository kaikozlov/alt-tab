import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var overlayView: OverlayView!
    private var statusItem: NSStatusItem?
    private let session = SwitcherSession()
    private var switcherWindows: [WindowInfo] = []

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
        Hotkey.shared.onCycleForward = { [weak self] in self?.cycleSwitcher(1) }
        Hotkey.shared.onCycleBackward = { [weak self] in self?.cycleSwitcher(-1) }
        Hotkey.shared.onConfirm = { [weak self] in self?.confirmSelection() }
        Hotkey.shared.onCancel = { [weak self] in self?.dismissSwitcher() }
        Hotkey.shared.onQuit = { [weak self] in self?.quitSelectedApp() }
        Hotkey.shared.onClose = { [weak self] in self?.closeSelectedWindow() }
        Hotkey.shared.switcherIsActive = { [weak self] in self?.session.isSwitching == true }
    }

    // MARK: - Switcher lifecycle

    private func showSwitcher() {
        WindowManager.shared.syncWithRunningApplications()
        let windows = WindowManager.shared.sortedWindows()
        let index = initialSelectedIndex(for: windows)
        guard !windows.isEmpty, session.beginSwitching(selectedIndex: index) else { return }
        switcherWindows = windows
        ThumbnailCapture.releaseAll(windows)
        let generation = session.generation
        ThumbnailCapture.captureAll(windows) { [weak self] in
            guard let self else { return }
            self.session.endPreparing()
            guard self.session.isSwitching, self.session.generation == generation else { ThumbnailCapture.releaseAll(windows); return }
            guard NSEvent.modifierFlags.contains(.command) else { self.confirmSelection(); return }
            Hotkey.shared.setPanelOpen(true)
            self.updatePanel(windows: self.switcherWindows, selectedIndex: self.session.selectedIndex)
        }
    }

    private func cycleSwitcher(_ step: Int) {
        guard session.isSwitching else { return }
        session.cycleSelection(step, count: switcherWindows.count)
        if Hotkey.shared.panelIsOpen { overlayView.setSelectedIndex(session.selectedIndex) }
    }

    private func confirmSelection() {
        guard let window = selectedWindow() else { dismissSwitcher(); return }
        dismissSwitcher(); WindowManager.shared.markFocused(window); window.focus()
    }

    private func dismissSwitcher() {
        panel.dismiss()
        Hotkey.shared.setPanelOpen(false)
        ThumbnailCapture.releaseAll(switcherWindows.isEmpty ? WindowManager.shared.sortedWindows() : switcherWindows)
        switcherWindows.removeAll()
        session.endSwitching()
    }

    private func quitSelectedApp() {
        guard let window = selectedWindow() else { return }
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        guard app.bundleIdentifier != "com.apple.finder" else { NSSound.beep(); return }
        if session.shouldForceQuit(pid: window.pid) { app.forceTerminate() } else { app.terminate() }
    }

    private func closeSelectedWindow() {
        guard let window = selectedWindow() else { return }
        window.closeSoftly { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                WindowManager.shared.syncWithRunningApplications()
                self?.refreshSwitcherPanel()
            }
        }
    }

    private func refreshSwitcherPanel() {
        guard Hotkey.shared.panelIsOpen else { return }
        let windows = WindowManager.shared.sortedWindows()
        guard !windows.isEmpty else { dismissSwitcher(); return }
        switcherWindows = windows
        session.setSelectedIndex(min(overlayView.getSelectedIndex(), windows.count - 1), count: windows.count)
        if windows.contains(where: { $0.thumbnail == nil }) {
            refreshPanelAfterCapturingMissing(windows: windows, selectedIndex: session.selectedIndex)
        } else {
            updatePanel(windows: windows, selectedIndex: session.selectedIndex)
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
        panel.setContentSize(overlayView.frame.size); panel.showCentered()
    }

    private func selectedWindow() -> WindowInfo? {
        let windows = switcherWindows.isEmpty ? WindowManager.shared.sortedWindows() : switcherWindows
        let index = Hotkey.shared.panelIsOpen ? overlayView.getSelectedIndex() : session.selectedIndex
        session.setSelectedIndex(index, count: windows.count)
        return session.selectedIndex < windows.count ? windows[session.selectedIndex] : nil
    }

    private func initialSelectedIndex(for windows: [WindowInfo]) -> Int { windows.count > 1 ? 1 : 0 }

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
