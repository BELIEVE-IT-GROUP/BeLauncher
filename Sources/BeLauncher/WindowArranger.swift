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
    /// Arranges a window, on `target` when one is given.
    ///
    /// The target has to be passed in, and that is the whole fix: summoning the launcher calls
    /// `NSApp.activate`, so by the time this runs the frontmost application *is* BeLauncher. Asking
    /// the system who is in front therefore always answered "us", and every attempt came back
    /// "No hay ninguna ventana delante" — the app looking at its own window and reporting the room
    /// empty. Who was in front before the panel appeared is the only thing that means anything
    /// here, and only the caller knows it.
    static func arrange(_ rawLayout: String, on target: NSRunningApplication? = nil) -> String? {
        guard let layout = WindowCommand.Layout(rawValue: rawLayout) else { return nil }

        guard Permissions.requestAccessibility(
            reason: "Colocar ventanas es lo único que macOS no deja hacer sin este permiso."
        ) else {
            return "Necesito permiso de Accesibilidad para mover ventanas de otras apps."
        }

        let candidate = target ?? NSWorkspace.shared.frontmostApplication
        guard let app = candidate,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "No hay ninguna ventana delante. Abre una app, súmmona BeLauncher encima y "
                 + "vuelve a intentarlo."
        }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue else {
            return "\(app.localizedName ?? "Esa app") no expone su ventana a macOS."
        }
        let axWindow = unsafeBitCast(window, to: AXUIElement.self)

        // A window in full screen reports its size and refuses to move, so arranging it looks
        // like nothing happened. Say so instead.
        var fullScreenValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, "AXFullScreen" as CFString,
                                         &fullScreenValue) == .success,
           (fullScreenValue as? Bool) == true {
            return "«\(app.localizedName ?? "Esa app")» está en pantalla completa y macOS no deja "
                 + "mover esas ventanas. Sácala de pantalla completa y vuelve a intentarlo."
        }

        // Read once, and once more after a beat: the launcher has just closed and some apps take
        // a moment to answer while their window is still settling. One retry turns a race into a
        // pause nobody notices.
        var reading = read(axWindow)
        if case .failed = reading {
            Thread.sleep(forTimeInterval: 0.15)
            reading = read(axWindow)
        }
        guard case .ok(let current) = reading else {
            if case .failed(let why) = reading { return why }
            return "No pude leer la ventana."
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axWindow, kAXPositionAttribute as CFString, &settable)
        guard settable.boolValue else {
            return "«\(app.localizedName ?? "Esa app")» no deja que se muevan sus ventanas. "
                 + "Suele pasar con ventanas de sistema y diálogos."
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

    /// Reads position and size, saying which one failed and with what error.
    ///
    /// "No pude leer el tamaño de la ventana" had four different causes behind it and named none,
    /// which is useless to the person and useless to whoever has to fix it. `-25204` is macOS
    /// saying the app did not answer in time; `-25211` is the Accessibility permission missing.
    enum Reading {
        case ok(WindowLayoutMath.Frame)
        /// A sentence for the person, not an error type: nothing rethrows this.
        case failed(String)
    }

    private static func read(_ window: AXUIElement) -> Reading {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionStatus = AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionValue)
        let sizeStatus = AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeValue)

        guard positionStatus == .success, sizeStatus == .success,
              let positionValue, let sizeValue else {
            let failing = positionStatus == .success ? sizeStatus : positionStatus
            return .failed(explain(failing))
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return .failed("Esa ventana devolvió un tamaño que no tiene sentido.")
        }
        return .ok(WindowLayoutMath.Frame(x: origin.x, y: origin.y,
                                          width: size.width, height: size.height))
    }

    /// What an AXError means, in words, plus what to do about it.
    static func explain(_ error: AXError) -> String {
        switch error {
        case .apiDisabled:
            "Falta el permiso de Accesibilidad. Ajustes del sistema › Privacidad y seguridad › "
            + "Accesibilidad, y activa BeLauncher."
        case .notImplemented, .attributeUnsupported:
            "Esa app no le cuenta a macOS dónde está su ventana, así que no se puede colocar."
        case .cannotComplete:
            "La app no respondió a tiempo. Si acaba de abrirse o está ocupada, prueba otra vez."
        case .invalidUIElement:
            "La ventana cambió mientras la miraba. Vuelve a intentarlo."
        default:
            "macOS no dejó leer la ventana (error \(error.rawValue)). Ejecuta "
            + "«BeLauncher --diagnose-windows» y mándanos lo que salga."
        }
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
