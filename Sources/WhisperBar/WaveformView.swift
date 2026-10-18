import AppKit

/// Scrolling level meter: newest bar on the right.
@MainActor
final class WaveformView: NSView {
    private var levels: [CGFloat] = []
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2

    func reset() { levels.removeAll(); needsDisplay = true }

    func push(_ level: CGFloat) {
        levels.append(level)
        let maxBars = max(1, Int(bounds.width / (barWidth + gap)))
        if levels.count > maxBars { levels.removeFirst(levels.count - maxBars) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = barWidth + gap
        let maxBars = max(1, Int(bounds.width / step))
        for k in 0..<maxBars {
            let idx = levels.count - maxBars + k
            let live = idx >= 0
            (live ? NSColor.systemRed : NSColor.tertiaryLabelColor).setFill()
            let h = max(3, (live ? levels[idx] : 0) * bounds.height)
            let r = NSRect(x: bounds.minX + CGFloat(k) * step, y: bounds.midY - h / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: r, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}
