import AppKit

/// The Brain is not a popover. It has a navigation rail, a command bar, reader surfaces, graph
/// controls and dense daily context, so a small utility-window size makes the top chrome collide
/// with the content. Size it like a workspace, while still respecting the visible display.
enum BrainWindowSizing {
    static let ideal = NSSize(width: 1360, height: 860)
    static let minimum = NSSize(width: 1120, height: 740)
    private static let margin: CGFloat = 48

    static func frame(in visible: NSRect) -> NSRect {
        let maxWidth = max(640, visible.width - margin)
        let maxHeight = max(520, visible.height - margin)
        let width = min(ideal.width, maxWidth)
        let height = min(ideal.height, maxHeight)
        let x = visible.midX - width / 2
        let preferredY = visible.midY - height / 2 + visible.height * 0.04
        let y = min(max(preferredY, visible.minY), visible.maxY - height)
        return NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height.rounded())
    }

    static func minimumSize(in visible: NSRect) -> NSSize {
        let target = frame(in: visible)
        return NSSize(width: min(minimum.width, target.width),
                      height: min(minimum.height, target.height))
    }

    static func shouldGrow(current: NSRect, toward target: NSRect) -> Bool {
        current.width < target.width * 0.96 || current.height < target.height * 0.96
    }
}
