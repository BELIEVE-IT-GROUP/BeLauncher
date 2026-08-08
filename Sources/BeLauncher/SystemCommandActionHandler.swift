import Foundation
import BeLauncherCore

/// First real adapter behind the BEL contract. The gate owns confirmation and capability policy;
/// this adapter only translates the stable ID to the existing closed command implementation.
struct SystemCommandActionHandler: BELActionHandler {
    let actionID: String
    private let rawKind: String

    init?(definition: BELActionDefinition) {
        guard definition.kind == .native,
              definition.adapter == .allowlistedShell,
              let rawKind = BELActionCatalog.systemCommandKind(for: definition.id) else {
            return nil
        }
        self.actionID = definition.id
        self.rawKind = rawKind
    }

    func perform(input: Data) async throws -> BELActionResult {
        let failure = await MainActor.run {
            // R2/R3 confirmation has already happened in BELActionExecutor.
            SystemCommandRunner.run(rawKind, confirm: { _ in true })
        }
        if let failure { throw SystemCommandActionError.failed(failure) }
        return BELActionResult(text: "", receipt: "system:\(rawKind)")
    }
}

enum SystemCommandActionError: Error, Equatable {
    case failed(String)
}
