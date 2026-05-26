import Cocoa

/// The content view of the switcher overlay. Lays out TileViews in rows,
/// with each tile's width adapted to its thumbnail's aspect ratio.
final class OverlayView: NSVisualEffectView {

    private var tileViews: [TileView] = []
    private var selectedIndex: Int = 0
    private var windows: [WindowInfo] = []

    /// Called when user clicks a tile. Wired by AppDelegate.
    var onClickedTile: (() -> Void)?

    // Layout constants
    private let interTilePadding: CGFloat = 6
    private let outerPadding: CGFloat = 16
    private let cornerRadius: CGFloat = 14
    private var trackingArea: NSTrackingArea?

    /// Max width of the overlay as a fraction of screen width
    private var maxPanelWidth: CGFloat {
        (NSScreen.main?.frame.width ?? 1920) * 0.85
    }

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
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = tileIndex(at: point) {
            setSelectedIndex(index)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = tileIndex(at: point) {
            setSelectedIndex(index)
            onClickedTile?()
        }
    }

    /// Returns the tile index at the given point, or nil.
    private func tileIndex(at point: NSPoint) -> Int? {
        for (i, tile) in tileViews.enumerated() {
            if tile.frame.contains(point) {
                return i
            }
        }
        return nil
    }

    // MARK: - Public

    /// Update the view with new window data. Recalculates layout and resizes the panel.
    func update(windows: [WindowInfo], selectedIndex: Int) {
        self.windows = windows
        self.selectedIndex = selectedIndex

        // Remove old tiles
        for tile in tileViews { tile.removeFromSuperview() }
        tileViews.removeAll()

        guard !windows.isEmpty else { return }

        // Create tiles
        for (i, window) in windows.enumerated() {
            let tile = TileView(frame: .zero)
            tile.configure(with: window)
            tile.isHighlighted = (i == selectedIndex)
            addSubview(tile)
            tileViews.append(tile)
        }

        layoutTiles()
    }

    /// Refresh tile thumbnails in-place, then re-layout since widths may change.
    func refreshThumbnails() {
        for (i, tile) in tileViews.enumerated() where i < windows.count {
            tile.configure(with: windows[i])
        }
        layoutTiles()

        // Resize panel to match
        if let panel = window as? OverlayPanel {
            panel.setContentSize(frame.size)
            panel.showCentered()
        }
    }

    // MARK: - Flow layout

    /// Lay out tiles in rows, wrapping when a row exceeds maxPanelWidth.
    /// Tiles have variable widths but uniform height.
    private func layoutTiles() {
        let tileH = TileView.tileHeight
        let maxW = maxPanelWidth - outerPadding * 2

        // Compute per-tile widths
        let tileWidths: [CGFloat] = windows.map { TileView.tileWidth(for: $0) }

        // Break into rows
        var rows: [[Int]] = [[]]  // rows of tile indices
        var currentRowWidth: CGFloat = 0

        for (i, w) in tileWidths.enumerated() {
            let needed = currentRowWidth > 0 ? interTilePadding + w : w
            if currentRowWidth + needed > maxW && !rows[rows.count - 1].isEmpty {
                // Start new row
                rows.append([i])
                currentRowWidth = w
            } else {
                rows[rows.count - 1].append(i)
                currentRowWidth += needed
            }
        }

        // Compute actual row widths (for centering) and total panel size
        var rowWidths: [CGFloat] = []
        for row in rows {
            let w = row.reduce(CGFloat(0)) { $0 + tileWidths[$1] }
                + CGFloat(max(0, row.count - 1)) * interTilePadding
            rowWidths.append(w)
        }

        let widestRow = rowWidths.max() ?? 0
        let totalW = widestRow + outerPadding * 2
        let totalH = outerPadding * 2 + tileH * CGFloat(rows.count)
            + interTilePadding * CGFloat(max(0, rows.count - 1))

        frame.size = NSSize(width: totalW, height: totalH)

        // Position tiles — centered per row, top row at top (NSView y=0 is bottom)
        for (rowIdx, row) in rows.enumerated() {
            let rowW = rowWidths[rowIdx]
            var x = outerPadding + (widestRow - rowW) / 2
            let y = totalH - outerPadding - tileH - CGFloat(rowIdx) * (tileH + interTilePadding)

            for tileIdx in row {
                let w = tileWidths[tileIdx]
                tileViews[tileIdx].frame = CGRect(x: x, y: y, width: w, height: tileH)
                x += w + interTilePadding
            }
        }
    }

    // MARK: - Selection

    func setSelectedIndex(_ index: Int) {
        guard index >= 0, index < tileViews.count else { return }
        if selectedIndex < tileViews.count {
            tileViews[selectedIndex].isHighlighted = false
        }
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
        let next = (selectedIndex + 1) % windows.count
        setSelectedIndex(next)
    }

    func cycleBackward() {
        guard !windows.isEmpty else { return }
        let prev = (selectedIndex - 1 + windows.count) % windows.count
        setSelectedIndex(prev)
    }

    func selectedWindow() -> WindowInfo? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }
}
