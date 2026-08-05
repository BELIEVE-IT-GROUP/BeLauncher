import AppKit
import ApplicationServices
import BeLauncherCore

/// Moves and resizes the front window of whatever app the user was in.
///
/// This is the one feature that genuinely needs Accessibility, because macOS gives no other way
/// to touch another app's window. The permission is requested here, in context, the first time a
/// window command runs — not at launch alongside everything else.
@MainActor
enum WindowArranger {

    /// Returns a message when it could not do it, so the caller can say so instead of doing
    /// nothing visible.
    @discardableResult
    static func arrange(_ rawLayout: String) -> String? {
        guard let layout = WindowCommand.Layout(rawValue: rawLayout) else { return nil }

        guard Permissions.requestAccessibility(
            reason: "Colocar ventanas es lo único que macOS no deja hacer sin este permiso."
        ) else {
            return "Necesito permiso de Accesibilidad para mover ventanas de otras apps."
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "No hay ninguna ventana delante."
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return "\(app.localizedName ?? "Esa app") no expone su ventana a macOS."
        }
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)

        guard let current = frame(of: axWindow) else {
            return "No pude leer el tamaño de la ventana."
        }
        guard let screen = screen(containing: current) else { return "No encontré la pantalla." }

        let target: WindowLayoutMath.Frame
        switch layout {
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1, let index = screens.firstIndex(of: screen) else {
                return "Solo hay una pantalla."
            }
            let step = layout == .nextDisplay ? 1 : -1
            let destination = screens[(index + step + screens.count) % screens.count]
            target = WindowLayoutMath.fit(current,
                                          from: flipped(screen.visibleFrame),
                                          to: flipped(destination.visibleFrame))
        default:
            guard let frame = WindowLayoutMath.frame(for: layout, in: flipped(screen.visibleFrame)) else {
                return nil
            }
            target = frame
        }

        set(frame: target, on: axWindow)
        return nil
    }

    // MARK: - Accessibility plumbing

    /// Accessibility uses top-left origin coordinates while NSScreen uses bottom-left, so screen
    /// rectangles are flipped once here and every layout works in a single space.
    private static func flipped(_ rect: NSRect) -> WindowLayoutMath.Frame {
        let totalHeight = NSScreen.screens.first?.frame.maxY ?? rect.maxY
        return WindowLayoutMath.Frame(
            x: rect.origin.x,
            y: totalHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func frame(of window: AXUIElement) -> WindowLayoutMath.Frame? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return WindowLayoutMath.Frame(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    private static func set(frame: WindowLayoutMath.Frame, on window: AXUIElement) {
        var origin = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        // Position first, then size: some apps clamp a size that would fall off the old screen.
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        }
    }

    private static func screen(containing frame: WindowLayoutMath.Frame) -> NSScreen? {
        let centre = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        return NSScreen.screens.first { flippedContains(flipped($0.visibleFrame), centre) }
            ?? NSScreen.main
    }

    private static func flippedContains(_ frame: WindowLayoutMath.Frame, _ point: CGPoint) -> Bool {
        point.x >= frame.x && point.x <= frame.x + frame.width
            && point.y >= frame.y && point.y <= frame.y + frame.height
    }
}
