import AppKit
import UniformTypeIdentifiers

enum ExportFormat {
    case txt, markdown

    var fileExtension: String { self == .txt ? "txt" : "md" }

    var contentType: UTType {
        switch self {
        case .txt: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

/// Shows the export menu (Save as .txt / .md, Share…) for one or many transcripts.
@MainActor
final class ExportController: NSObject {
    /// true while a save panel is up, so the tile doesn't auto-close underneath it
    var onBusy: (@MainActor (Bool) -> Void)?
    var onResult: (@MainActor (String) -> Void)?

    private var picker: NSSharingServicePicker?

    @MainActor
    private final class Request: NSObject {
        enum Kind { case save(ExportFormat), share }
        let items: [Transcript]
        let kind: Kind
        weak var anchor: NSView?
        init(items: [Transcript], kind: Kind, anchor: NSView) {
            self.items = items; self.kind = kind; self.anchor = anchor
        }
    }

    // MARK: Menu

    func showMenu(for items: [Transcript], from anchor: NSView) {
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, symbol: String, kind: Request.Kind) {
            let item = NSMenuItem(title: title, action: #selector(menuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.image = Symbols.image(symbol, size: 13, weight: .regular)
            item.representedObject = Request(items: items, kind: kind, anchor: anchor)
            menu.addItem(item)
        }
        add("Save as Text…", symbol: "doc.plaintext", kind: .save(.txt))
        add("Save as Markdown…", symbol: "doc.richtext", kind: .save(.markdown))
        menu.addItem(.separator())
        add("Share…", symbol: "square.and.arrow.up", kind: .share)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
    }

    @objc private func menuPicked(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? Request else { return }
        switch req.kind {
        case .save(let format): save(req.items, as: format)
        case .share: if let anchor = req.anchor { share(req.items, from: anchor) }
        }
    }

    // MARK: Save / share

    private func save(_ items: [Transcript], as format: ExportFormat) {
        onBusy?(true)
        defer { onBusy?(false) }
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName(for: items, format: format)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try render(items, as: format).write(to: url, atomically: true, encoding: .utf8)
            onResult?("Saved \(url.lastPathComponent)")
        } catch {
            NSSound.beep()
            onResult?("Couldn’t save: \(error.localizedDescription)")
        }
    }

    private func share(_ items: [Transcript], from anchor: NSView) {
        let picker = NSSharingServicePicker(items: [render(items, as: .txt)])
        self.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: Formatting

    private func suggestedName(for items: [Transcript], format: ExportFormat) -> String {
        if items.count == 1, let t = items.first {
            return "Transcript \(Formats.fileStamp.string(from: t.date)).\(format.fileExtension)"
        }
        return "WhisperBar transcripts \(Formats.dayStamp.string(from: Date())).\(format.fileExtension)"
    }

    func render(_ items: [Transcript], as format: ExportFormat) -> String {
        let ordered = items.sorted { $0.date < $1.date }          // oldest first
        switch format {
        case .txt:
            if ordered.count == 1 { return ordered[0].text + "\n" }
            return ordered
                .map { "[\(Formats.stamp.string(from: $0.date))]\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        case .markdown:
            let header = ordered.count > 1 ? "# WhisperBar transcripts\n\n" : ""
            return header + ordered
                .map { "## \(Formats.stamp.string(from: $0.date))\n\n\($0.text)" }
                .joined(separator: "\n\n") + "\n"
        }
    }
}
