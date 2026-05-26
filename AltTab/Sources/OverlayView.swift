import Cocoa

/// The content view of the switcher overlay. Lays out TileViews in rows.
final class OverlayView: NSVisualEffectView {

    private var tileViews: [TileView] = []
    private var selectedIndex: Int = 0
    private var windows: [WindowInfo] = []

    // Layout constants
    private let maxColumns = 8
    private let interTilePadding: CGFloat = 6
    private let outerPadding: CGFloat = 16
    private let cornerRadius: CGFloat = 14

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

        // Calculate layout
        let columns = min(windows.count, maxColumns)
        let rows = (windows.count + columns - 1) / columns

        let tileW = TileView.tileWidth
        let tileH = TileView.tileHeight
        let totalW = outerPadding * 2 + tileW * CGFloat(columns) + interTilePadding * CGFloat(columns - 1)
        let totalH = outerPadding * 2 + tileH * CGFloat(rows) + interTilePadding * CGFloat(rows - 1)

        // Resize self and panel
        frame.size = NSSize(width: totalW, height: totalH)
        if let panel = window as? OverlayPanel {
            panel.setContentSize(NSSize(width: totalW, height: totalH))
        }

        // Position tiles (top-left origin, row by row)
        for (i, tile) in tileViews.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = outerPadding + CGFloat(col) * (tileW + interTilePadding)
            // NSView coordinates: y=0 is bottom, so first row is at top
            let y = totalH - outerPadding - tileH - CGFloat(row) * (tileH + interTilePadding)
            tile.frame = CGRect(x: x, y: y, width: tileW, height: tileH)
        }
    }

    /// Move selection highlight.
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

    /// Cycle selection forward (wrapping)
    func cycleForward() {
        guard !windows.isEmpty else { return }
        let next = (selectedIndex + 1) % windows.count
        setSelectedIndex(next)
    }

    /// Cycle selection backward (wrapping)
    func cycleBackward() {
        guard !windows.isEmpty else { return }
        let prev = (selectedIndex - 1 + windows.count) % windows.count
        setSelectedIndex(prev)
    }

    /// Refresh tile thumbnails in-place without rebuilding layout.
    func refreshThumbnails() {
        for (i, tile) in tileViews.enumerated() where i < windows.count {
            tile.configure(with: windows[i])
        }
    }

    /// Get the currently selected window.
    func selectedWindow() -> WindowInfo? {
        guard selectedIndex >= 0, selectedIndex < windows.count else { return nil }
        return windows[selectedIndex]
    }
}
