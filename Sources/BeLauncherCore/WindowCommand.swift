import Foundation

/// Window management: the piece people miss most when they leave Alfred or Raycast.
///
/// Each command is a pure geometry function — given the visible screen area, return the frame the
/// front window should take. That keeps every layout testable without a window on screen, and the
/// app layer only has to apply the result.
public struct WindowCommand: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let keywords: [String]
    public let symbol: String
    public let layout: Layout

    public enum Layout: String, Sendable, Equatable, CaseIterable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case leftThird, centreThird, rightThird
        case leftTwoThirds, centreTwoThirds, rightTwoThirds
        case maximise, centre, almostMaximise
        case nextDisplay, previousDisplay
    }

    public init(id: String, title: String, keywords: [String], symbol: String, layout: Layout) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.symbol = symbol
        self.layout = layout
    }

    public static let all: [WindowCommand] = [
        .init(id: "left-half", title: L("Window: left half"), keywords: ["izquierda", "left", "half"],
              symbol: "rectangle.lefthalf.filled", layout: .leftHalf),
        .init(id: "right-half", title: L("Window: right half"), keywords: ["derecha", "right", "half"],
              symbol: "rectangle.righthalf.filled", layout: .rightHalf),
        .init(id: "top-half", title: L("Window: top half"), keywords: ["arriba", "top"],
              symbol: "rectangle.tophalf.filled", layout: .topHalf),
        .init(id: "bottom-half", title: L("Window: bottom half"), keywords: ["abajo", "bottom"],
              symbol: "rectangle.bottomhalf.filled", layout: .bottomHalf),
        .init(id: "top-left", title: L("Window: top left corner"), keywords: ["cuarto", "quarter"],
              symbol: "rectangle.inset.topleft.filled", layout: .topLeft),
        .init(id: "top-right", title: L("Window: top right corner"), keywords: ["cuarto", "quarter"],
              symbol: "rectangle.inset.topright.filled", layout: .topRight),
        .init(id: "bottom-left", title: L("Window: bottom left corner"), keywords: ["cuarto", "quarter"],
              symbol: "rectangle.inset.bottomleft.filled", layout: .bottomLeft),
        .init(id: "bottom-right", title: L("Window: bottom right corner"), keywords: ["cuarto", "quarter"],
              symbol: "rectangle.inset.bottomright.filled", layout: .bottomRight),
        .init(id: "left-third", title: L("Window: left third"), keywords: ["tercio", "third"],
              symbol: "rectangle.split.3x1", layout: .leftThird),
        .init(id: "centre-third", title: L("Window: centre third"), keywords: ["tercio", "third", "centro"],
              symbol: "rectangle.split.3x1.fill", layout: .centreThird),
        .init(id: "right-third", title: L("Window: right third"), keywords: ["tercio", "third"],
              symbol: "rectangle.split.3x1", layout: .rightThird),
        .init(id: "left-two-thirds", title: L("Window: left two thirds"), keywords: ["tercios"],
              symbol: "rectangle.lefthalf.inset.filled", layout: .leftTwoThirds),
        .init(id: "centre-two-thirds", title: L("Window: centred two thirds"),
              keywords: ["dos tercios", "centro", "two thirds", "center"],
              symbol: "rectangle.center.inset.filled", layout: .centreTwoThirds),
        .init(id: "right-two-thirds", title: L("Window: right two thirds"), keywords: ["tercios"],
              symbol: "rectangle.righthalf.inset.filled", layout: .rightTwoThirds),
        .init(id: "maximise", title: L("Window: maximise"), keywords: ["maximizar", "maximize", "full"],
              symbol: "rectangle.fill", layout: .maximise),
        .init(id: "almost-maximise", title: L("Window: almost maximise"), keywords: ["casi", "almost"],
              symbol: "rectangle.inset.filled", layout: .almostMaximise),
        .init(id: "centre", title: L("Window: centre"), keywords: ["centrar", "centre", "center"],
              symbol: "rectangle.center.inset.filled", layout: .centre),
        .init(id: "next-display", title: L("Window: next display"), keywords: ["pantalla", "monitor", "display"],
              symbol: "display.2", layout: .nextDisplay),
        .init(id: "previous-display", title: L("Window: previous display"), keywords: ["pantalla", "monitor"],
              symbol: "display.2", layout: .previousDisplay),
    ]

    public static func search(_ query: String) -> [(command: WindowCommand, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }
        let needle = Fuzzy.folded(trimmed)
        return all.compactMap { command in
            let candidates = [command.title] + command.keywords
            guard let best = candidates
                .compactMap({ Fuzzy.score(needle: needle, hay: Fuzzy.folded($0)) })
                .max() else { return nil }
            return (command, best)
        }
        .sorted { $0.score > $1.score }
    }
}

