import AppKit
import Testing
@testable import BeLauncher

@Suite("Brain window sizing")
struct BrainWindowSizingTests {

    @Test("the Brain opens as a workspace on a normal Mac display")
    func normalDisplayGetsLargeWorkspace() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = BrainWindowSizing.frame(in: visible)
        let minimum = BrainWindowSizing.minimumSize(in: visible)

        #expect(frame.width == 1360)
        #expect(frame.height == 852)
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
        #expect(minimum.width == 1120)
        #expect(minimum.height == 740)
    }

    @Test("small displays are respected instead of pushing the title bar off screen")
    func smallDisplayIsCapped() {
        let visible = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let frame = BrainWindowSizing.frame(in: visible)
        let minimum = BrainWindowSizing.minimumSize(in: visible)

        #expect(frame.width == 976)
        #expect(frame.height == 592)
        #expect(frame.minX >= visible.minX)
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
        #expect(minimum.width <= frame.width)
        #expect(minimum.height <= frame.height)
    }

    @Test("a previously small Brain window grows when reopened")
    func smallExistingWindowGrows() {
        let target = BrainWindowSizing.frame(in: NSRect(x: 0, y: 0, width: 1440, height: 900))
        let small = NSRect(x: 100, y: 100, width: 960, height: 620)
        let alreadyLarge = NSRect(x: 100, y: 100, width: target.width, height: target.height)

        #expect(BrainWindowSizing.shouldGrow(current: small, toward: target))
        #expect(!BrainWindowSizing.shouldGrow(current: alreadyLarge, toward: target))
    }
}
