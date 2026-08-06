import AppKit
import BeLauncherCore

/// BeLauncher inside the right-click menu of every app on the Mac.
///
/// macOS already has the surface people reach for when they have something selected and want
/// something done with it: right click → Servicios. It works in Mail, Notes, Safari, Xcode,
/// Preview, anywhere text can be selected, and it hands over exactly what the person highlighted —
/// no Accessibility permission, no OCR, no guessing.
///
/// That last part is why this is worth more than the screen shortcut: the whole difficulty of
/// "act on what I am looking at" is knowing what the person meant, and a Service is the operating
/// system answering that question for you.
@MainActor
final class ServiceProvider: NSObject {

    /// Set by the app so a service can run a verb and show the answer in the launcher.
    var runVerb: ((String, String) -> Void)?
    var writeNote: ((String) -> Void)?
    var remember: ((String, String) -> Void)?

    /// Registers the provider. Without this the menu entries exist and do nothing.
    static func install(_ provider: ServiceProvider) {
        NSApp.servicesProvider = provider
        // Tells macOS to re-read the app's advertised services now rather than whenever it next
        // feels like it, which otherwise makes a fresh install look broken.
        NSUpdateDynamicServices()
    }

    // MARK: - The services themselves

    /// Every entry has the same shape: take the selected text, hand it to the app, report back if
    /// something was wrong with what arrived.
    private func text(from pasteboard: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString>?) -> String? {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = L("Select some text first.") as NSString
            return nil
        }
        return text
    }

    @objc func translate(_ pasteboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        runVerb?("translate-es", text)
    }

    @objc func summarise(_ pasteboard: NSPasteboard, userData: String?,
                         error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        runVerb?("summarise", text)
    }

    @objc func fix(_ pasteboard: NSPasteboard, userData: String?,
                   error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        runVerb?("fix", text)
    }

    @objc func extractTasks(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        runVerb?("extract-tasks", text)
    }

    @objc func note(_ pasteboard: NSPasteboard, userData: String?,
                    error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        writeNote?(text)
    }

    @objc func rememberThis(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = text(from: pasteboard, error: error) else { return }
        // A memory is a proposal, here as everywhere: coming in through a right-click menu does
        // not make it something the company has decided.
        remember?(text, L("Selected in another app"))
    }
}
