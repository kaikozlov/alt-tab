import Cocoa

/// The content view of the switcher overlay. Owns TileViews and delegates flow-layout math to TileLayout.
final class OverlayView: NSVisualEffectView {
    private var tileViews: [TileView] = []
    private var selectedIndex = 0
    private var windows: [WindowInfo] = []
    private var trackingArea: NSTrackingArea?

    var onClickedTile: (() -> Void)?

    private let interTilePadding: CGFloat = 6
    private let outerPadding: CGFloat = 16
    private let cornerRadius: CGFloat = 14
    private var maxPanelWidth: CGFloat { (NSScreen.main?.frame.width ?? 1920) * 0.85 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setup() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
    }

    // MARK: - Mouse tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = tileIndex(at: convert(event.locationInWindow, from: nil)) { setSelectedIndex(index) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = tileIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        setSelectedIndex(index)
        onClickedTile?()
    }

    private func tileIndex(at point: NSPoint) -> Int? {
        for (i, tile) in tileViews.enumerated() where tile.frame.contains(point) { return i }
        return nil
    }

    // MARK: - Public

    func update(windows: [WindowInfo], selectedIndex: Int) {
        self.windows = windows
        self.selectedIndex = selectedIndex
        for tile in tileViews { tile.removeFromSuperview() }
        tileViews.removeAll()
        guard !windows.isEmpty else { return }
        for (i, window) in windows.enumerated() {
            let tile = TileView(frame: .zero)
            tile.configure(with: window)
            tile.isHighlighted = (i == selectedIndex)
            addSubview(tile)
            tileViews.append(tile)
        }
        layoutTiles()
    }

    func refreshThumbnails() {
        for (i, tile) in tileViews.enumerated() where i < windows.count { tile.configure(with: windows[i]) }
        layoutTiles()
        if let panel = window as? OverlayPanel {
            panel.setContentSize(frame.size)
            panel.showCentered()
        }
    }

    func setSelectedIndex(_ index: Int) {
        guard index >= 0, index < tileViews.count else { return }
        if selectedIndex < tileViews.count { tileViews[selectedIndex].isHighlighted = false }
        selectedIndex = index
        tileViews[selectedIndex].isHighlighted = true
    }

    func getSelectedIndex() -> Int {
        return selectedIndex
    }

    func windowCount() -> Int {
        return windows.count
    }

    func cycleForward() {
        guard !windows.isEmpty else { return }
        setSelectedIndex((selectedIndex + 1) % windows.count)
    }

    func cycleBackward() {
        guard !windows.isEmpty else { return }
        setSelectedIndex((selectedIndex - 1 + windows.count) % windows.count)
    }

    func selectedWindow() -> WindowInfo? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }

    // MARK: - Layout

    private func layoutTiles() {
        let widths = windows.map { TileView.tileWidth(for: $0) }
        let layout = TileLayout.calculate(tileWidths: widths, tileHeight: TileView.tileHeight,
                                          maxWidth: maxPanelWidth, outerPadding: outerPadding,
                                          interTilePadding: interTilePadding)
        frame.size = layout.size
        for (i, tileFrame) in layout.frames.enumerated() where i < tileViews.count {
            tileViews[i].frame = tileFrame
        }
    }
}
