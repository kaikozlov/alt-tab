import Cocoa

/// A single window tile in the switcher overlay: thumbnail + app icon + title.
final class TileView: NSView {
    private let thumbnailLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let highlightLayer = CALayer()

    var windowInfo: WindowInfo?
    var isHighlighted = false {
        didSet { updateHighlight() }
    }

    static let thumbnailHeight: CGFloat = 170
    static let minThumbnailWidth: CGFloat = 130
    static let maxThumbnailWidth: CGFloat = 360
    static let iconSize: CGFloat = 26
    static let titleHeight: CGFloat = 22
    static let padding: CGFloat = 12
    static let titleGap: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    static var tileHeight: CGFloat {
        padding + thumbnailHeight + titleGap + max(iconSize, titleHeight) + padding
    }

    static func tileWidth(for window: WindowInfo) -> CGFloat {
        return thumbnailWidth(for: window) + padding * 2
    }

    static func thumbnailWidth(for window: WindowInfo) -> CGFloat {
        let imageSize = thumbnailSize(for: window)
        guard imageSize.height > 0 else { return minThumbnailWidth }
        let width = (thumbnailHeight * imageSize.width / imageSize.height).rounded()
        return min(max(width, minThumbnailWidth), maxThumbnailWidth)
    }

    private static func thumbnailSize(for window: WindowInfo) -> CGSize {
        guard let thumb = window.thumbnail else { return CGSize(width: 16, height: 10) }
        return CGSize(width: thumb.width, height: thumb.height)
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
        layer?.masksToBounds = false
        setupHighlight()
        setupThumbnail()
        setupIcon()
        setupTitle()
    }

    private func setupHighlight() {
        highlightLayer.cornerRadius = TileView.cornerRadius
        highlightLayer.isHidden = true
        layer?.addSublayer(highlightLayer)
    }

    private func setupThumbnail() {
        thumbnailLayer.contentsGravity = .resizeAspect
        thumbnailLayer.cornerRadius = 6
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.borderWidth = 0.5
        thumbnailLayer.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        layer?.addSublayer(thumbnailLayer)
    }

    private func setupIcon() {
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)
    }

    private func setupTitle() {
        titleLabel.font = NSFont.systemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.alignment = .left
        addSubview(titleLabel)
    }

    func configure(with window: WindowInfo) {
        windowInfo = window
        thumbnailLayer.contents = window.thumbnail ?? window.appIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        iconView.image = window.appIcon
        titleLabel.stringValue = displayTitle(for: window)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayersAndViews()
        CATransaction.commit()
    }

    private func layoutLayersAndViews() {
        let p = TileView.padding
        highlightLayer.frame = bounds
        let thumbWidth = bounds.width - p * 2
        thumbnailLayer.frame = CGRect(x: p, y: p, width: thumbWidth, height: TileView.thumbnailHeight)
        let iconY = p + TileView.thumbnailHeight + TileView.titleGap
        iconView.frame = CGRect(x: p, y: iconY, width: TileView.iconSize, height: TileView.iconSize)
        let labelX = p + TileView.iconSize + 6
        let labelY = iconY + (TileView.iconSize - TileView.titleHeight) / 2
        titleLabel.frame = CGRect(x: labelX, y: labelY, width: bounds.width - labelX - p, height: TileView.titleHeight)
    }

    private func updateHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.isHidden = !isHighlighted
        highlightLayer.backgroundColor = isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor : nil
        CATransaction.commit()
    }

    private func displayTitle(for window: WindowInfo) -> String {
        guard window.title != window.appName, !window.title.isEmpty else { return window.appName }
        return "\(window.appName) — \(window.title)"
    }
}
