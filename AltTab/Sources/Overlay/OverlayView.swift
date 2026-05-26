import Cocoa

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.windows = windows
        self.selectedIndex = selectedIndex
        resizeTilePool(to: windows.count)
        guard !windows.isEmpty else { return }
        for (i, window) in windows.enumerated() {
            let tile = tileViews[i]
            tile.configure(with: window)
            tile.isHighlighted = (i == selectedIndex)
            tile.layoutSubtreeIfNeeded()
        }
        layoutTiles()
    }

    private func resizeTilePool(to count: Int) {
        while tileViews.count > count { tileViews.removeLast().removeFromSuperview() }
        while tileViews.count < count {
            let tile = TileView(frame: .zero)
            tile.setThumbnailContents(nil)
            addSubview(tile)
            tileViews.append(tile)
        }
    }

    func refreshThumbnail(for windowId: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.windowId == windowId }), index < tileViews.count else { return }
        guard windows[index].thumbnail != nil else { return }
        let widthBefore = TileView.tileWidth(for: windows[index])
        tileViews[index].setThumbnailContents(windows[index].thumbnail)
        tileViews[index].layoutSubtreeIfNeeded()
        guard TileView.tileWidth(for: windows[index]) != widthBefore else { return }
        layoutTiles()
        (window as? OverlayPanel)?.setContentSize(frame.size)
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
