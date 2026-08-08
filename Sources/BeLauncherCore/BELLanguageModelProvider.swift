import Foundation

/// The model boundary used by Brain actions. The Brain asks for a capability and a typed
/// response; it never needs to know whether the answer came from Ollama, an OpenAI-compatible
/// server, or a direct cloud API.
public struct BELModelRequest: Sendable, Equatable {
    public let system: String
    public let prompt: String
    public let sensitivity: Sensitivity
    public let maxTokens: Int

    public init(system: String = "", prompt: String, sensitivity: Sensitivity = .personal,
                maxTokens: Int = 1024) {
        self.system = system
        self.prompt = prompt
        self.sensitivity = sensitivity
        self.maxTokens = maxTokens
    }
}

public struct BELModelResponse: Sendable, Equatable {
    public let text: String
    public let providerID: String
    public let model: String

    public init(text: String, providerID: String, model: String) {
        self.text = text
        self.providerID = providerID
        self.model = model
    }
}

public protocol BELLanguageModelProvider: Sendable {
    var providerID: String { get }
    var capabilities: Set<ModelCapability> { get }

    func generate(_ request: BELModelRequest, model: String?) async throws -> BELModelResponse
}

/// Adapter for every provider that speaks the configured HTTP contract. Keeping this adapter
/// small is intentional: authentication, vendor request shapes and response parsing stay in
/// `IntelligenceClient`, while callers get one stable Brain-facing API.
public struct BELHTTPModelProvider: BELLanguageModelProvider {
    public let descriptor: IntelligenceProvider
    public let capabilities: Set<ModelCapability>
    public let client: IntelligenceClient

    public var providerID: String { descriptor.id }

    public init(descriptor: IntelligenceProvider,
                capabilities: Set<ModelCapability> = [.chat],
                client: IntelligenceClient = IntelligenceClient()) {
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.client = client
    }

    public func generate(_ request: BELModelRequest, model: String? = nil) async throws -> BELModelResponse {
        let intelligenceRequest = IntelligenceRequest(
            system: request.system,
            prompt: request.prompt,
            sensitivity: request.sensitivity,
            maxTokens: request.maxTokens
        )
        let selectedModel = model ?? descriptor.defaultModel
        let text = try await client.answer(intelligenceRequest, using: descriptor, model: selectedModel)
        return BELModelResponse(text: text, providerID: providerID, model: selectedModel)
    }
}

public enum BELLanguageModelProviderFactory {
    /// Returns only providers present in the canonical chat catalogue. The factory does not
    /// invent Apple Foundation Models availability; that backend must be added once the target
    /// SDK exposes a runtime-checkable implementation.
    public static func httpProviders(
        client: IntelligenceClient = IntelligenceClient()
    ) -> [BELHTTPModelProvider] {
        IntelligenceProvider.all.map { provider in
            BELHTTPModelProvider(descriptor: provider, capabilities: [.chat], client: client)
        }
    }
}
