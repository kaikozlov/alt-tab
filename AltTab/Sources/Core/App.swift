import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: OverlayPanel!
    private var overlayView: OverlayView!
    private var statusItem: NSStatusItem?
    private let session = SwitcherSession()
    private var switcherWindows: [WindowInfo] = []
    private let refreshPanelThrottler = Throttler(delayInMs: 200)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.ensureGranted()
        WindowManager.shared.onChange = { [weak self] in
            guard self?.session.isSwitching == true, Hotkey.shared.panelIsOpen else { return }
            self?.refreshPanelThrottler.throttleOrProceed { self?.refreshSwitcherPanel() }
        }
        WindowManager.shared.suppressFocusRefresh = { [weak self] in self?.session.isSwitching == true }
        WindowManager.shared.refreshThumbnails = { ThumbnailCapture.refreshAsync($0) }
        ThumbnailCapture.switcherIsActive = { [weak self] in self?.session.isSwitching == true }
        ThumbnailCapture.onThumbnailUpdated = { [weak self] windowId in
            guard Hotkey.shared.panelIsOpen else { return }
            self?.overlayView.refreshThumbnail(for: windowId)
        }
        WindowManager.shared.start()
        overlayView = OverlayView(frame: .zero)
        panel = OverlayPanel(contentRect: .zero)
        panel.contentView = overlayView
        setupHotkeys()
        overlayView.onClickedTile = { [weak self] in self?.confirmSelection() }
        Hotkey.shared.start()
        setupStatusItem()
        ThumbnailCapture.refreshAsync(WindowManager.shared.sortedWindows())
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
        guard NSEvent.modifierFlags.contains(.command) else { confirmSelection(); return }
        buildUiAndShowPanel()
    }

    private func buildUiAndShowPanel() {
        guard session.isSwitching else { return }
        updatePanel(windows: switcherWindows, selectedIndex: session.selectedIndex)
        Hotkey.shared.setPanelOpen(true)
        ThumbnailCapture.refreshAsync(switcherWindows, source: .afterShowUi, prioritizedIds: prioritizedWindowIds())
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
        let selectedId = selectedSwitcherWindowId()
        let windows = mergeSwitcherWindows(with: WindowManager.shared.sortedWindows())
        guard !windows.isEmpty else { dismissSwitcher(); return }
        switcherWindows = windows
        let selectedIndex = selectedId.flatMap { id in windows.firstIndex(where: { $0.windowId == id }) }
            ?? min(overlayView.getSelectedIndex(), windows.count - 1)
        session.setSelectedIndex(selectedIndex, count: windows.count)
        updatePanel(windows: windows, selectedIndex: session.selectedIndex)
        ThumbnailCapture.refreshAsync(windows, source: .afterShowUi, prioritizedIds: prioritizedWindowIds())
    }

    private func prioritizedWindowIds() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for offset in [0, 1, -1, 2, -2] {
            let index = session.selectedIndex + offset
            guard switcherWindows.indices.contains(index) else { continue }
            ids.insert(switcherWindows[index].windowId)
        }
        return ids
    }

    private func selectedSwitcherWindowId() -> CGWindowID? {
        let index = overlayView.getSelectedIndex()
        guard switcherWindows.indices.contains(index) else { return nil }
        return switcherWindows[index].windowId
    }

    private func mergeSwitcherWindows(with managerWindows: [WindowInfo]) -> [WindowInfo] {
        let byId = Dictionary(uniqueKeysWithValues: managerWindows.map { ($0.windowId, $0) })
        var merged = switcherWindows.compactMap { byId[$0.windowId] }
        let known = Set(merged.map(\.windowId))
        merged.append(contentsOf: managerWindows.filter { !known.contains($0.windowId) })
        return merged
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
