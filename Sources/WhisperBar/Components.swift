import AppKit

// MARK: - SF Symbols

enum Symbols {
    static func image(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}

// MARK: - Date / duration formats

@MainActor
enum Formats {
    static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let stamp = posix("yyyy-MM-dd HH:mm")
    static let fileStamp = posix("yyyy-MM-dd HHmm")
    static let dayStamp = posix("yyyy-MM-dd")

    private static func posix(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Layout helpers

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }     // so scroll content starts at the top
}

@MainActor
enum UI {
    static let tileWidth: CGFloat = 320
    static let contentWidth: CGFloat = 292    // tileWidth minus 14pt insets

    @discardableResult
    static func fixedWidth<V: NSView>(_ v: V, _ width: CGFloat = UI.contentWidth) -> V {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    static func spacer() -> NSView {
        let s = NSView()
        s.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return s
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.distribution = .fill
        r.alignment = .centerY
        r.spacing = spacing
        return fixedWidth(r)
    }

    static func column(_ views: [NSView]) -> NSStackView {
        let c = NSStackView(views: views)
        c.orientation = .vertical
        c.alignment = .leading
        c.spacing = 10
        c.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        c.translatesAutoresizingMaskIntoConstraints = false
        c.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true
        return c
    }

    static func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return fixedWidth(b)
    }

    static func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.lineBreakMode = .byTruncatingTail
        return t
    }

    static func paragraph(_ s: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size)
        t.textColor = color
        t.preferredMaxLayoutWidth = contentWidth
        return fixedWidth(t)
    }
}

// MARK: - Icon button

/// Borderless symbol button with a hover highlight. Pass `fill` for a solid round button.
@MainActor
final class IconButton: NSButton {
    private let side: CGFloat
    private let symbolSize: CGFloat
    private var fill: NSColor?
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refreshBackground() } }

    init(symbol: String, tooltip: String, side: CGFloat = 28, symbolSize: CGFloat = 14,
         fill: NSColor? = nil, target: AnyObject?, action: Selector?) {
        self.side = side
        self.symbolSize = symbolSize
        self.fill = fill
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        self.target = target
        self.action = action
        toolTip = tooltip
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        setSymbol(symbol)
        setFill(fill)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) { image = Symbols.image(name, size: symbolSize) }

    func setFill(_ color: NSColor?) {
        fill = color
        contentTintColor = color == nil ? .secondaryLabelColor : .white
        refreshBackground()
    }

    /// Colors the symbol (for buttons without a solid fill).
    func setTint(_ color: NSColor) { contentTintColor = color }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.35; refreshBackground() }
    }

    private func refreshBackground() {
        guard let layer else { return }
        if let fill {
            layer.cornerRadius = side / 2
            let shown = (hovering && isEnabled) ? (fill.blended(withFraction: 0.18, of: .white) ?? fill) : fill
            layer.backgroundColor = shown.cgColor
        } else {
            layer.cornerRadius = 7
            layer.backgroundColor = (hovering && isEnabled)
                ? NSColor.labelColor.withAlphaComponent(0.10).cgColor : nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