/// The geometry, kept free of AppKit so every layout can be asserted without a screen.
public enum WindowLayoutMath {
    /// A rectangle in the same coordinate space as the visible screen area it is given.
    public struct Frame: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// `visible` is the usable area of the screen, already excluding menu bar and Dock.
    /// Returns nil for the layouts that mean "move to another screen", which need more than maths.
    public static func frame(for layout: WindowCommand.Layout, in visible: Frame) -> Frame? {
        let halfWidth = visible.width / 2
        let halfHeight = visible.height / 2
        let third = visible.width / 3

        switch layout {
        case .leftHalf:
            return Frame(x: visible.x, y: visible.y, width: halfWidth, height: visible.height)
        case .rightHalf:
            return Frame(x: visible.x + halfWidth, y: visible.y, width: halfWidth, height: visible.height)
        case .topHalf:
            return Frame(x: visible.x, y: visible.y, width: visible.width, height: halfHeight)
        case .bottomHalf:
            return Frame(x: visible.x, y: visible.y + halfHeight, width: visible.width, height: halfHeight)
        case .topLeft:
            return Frame(x: visible.x, y: visible.y, width: halfWidth, height: halfHeight)
        case .topRight:
            return Frame(x: visible.x + halfWidth, y: visible.y, width: halfWidth, height: halfHeight)
        case .bottomLeft:
            return Frame(x: visible.x, y: visible.y + halfHeight, width: halfWidth, height: halfHeight)
        case .bottomRight:
            return Frame(x: visible.x + halfWidth, y: visible.y + halfHeight, width: halfWidth, height: halfHeight)
        case .leftThird:
            return Frame(x: visible.x, y: visible.y, width: third, height: visible.height)
        case .centreThird:
            return Frame(x: visible.x + third, y: visible.y, width: third, height: visible.height)
        case .rightThird:
            return Frame(x: visible.x + third * 2, y: visible.y, width: third, height: visible.height)
        case .leftTwoThirds:
            return Frame(x: visible.x, y: visible.y, width: third * 2, height: visible.height)
        case .centreTwoThirds:
            // Centred with a third's worth of margin split either side: the shape for reading
            // something long on a wide display without it stretching across the whole thing.
            return Frame(x: visible.x + third / 2, y: visible.y,
                         width: third * 2, height: visible.height)
        case .rightTwoThirds:
            return Frame(x: visible.x + third, y: visible.y, width: third * 2, height: visible.height)
        case .maximise:
            return visible
        case .almostMaximise:
            // The layout people actually use all day: full height, generous margins.
            let inset = min(visible.width, visible.height) * 0.06
            return Frame(x: visible.x + inset, y: visible.y + inset,
                         width: visible.width - inset * 2, height: visible.height - inset * 2)
        case .centre:
            let width = visible.width * 0.6
            let height = visible.height * 0.7
            return Frame(x: visible.x + (visible.width - width) / 2,
                         y: visible.y + (visible.height - height) / 2,
                         width: width, height: height)
        case .nextDisplay, .previousDisplay:
            return nil
        }
    }

    /// Keeps a window's proportions when it lands on a screen of a different size.
    public static func fit(_ frame: Frame, from source: Frame, to destination: Frame) -> Frame {
        let scaleX = destination.width / source.width
        let scaleY = destination.height / source.height
        let width = min(frame.width * scaleX, destination.width)
        let height = min(frame.height * scaleY, destination.height)
        let x = destination.x + (frame.x - source.x) * scaleX
        let y = destination.y + (frame.y - source.y) * scaleY
        return Frame(
            x: min(max(x, destination.x), destination.x + destination.width - width),
            y: min(max(y, destination.y), destination.y + destination.height - height),
            width: width, height: height
        )
    }
}
