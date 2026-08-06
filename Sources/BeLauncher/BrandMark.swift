import SwiftUI
import AppKit

/// The BeLauncher glyph: a chevron (launch) over a command bar, closed by the fixed cyan dot.
/// Vector, not the app-icon PNG — so it stays crisp at 14pt in the search field and can be
/// rendered as a monochrome template for the menu bar.
struct BeLauncherMark: View {
    var side: CGFloat = 22
    var color: Color = .primary
    /// The cyan signature dot. Nil for monochrome surfaces such as the menu bar.
    var dot: Color? = Theme.cyan

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: point(0.15, 0.42))
                path.addLine(to: point(0.50, 0.19))
                path.addLine(to: point(0.85, 0.42))
            }
            .stroke(color, style: StrokeStyle(lineWidth: side * 0.115, lineCap: .round, lineJoin: .round))

            Path { path in
                path.addRoundedRect(
                    in: CGRect(x: side * 0.15, y: side * 0.655, width: side * 0.47, height: side * 0.115),
                    cornerSize: CGSize(width: side * 0.0575, height: side * 0.0575)
                )
            }
            .fill(color)

            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: side * 0.155, height: side * 0.155)
                    .offset(x: side * 0.70, y: side * 0.635)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: side * x, y: side * y)
    }
}

extension BeLauncherMark {
    /// Monochrome template image for the status item; macOS tints it for light/dark menu bars.
    @MainActor
    static func menuBarImage(side: CGFloat = 18) -> NSImage? {
        let renderer = ImageRenderer(content: BeLauncherMark(side: side, color: .black, dot: nil))
        renderer.scale = 3
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

/// The real app icon — blue glass tile, cyan edge and all — for places big enough to show it.
/// Falls back to the vector glyph when running outside a bundle (`swift run` during development).
@MainActor
struct AppIconView: View {
    var side: CGFloat

    static let artwork: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIconArt", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        // Deliberately not NSApp.applicationIconImage: macOS 26 hands that back already wrapped
        // in the system's own icon tile, which shows up as a grey frame around the artwork.
        if let icon = AppIconView.artwork {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        } else {
            BeLauncherMark(side: side, color: Theme.believeBlue)
        }
    }
}

/// The mascot, shown where the app is seen rarely and large.
///
/// Not in the command bar and not in the menu bar, and that is a decision rather than an
/// oversight: at 26 and 18 points the arms, the legs and the specular highlights collapse into a
/// blue smudge, and that mark appears fifty times a day — character at that frequency stops being
/// character and becomes noise. Here, where it is seen once or while waiting, it is the whole
/// point.
@MainActor
struct Mascot: View {
    var height: CGFloat = 120
    /// Breathes gently while something is being waited for.
    var isWorking = false

    @State private var lifted = false

    var body: some View {
        Group {
            if let image = Mascot.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // A build without the artwork still shows something rather than a hole.
                BeLauncherMark(side: height * 0.7)
            }
        }
        .frame(height: height)
        .offset(y: lifted ? -5 : 0)
        .animation(isWorking
                   ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                   : .default,
                   value: lifted)
        .onAppear { if isWorking { lifted = true } }
        .onChange(of: isWorking) { _, working in lifted = working }
        .accessibilityHidden(true)
    }

    /// Loaded once: this appears in list rows and reading the file per frame would be silly.
    static let image: NSImage? = {
        guard let path = Bundle.main.path(forResource: "Mascot", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }()
}
