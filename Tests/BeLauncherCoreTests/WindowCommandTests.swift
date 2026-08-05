import Testing
import Foundation
@testable import BeLauncherCore

@Suite("Window management")
struct WindowCommandTests {

    /// A 1440x900 usable area starting at the origin, in the top-left space Accessibility uses.
    private let screen = WindowLayoutMath.Frame(x: 0, y: 0, width: 1440, height: 900)

    @Test("halves cover the screen exactly, with no gap and no overlap")
    func halves() {
        let left = WindowLayoutMath.frame(for: .leftHalf, in: screen)!
        let right = WindowLayoutMath.frame(for: .rightHalf, in: screen)!
        #expect(left == .init(x: 0, y: 0, width: 720, height: 900))
        #expect(right == .init(x: 720, y: 0, width: 720, height: 900))
        #expect(left.width + right.width == screen.width)
        #expect(left.x + left.width == right.x)
    }

    @Test("quarters tile the screen")
    func quarters() {
        let corners: [WindowCommand.Layout] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let frames = corners.map { WindowLayoutMath.frame(for: $0, in: screen)! }
        #expect(frames.allSatisfy { $0.width == 720 && $0.height == 450 })
        let area = frames.reduce(0.0) { $0 + $1.width * $1.height }
        #expect(area == screen.width * screen.height)
    }

    @Test("thirds add up to the full width")
    func thirds() {
        let left = WindowLayoutMath.frame(for: .leftThird, in: screen)!
        let centre = WindowLayoutMath.frame(for: .centreThird, in: screen)!
        let right = WindowLayoutMath.frame(for: .rightThird, in: screen)!
        #expect(left.width + centre.width + right.width == screen.width)
        #expect(left.x + left.width == centre.x)
        #expect(centre.x + centre.width == right.x)
    }

    @Test("two-thirds layouts leave exactly one third free")
    func twoThirds() {
        let left = WindowLayoutMath.frame(for: .leftTwoThirds, in: screen)!
        let right = WindowLayoutMath.frame(for: .rightTwoThirds, in: screen)!
        #expect(left.width == screen.width / 3 * 2)
        #expect(right.x == screen.width / 3)
        #expect(right.x + right.width == screen.width)
    }

    @Test("maximise fills the usable area, and respects a menu bar offset")
    func maximise() {
        #expect(WindowLayoutMath.frame(for: .maximise, in: screen) == screen)

        let offset = WindowLayoutMath.Frame(x: 0, y: 25, width: 1440, height: 875)
        let maxed = WindowLayoutMath.frame(for: .maximise, in: offset)!
        #expect(maxed.y == 25, "a maximised window must never cover the menu bar")
    }

    @Test("almost-maximise and centre stay inside the screen")
    func insetLayouts() {
        for layout in [WindowCommand.Layout.almostMaximise, .centre] {
            let frame = WindowLayoutMath.frame(for: layout, in: screen)!
            #expect(frame.x >= screen.x)
            #expect(frame.y >= screen.y)
            #expect(frame.x + frame.width <= screen.x + screen.width)
            #expect(frame.y + frame.height <= screen.y + screen.height)
        }
    }

    @Test("every layout except display moves returns a frame")
    func everyLayoutCovered() {
        for layout in WindowCommand.Layout.allCases {
            let frame = WindowLayoutMath.frame(for: layout, in: screen)
            if layout == .nextDisplay || layout == .previousDisplay {
                #expect(frame == nil)
            } else {
                #expect(frame != nil, "\(layout) has no geometry")
            }
        }
    }

    @Test("moving to a smaller screen keeps the window on it")
    func fitToSmallerScreen() {
        let big = WindowLayoutMath.Frame(x: 0, y: 0, width: 3840, height: 2160)
        let small = WindowLayoutMath.Frame(x: 0, y: 0, width: 1440, height: 900)
        let window = WindowLayoutMath.Frame(x: 3000, y: 1800, width: 800, height: 600)

        let moved = WindowLayoutMath.fit(window, from: big, to: small)
        #expect(moved.x >= small.x)
        #expect(moved.y >= small.y)
        #expect(moved.x + moved.width <= small.x + small.width + 0.001)
        #expect(moved.y + moved.height <= small.y + small.height + 0.001)
    }

    @Test("commands are found by name and by shorthand, in Spanish")
    func search() {
        #expect(WindowCommand.search("izquierda").contains { $0.command.layout == .leftHalf })
        #expect(WindowCommand.search("maximizar").first?.command.layout == .maximise)
        #expect(WindowCommand.search("tercio").contains { $0.command.layout == .leftThird })
        #expect(WindowCommand.search("v").isEmpty, "one letter must not flood the list")
    }

    @Test("running one dismisses the window first, then arranges the app underneath")
    @MainActor
    func runOrder() {
        var performed: [LauncherModel.Action] = []
        let model = LauncherModel(dataSource: { SearchInput() }, perform: { performed.append($0) })
        model.activate()
        model.query = "maximizar"

        #expect(model.selected?.kind == .window)
        model.handle(.enter)
        #expect(performed == [.dismiss, .arrangeWindow(WindowCommand.Layout.maximise.rawValue)],
                "our own window must be gone before we touch the user's")
    }

    @Test("ids and layouts are unique so a payload resolves to one command")
    func uniqueness() {
        #expect(Set(WindowCommand.all.map(\.id)).count == WindowCommand.all.count)
        #expect(Set(WindowCommand.all.map(\.layout)).count == WindowCommand.all.count)
    }
}
