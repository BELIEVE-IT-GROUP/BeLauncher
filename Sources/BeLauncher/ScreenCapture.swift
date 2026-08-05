import AppKit
import Vision
import ApplicationServices
import BeLauncherCore

/// Reads what is on screen, in the cheapest way that works.
///
/// Three routes, tried in order, because they cost wildly different amounts. A text selection read
/// through Accessibility is instant, exact and needs no new permission — most of the time it is the
/// answer. A file open in the front window is nearly as cheap. Only when neither works does this
/// fall back to photographing the screen and running text recognition, which is the slow one and
/// the one that needs Screen Recording.
///
/// Everything stays on the Mac: recognition is Apple's on-device Vision, no image is written to
/// disk, and nothing is uploaded anywhere. The recognised text goes to whichever model the person
/// chose, exactly like anything they had typed themselves.
@MainActor
enum ScreenCapture {

    /// Grabs the best context available right now.
    static func read() async -> ScreenContext {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""

        if let selection = selectedText(), selection.count >= ScreenReader.minimumLength {
            return ScreenContext(text: selection, origin: .selection, application: app)
        }
        if let path = frontmostDocumentPath() {
            return ScreenContext(text: (path as NSString).lastPathComponent, origin: .file,
                                 application: app, path: path)
        }
        if let recognised = await recogniseScreen(), recognised.count >= ScreenReader.minimumLength {
            return ScreenContext(text: recognised, origin: .recognised, application: app)
        }
        // Falling back to the clipboard keeps the shortcut from ever doing nothing at all.
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        return ScreenContext(text: clipboard, origin: .clipboard, application: app)
    }

    // MARK: - The cheap routes

    /// The focused element's selected text, straight from Accessibility.
    ///
    /// This is the same permission the app already asks for to paste and arrange windows, so for
    /// most people Screen-to-Action costs no new permission at all.
    static func selectedText() -> String? {
        guard Permissions.accessibilityGranted else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The document the front window is showing, when it is showing one.
    static func frontmostDocumentPath() -> String? {
        guard Permissions.accessibilityGranted,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                            &window) == .success,
              let focused = window else { return nil }

        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement,
                                            kAXDocumentAttribute as CFString,
                                            &document) == .success,
              let raw = document as? String,
              let url = URL(string: raw), url.isFileURL else { return nil }
        return url.path
    }

    // MARK: - The expensive route

    /// Photographs the active display and reads the text in it, on device.
    ///
    /// `CGWindowListCreateImage` is deprecated in favour of ScreenCaptureKit, which is async and
    /// heavier; for a single still frame this remains the direct route and it is the one that stops
    /// at a single frame, which matters for a feature people are right to be wary of.
    static func recogniseScreen() async -> String? {
        guard let image = captureScreen() else { return nil }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.isEmpty
                                    ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["es-ES", "en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    static func captureScreen() -> CGImage? {
        guard let screen = NSScreen.main else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        return CGWindowListCreateImage(bounds, .optionOnScreenOnly, kCGNullWindowID,
                                       [.bestResolution, .nominalResolution])
    }

    /// Whether macOS will let us photograph the screen. Asking without checking pops the system
    /// dialog, which should only ever happen at a moment the person understands.
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }
}
