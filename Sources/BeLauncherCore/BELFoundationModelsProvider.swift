import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Native Apple Intelligence adapter. It is optional at runtime: the SDK can be present while the
/// model is unavailable because the device, region or Apple Intelligence setting is not eligible.
public enum BELFoundationModelsRuntime {
    public static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }
}

@available(macOS 26.0, *)
public struct BELFoundationModelsProvider: BELLanguageModelProvider {
    public let providerID = "apple.foundation.models"
    public let capabilities: Set<ModelCapability> = [.chat]

    public init() {}

    private func session(for request: BELModelRequest) throws -> LanguageModelSession {
        guard SystemLanguageModel.default.isAvailable else {
            throw IntelligenceError.transport("Apple Foundation Models is unavailable on this Mac.")
        }
        let instructions = request.system.isEmpty ? nil : request.system
        return LanguageModelSession(instructions: instructions)
    }

    public func generate(_ request: BELModelRequest, model: String? = nil) async throws
        -> BELModelResponse {
        try Task.checkCancellation()
        let session = try session(for: request)
        let response = try await session.respond(
            to: request.prompt,
            options: GenerationOptions(maximumResponseTokens: request.maxTokens)
        )
        try Task.checkCancellation()
        return BELModelResponse(text: response.content, providerID: providerID,
                                model: model ?? "apple-foundation-models")
    }

    public func stream(_ request: BELModelRequest, model: String? = nil,
                       onFragment: @escaping @Sendable (String) -> Void) async throws
        -> BELModelResponse {
        try Task.checkCancellation()
        let session = try session(for: request)
        var stream = session.streamResponse(
            to: request.prompt,
            options: GenerationOptions(maximumResponseTokens: request.maxTokens)
        )
        var complete = ""
        for try await snapshot in stream {
            try Task.checkCancellation()
            let current = snapshot.content
            let fragment: String
            if current.hasPrefix(complete) {
                fragment = String(current.dropFirst(complete.count))
            } else {
                // A provider snapshot is expected to be cumulative. If Apple changes that
                // contract, preserve the visible text rather than dropping a fragment.
                fragment = current
            }
            if !fragment.isEmpty { onFragment(fragment) }
            complete = current
        }
        guard !complete.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.emptyAnswer
        }
        return BELModelResponse(text: complete, providerID: providerID,
                                model: model ?? "apple-foundation-models")
    }
}
#else

public enum BELFoundationModelsRuntime {
    public static let isAvailable = false
}

#endif
