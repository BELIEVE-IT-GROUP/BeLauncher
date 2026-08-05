import SwiftUI
import AppKit

enum Theme {
    static let panelWidth: CGFloat = 780
    /// Width of the result list when a detail pane is showing beside it.
    static let listWidth: CGFloat = 430
    static let corner: CGFloat = 20
    static let rowHeight: CGFloat = 52
    static let searchHeight: CGFloat = 64
    static let shadowPadding: CGFloat = 26
    static let accent = Color(nsColor: .controlAccentColor)
    /// Believe Blue 700 and Cyan 400 — the brand pair used by the mark.
    static let believeBlue = Color(red: 0.047, green: 0.231, blue: 0.725)
    static let cyan = Color(red: 0, green: 0.667, blue: 1)
    /// Bright enough to stay legible over the panel's translucent background, which sits over
    /// whatever the user happens to have on screen.
    static let destructive = Color(red: 1, green: 0.45, blue: 0.42)
}

/// Real window-level blur. `.ultraThinMaterial` alone looks flat over a moving desktop.
struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Glass edge: a hairline that is brighter at the top, like light landing on a pane.
struct GlassEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.08), .white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

struct KeyCap: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(minWidth: 17, minHeight: 16)
                .padding(.horizontal, 3)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.10)))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func applicationIcon(path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 28, height: 28)
        icons[path] = icon
        return icon
    }
}

extension String {
    /// Bolds the characters the fuzzy matcher hit, so the ranking is legible.
    func highlighting(_ indices: [Int]) -> AttributedString {
        var attributed = AttributedString(self)
        guard !indices.isEmpty else { return attributed }
        let hits = Set(indices)
        var index = attributed.characters.startIndex
        var offset = 0
        while index < attributed.characters.endIndex {
            let next = attributed.characters.index(after: index)
            if hits.contains(offset) {
                attributed[index..<next].font = .system(size: 14, weight: .heavy)
                attributed[index..<next].foregroundColor = Theme.accent
            }
            index = next
            offset += 1
        }
        return attributed
    }
}
