import Cocoa

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
        return thumbnailDisplaySize(for: window).width + padding * 2
    }

    static func thumbnailDisplaySize(for window: WindowInfo) -> CGSize {
        guard let source = window.contentSize, source.width > 0, source.height > 0 else {
            return CGSize(width: minThumbnailWidth, height: thumbnailHeight)
        }
        let imageWidth = source.width
        let imageHeight = source.height
        let imageRatio = imageWidth / imageHeight
        let thumbnailHeightMax = thumbnailHeight
        let thumbnailWidthMax = maxThumbnailWidth
        let boundedHeight = min(imageHeight, thumbnailHeightMax)
        let boundedWidth = min(imageWidth, thumbnailWidthMax)
        let thumbnailRatio = boundedWidth / boundedHeight
        let width: CGFloat
        let height: CGFloat
        if thumbnailRatio > imageRatio {
            height = boundedHeight
            width = imageWidth * height / imageHeight
        } else if thumbnailRatio < imageRatio {
            width = boundedWidth
            height = imageHeight * width / imageWidth
        } else {
            height = thumbnailHeightMax
            width = height / imageHeight * imageWidth
        }
        return CGSize(width: min(max(width.rounded(), minThumbnailWidth), maxThumbnailWidth),
                      height: min(height.rounded(), thumbnailHeightMax))
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

    private static let disabledLayerActions: [String: CAAction] = [
        "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(),
    ]

    private func setupThumbnail() {
        thumbnailLayer.contentsGravity = .resizeAspect
        thumbnailLayer.cornerRadius = 6
        thumbnailLayer.masksToBounds = true
        thumbnailLayer.borderWidth = 0.5
        thumbnailLayer.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        thumbnailLayer.actions = Self.disabledLayerActions
        thumbnailLayer.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
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
        setThumbnailContents(window.thumbnail)
        iconView.image = window.appIcon
        titleLabel.stringValue = displayTitle(for: window)
    }

    func setThumbnailContents(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnailLayer.contents = image
        CATransaction.commit()
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
        let thumbSize = windowInfo.map { TileView.thumbnailDisplaySize(for: $0) }
            ?? CGSize(width: bounds.width - p * 2, height: TileView.thumbnailHeight)
        let thumbX = p + max(0, (bounds.width - p * 2 - thumbSize.width) / 2)
        let thumbY = p + (TileView.thumbnailHeight - thumbSize.height) / 2
        thumbnailLayer.frame = CGRect(x: thumbX, y: thumbY, width: thumbSize.width, height: thumbSize.height)
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
