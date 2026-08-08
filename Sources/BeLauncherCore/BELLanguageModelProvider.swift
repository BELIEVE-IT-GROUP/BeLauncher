import Foundation

/// Stable product identity for whichever local runtime currently serves the Brain.
public enum BELLocalCore {
    public static let id = "bebrain.local.core"
}

/// The model boundary used by Brain actions. The Brain asks for a capability and a typed
/// response; it never needs to know whether the answer came from Ollama, an OpenAI-compatible
/// server, or a direct cloud API.
public struct BELModelRequest: Sendable, Equatable {
    public let system: String
    public let prompt: String
    public let sensitivity: Sensitivity
    public let maxTokens: Int
    public let localOnly: Bool

    public init(system: String = "", prompt: String, sensitivity: Sensitivity = .personal,
                maxTokens: Int = 1024, localOnly: Bool = false) {
        self.system = system
        self.prompt = prompt
        self.sensitivity = sensitivity
        self.maxTokens = maxTokens
        self.localOnly = localOnly
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

    /// Returns the same response while exposing fragments to interactive surfaces.
    func stream(_ request: BELModelRequest, model: String?,
                onFragment: @escaping @Sendable (String) -> Void) async throws -> BELModelResponse
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
                capabilities: Set<ModelCapability>? = nil,
                client: IntelligenceClient = IntelligenceClient()) {
        self.descriptor = descriptor
        self.capabilities = capabilities ?? descriptor.capabilities
        self.client = client
    }

    public func generate(_ request: BELModelRequest, model: String? = nil) async throws -> BELModelResponse {
        let intelligenceRequest = IntelligenceRequest(
            system: request.system,
            prompt: request.prompt,
            sensitivity: request.sensitivity,
            maxTokens: request.maxTokens,
            localOnly: request.localOnly
        )
        let selectedModel = model ?? descriptor.defaultModel
        let text = try await client.answer(intelligenceRequest, using: descriptor, model: selectedModel)
        return BELModelResponse(text: text, providerID: providerID, model: selectedModel)
    }

    public func stream(_ request: BELModelRequest, model: String? = nil,
                       onFragment: @escaping @Sendable (String) -> Void) async throws
        -> BELModelResponse {
        let intelligenceRequest = IntelligenceRequest(
            system: request.system,
            prompt: request.prompt,
            sensitivity: request.sensitivity,
            maxTokens: request.maxTokens,
            localOnly: request.localOnly
        )
        let selectedModel = model ?? descriptor.defaultModel
        let text = try await client.stream(intelligenceRequest, using: descriptor,
                                           model: selectedModel, onFragment: onFragment)
        return BELModelResponse(text: text, providerID: providerID, model: selectedModel)
    }
}

/// Local-core facade. The concrete HTTP runtime remains inspectable for health and diagnostics,
/// while Brain callers receive one stable identity across Ollama, LM Studio, or a future runtime.
public struct BELLocalCoreProvider: BELLanguageModelProvider {
    public let backend: BELHTTPModelProvider
    public var providerID: String { BELLocalCore.id }
    public var capabilities: Set<ModelCapability> { backend.capabilities }

    public init(descriptor: IntelligenceProvider,
                client: IntelligenceClient = IntelligenceClient()) {
        self.backend = BELHTTPModelProvider(descriptor: descriptor, client: client)
    }

    public func generate(_ request: BELModelRequest, model: String? = nil) async throws
        -> BELModelResponse {
        let response = try await backend.generate(request, model: model)
        return BELModelResponse(text: response.text, providerID: providerID, model: response.model)
    }

    public func stream(_ request: BELModelRequest, model: String? = nil,
                       onFragment: @escaping @Sendable (String) -> Void) async throws
        -> BELModelResponse {
        let response = try await backend.stream(request, model: model, onFragment: onFragment)
        return BELModelResponse(text: response.text, providerID: providerID, model: response.model)
    }
}

public enum BELLanguageModelProviderFactory {
    /// Returns only providers present in the canonical chat catalogue. Apple Foundation Models
    /// is intentionally separate because it has no endpoint or user key: its runtime availability
    /// is checked below rather than inferred from the SDK or from Settings configuration.
    public static func httpProviders(
        client: IntelligenceClient = IntelligenceClient()
    ) -> [BELHTTPModelProvider] {
        IntelligenceProvider.all.map { provider in
            BELHTTPModelProvider(descriptor: provider, client: client)
        }
    }

    public static func localCoreProviders(
        client: IntelligenceClient = IntelligenceClient()
    ) -> [BELLocalCoreProvider] {
        IntelligenceProvider.all.filter(\.isPrivate).map {
            BELLocalCoreProvider(descriptor: $0, client: client)
        }
    }

    /// Builds the runtime boundary used by callers. Local transports intentionally collapse to
    /// the stable Brain identity; cloud transports retain their provider identity for receipts,
    /// routing and diagnostics.
    public static func provider(for descriptor: IntelligenceProvider,
                               client: IntelligenceClient = IntelligenceClient())
        -> any BELLanguageModelProvider {
        if descriptor.isPrivate {
            return BELLocalCoreProvider(descriptor: descriptor, client: client)
        }
        return BELHTTPModelProvider(descriptor: descriptor, client: client)
    }

    /// Apple Intelligence is discovered at runtime and never reported as configured merely
    /// because the framework exists in the SDK.
    public static func foundationModelsProvider() -> (any BELLanguageModelProvider)? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), BELFoundationModelsRuntime.isAvailable {
            return BELFoundationModelsProvider()
        }
        #endif
        return nil
    }
}
