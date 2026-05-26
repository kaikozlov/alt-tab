import Cocoa

/// A single window tile in the switcher overlay: thumbnail + app icon + title.
final class TileView: NSView {

    private let thumbnailLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let highlightLayer = CALayer()

    var window_: WindowInfo?
    var isHighlighted = false {
        didSet { updateHighlight() }
    }

    // Layout constants
    static let thumbnailWidth: CGFloat = 200
    static let thumbnailHeight: CGFloat = 130
    static let iconSize: CGFloat = 20
    static let titleHeight: CGFloat = 18
    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 10

    static var tileWidth: CGFloat { thumbnailWidth + padding * 2 }
    static var tileHeight: CGFloat { padding + thumbnailHeight + 6 + iconSize + 2 + titleHeight + padding }

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

        // Thumbnail
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
        titleLabel.font = NSFont.systemFont(ofSize: 11)
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
            // Show app icon as placeholder
            thumbnailLayer.contents = window.appIcon?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        // App icon
        iconView.image = window.appIcon

        // Title — show "AppName — WindowTitle" or just title
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
        _ = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        highlightLayer.frame = bounds

        let thumbW = w - p * 2
        let thumbH = TileView.thumbnailHeight
        thumbnailLayer.frame = CGRect(x: p, y: p, width: thumbW, height: thumbH)

        let iconY = p + thumbH + 6
        iconView.frame = CGRect(x: p, y: iconY, width: TileView.iconSize, height: TileView.iconSize)

        let labelX = p + TileView.iconSize + 4
        let labelW = w - labelX - p
        titleLabel.frame = CGRect(x: labelX, y: iconY + 1, width: labelW, height: TileView.titleHeight)

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
