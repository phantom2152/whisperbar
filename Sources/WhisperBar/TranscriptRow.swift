import AppKit

/// One saved take in the History list.
@MainActor
final class TranscriptRow: NSView {
    var onCopy: (@MainActor () -> Void)?
    var onExport: (@MainActor (NSView) -> Void)?
    var onDelete: (@MainActor () -> Void)?

    private var copyButton: IconButton!
    private var exportButton: IconButton!

    init(transcript: Transcript) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        widthAnchor.constraint(equalToConstant: UI.contentWidth).isActive = true

        let text = NSTextField(wrappingLabelWithString: transcript.text)
        text.font = .systemFont(ofSize: 13)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        text.preferredMaxLayoutWidth = 186
        text.toolTip = transcript.text

        let meta = UI.label("\(Formats.display.string(from: transcript.date)) · \(Formats.duration(transcript.duration))",
                            size: 11, color: .tertiaryLabelColor)

        let textColumn = NSStackView(views: [text, meta])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.widthAnchor.constraint(equalToConstant: 186).isActive = true

        copyButton = IconButton(symbol: "doc.on.doc", tooltip: "Copy", side: 26, symbolSize: 12,
                                target: self, action: #selector(copyTapped))
        exportButton = IconButton(symbol: "square.and.arrow.up", tooltip: "Export…", side: 26, symbolSize: 12,
                                  target: self, action: #selector(exportTapped))
        let deleteButton = IconButton(symbol: "trash", tooltip: "Delete", side: 26, symbolSize: 12,
                                      target: self, action: #selector(deleteTapped))

        let stack = NSStackView(views: [textColumn, copyButton, exportButton, deleteButton])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func copyTapped() {
        onCopy?()
        copyButton.setSymbol("checkmark")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.copyButton.setSymbol("doc.on.doc")
        }
    }

    @objc private func exportTapped() { onExport?(exportButton) }
    @objc private func deleteTapped() { onDelete?() }
}
