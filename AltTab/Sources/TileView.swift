import Cocoa

/// A single window tile in the switcher overlay: thumbnail + app icon + title.
/// Tile width adapts to the thumbnail's aspect ratio. Height is fixed.
final class TileView: NSView {

    private let thumbnailLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let highlightLayer = CALayer()

    var window_: WindowInfo?
    var isHighlighted = false {
        didSet { updateHighlight() }
    }

    // Layout constants — height is fixed, width varies with aspect ratio
    static let thumbnailHeight: CGFloat = 170
    static let minThumbnailWidth: CGFloat = 130
    static let maxThumbnailWidth: CGFloat = 360
    static let iconSize: CGFloat = 26
    static let titleHeight: CGFloat = 22
    static let padding: CGFloat = 12
    static let titleGap: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    /// Fixed height for all tiles
    static var tileHeight: CGFloat {
        padding + thumbnailHeight + titleGap + max(iconSize, titleHeight) + padding
    }

    /// Compute tile width from a thumbnail's aspect ratio.
    static func tileWidth(for window: WindowInfo) -> CGFloat {
        let thumbW = thumbnailWidth(for: window)
        return thumbW + padding * 2
    }

    /// Compute thumbnail display width from a window's thumbnail or fallback dimensions.
    static func thumbnailWidth(for window: WindowInfo) -> CGFloat {
        let imageWidth: CGFloat
        let imageHeight: CGFloat

        if let thumb = window.thumbnail {
            imageWidth = CGFloat(thumb.width)
            imageHeight = CGFloat(thumb.height)
        } else {
            // Before thumbnails are captured, assume 16:10 (standard Mac ratio)
            imageWidth = 16
            imageHeight = 10
        }

        guard imageHeight > 0 else { return minThumbnailWidth }

        let ratio = imageWidth / imageHeight
        let w = (thumbnailHeight * ratio).rounded()
        return min(max(w, minThumbnailWidth), maxThumbnailWidth)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setup() {
        wantsLayer = true
        layer!.masksToBounds = false

        // Highlight (behind everything)
        highlightLayer.cornerRadius = TileView.cornerRadius
        highlightLayer.isHidden = true
        layer!.addSublayer(highlightLayer)

        // Thumbnail — resizeAspectFill + clip so the image fills the thumbnail area
        thumbnailLayer.contentsGravity = .resizeAspect
        thumbnailLayer.cornerRadius = 6
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.borderWidth = 0.5
        thumbnailLayer.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        layer!.addSublayer(thumbnailLayer)

        // App icon
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        // Title
        titleLabel.font = NSFont.systemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.alignment = .left
        addSubview(titleLabel)
    }

    func configure(with window: WindowInfo) {
        self.window_ = window

        // Thumbnail
        if let thumb = window.thumbnail {
            thumbnailLayer.contents = thumb
        } else {
            thumbnailLayer.contents = window.appIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        // App icon
        iconView.image = window.appIcon

        // Title
        let displayTitle: String
        if window.title == window.appName || window.title.isEmpty {
            displayTitle = window.appName
        } else {
            displayTitle = "\(window.appName) — \(window.title)"
        }
        titleLabel.stringValue = displayTitle
    }

    override func layout() {
        super.layout()
        let p = TileView.padding
        let w = bounds.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        highlightLayer.frame = bounds

        let thumbW = w - p * 2
        let thumbH = TileView.thumbnailHeight
        thumbnailLayer.frame = CGRect(x: p, y: p, width: thumbW, height: thumbH)

        let iconY = p + thumbH + TileView.titleGap
        iconView.frame = CGRect(x: p, y: iconY, width: TileView.iconSize, height: TileView.iconSize)

        let labelX = p + TileView.iconSize + 6
        let labelW = w - labelX - p
        let labelY = iconY + (TileView.iconSize - TileView.titleHeight) / 2
        titleLabel.frame = CGRect(x: labelX, y: labelY, width: labelW, height: TileView.titleHeight)

        CATransaction.commit()
    }

    private func updateHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isHighlighted {
            highlightLayer.isHidden = false
            highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        } else {
            highlightLayer.isHidden = true
        }

        CATransaction.commit()
    }
}
