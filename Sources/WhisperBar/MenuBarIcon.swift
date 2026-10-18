import AppKit

/// Menu bar glyph, drawn in code (no image assets).
///   .off       outlined mic  : server stopped / starting
///   .ready     filled mic    : server ready
///   .recording red filled    : microphone is live
enum MenuBarIcon {
    enum State { case off, ready, recording }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let color: NSColor = state == .recording ? .systemRed : .black
            color.setFill()
            color.setStroke()

            // Capsule
            let capsule = NSRect(x: 6, y: 7, width: 6, height: 9.5)
            if state == .off {
                let outline = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.65, dy: 0.65), xRadius: 2.35, yRadius: 2.35)
                outline.lineWidth = 1.3
                outline.stroke()
            } else {
                NSBezierPath(roundedRect: capsule, xRadius: 3, yRadius: 3).fill()
            }

            // Holder arc (lower half circle)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9.5), radius: 5.4, startAngle: 180, endAngle: 360)
            arc.lineWidth = 1.4
            arc.lineCapStyle = .round
            arc.stroke()

            // Stem and base
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 9, y: 4.1)); stand.line(to: NSPoint(x: 9, y: 2.0))
            stand.move(to: NSPoint(x: 6.5, y: 2.0)); stand.line(to: NSPoint(x: 11.5, y: 2.0))
            stand.lineWidth = 1.4
            stand.lineCapStyle = .round
            stand.stroke()
            return true
        }
        image.isTemplate = state != .recording     // template = auto black/white; recording stays red
        return image
    }
}
