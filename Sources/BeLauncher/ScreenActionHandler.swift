import Foundation
import BeLauncherCore

struct BELScreenContextInput: Codable, Sendable {
    let whole: Bool

    init(whole: Bool = false) {
        self.whole = whole
    }
}

/// Exposes the existing, consent-aware screen reader through the stable action contract.
/// `screen.read_context` never escalates to a screenshot; `screen.ocr` is a separate explicit
/// action because it needs Screen Recording permission and photographs one frame.
struct ScreenActionHandler: BELActionHandler {
    let actionID: String

    init?(definition: BELActionDefinition) {
        guard definition.kind == .native,
              definition.adapter == .publicAPI,
              ["screen.read_context", "screen.ocr"].contains(definition.id)
        else { return nil }
        actionID = definition.id
    }

    func perform(input: Data) async throws -> BELActionResult {
        switch actionID {
        case "screen.read_context":
            if !input.isEmpty,
               try JSONDecoder().decode(BELScreenContextInput.self, from: input).whole {
                throw ScreenActionError.useOCRAction
            }
            let context = await ScreenCapture.read(whole: false)
            guard !context.isEmpty else { throw ScreenActionError.noContext }
            return BELActionResult(text: context.text, receipt: "screen:context:\(context.origin.rawValue)")
        case "screen.ocr":
            guard await ScreenCapture.screenRecordingGranted else {
                throw ScreenActionError.permission
            }
            guard let text = await ScreenCapture.recogniseScreen(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScreenActionError.noTextRecognised
            }
            return BELActionResult(text: text, receipt: "screen:ocr")
        default:
            throw ScreenActionError.unknownAction(actionID)
        }
    }
}

enum ScreenActionError: Error, Equatable {
    case permission
    case noContext
    case noTextRecognised
    case useOCRAction
    case unknownAction(String)
}
