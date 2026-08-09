import Foundation

/// Stable product identity for whichever local runtime currently serves the Brain.
public enum BELLocalCore {
    public static let id = "bebrain.local.core"
}

/// Where the provider actually executes. This is deliberately separate from the provider name:
/// a local Ollama endpoint and a future first-party local core share the same privacy boundary.
public enum BELModelPlacement: String, Codable, Sendable, Equatable {
    case onDevice
    case local
    case cloud
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
    public let brainContextLevel: BELActionDefinition.BrainContextLevel

    public init(system: String = "", prompt: String, sensitivity: Sensitivity = .personal,
                maxTokens: Int = 1024, localOnly: Bool = false,
                brainContextLevel: BELActionDefinition.BrainContextLevel = .b0) {
        self.system = system
        self.prompt = prompt
        self.sensitivity = sensitivity
        self.maxTokens = maxTokens
        self.localOnly = localOnly
        self.brainContextLevel = brainContextLevel
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
    var placement: BELModelPlacement { get }
    var capabilities: Set<ModelCapability> { get }

    /// `nil` means the provider has not supplied a verified context limit. It must never be
    /// replaced with a marketing value because retrieval budgets depend on this number.
    var contextWindow: Int? { get async }

    /// A runtime check, not a configuration check. Implementations must perform a real probe or
    /// consult a runtime-owned health source before returning true.
    func isAvailable() async -> Bool

    func generate(_ request: BELModelRequest, model: String?) async throws -> BELModelResponse

    /// Returns the same response while exposing fragments to interactive surfaces.
    func stream(_ request: BELModelRequest, model: String?,
                onFragment: @escaping @Sendable (String) -> Void) async throws -> BELModelResponse
}

public extension BELLanguageModelProvider {
    var contextWindow: Int? { nil }

    /// New providers fail closed until they implement a real availability check.
    func isAvailable() async -> Bool { false }
}

/// Adapter for every provider that speaks the configured HTTP contract. Keeping this adapter
/// small is intentional: authentication, vendor request shapes and response parsing stay in
/// `IntelligenceClient`, while callers get one stable Brain-facing API.
public struct BELHTTPModelProvider: BELLanguageModelProvider {
    public let descriptor: IntelligenceProvider
    public let capabilities: Set<ModelCapability>
    public let client: IntelligenceClient

    public var providerID: String { descriptor.id }
    public var placement: BELModelPlacement {
        descriptor.isPrivate ? .local : .cloud
    }

    public init(descriptor: IntelligenceProvider,
                capabilities: Set<ModelCapability>? = nil,
                client: IntelligenceClient = IntelligenceClient()) {
        self.descriptor = descriptor
        self.capabilities = capabilities ?? descriptor.capabilities
        self.client = client
    }

    public func generate(_ request: BELModelRequest, model: String? = nil) async throws -> BELModelResponse {
        try Task.checkCancellation()
        let intelligenceRequest = IntelligenceRequest(
            system: request.system,
            prompt: request.prompt,
            sensitivity: request.sensitivity,
            maxTokens: request.maxTokens,
            localOnly: request.localOnly,
            brainContextLevel: request.brainContextLevel
        )
        let selectedModel = try selectedModel(model)
        let text = try await client.answer(intelligenceRequest, using: descriptor, model: selectedModel)
        try Task.checkCancellation()
        return BELModelResponse(text: text, providerID: providerID, model: selectedModel)
    }

    public func stream(_ request: BELModelRequest, model: String? = nil,
                       onFragment: @escaping @Sendable (String) -> Void) async throws
        -> BELModelResponse {
        try Task.checkCancellation()
        let intelligenceRequest = IntelligenceRequest(
            system: request.system,
            prompt: request.prompt,
            sensitivity: request.sensitivity,
            maxTokens: request.maxTokens,
            localOnly: request.localOnly,
            brainContextLevel: request.brainContextLevel
        )
        let selectedModel = try selectedModel(model)
        let text = try await client.stream(intelligenceRequest, using: descriptor,
                                           model: selectedModel, onFragment: onFragment)
        try Task.checkCancellation()
        return BELModelResponse(text: text, providerID: providerID, model: selectedModel)
    }

    private func selectedModel(_ model: String?) throws -> String {
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return model
        }
        guard !descriptor.isPrivate else {
            throw IntelligenceError.noProviderConfigured
        }
        return descriptor.defaultModel
    }

    public func isAvailable() async -> Bool {
        let key = descriptor.transport == .directKey
            ? client.keyLookup(descriptor.keychainAccount)
            : nil
        let state = await IntelligenceProvider.probe(descriptor, key: key,
                                                      transport: client.transport)
        if case .configured = state { return true }
        return false
    }
}

/// Local-core facade. The concrete HTTP runtime remains inspectable for health and diagnostics,
/// while Brain callers receive one stable identity across Ollama, LM Studio, or a future runtime.
public struct BELLocalCoreProvider: BELLanguageModelProvider {
    public let backend: BELHTTPModelProvider
    public var providerID: String { BELLocalCore.id }
    public var placement: BELModelPlacement { .local }
    public var capabilities: Set<ModelCapability> { backend.capabilities }
    public var contextWindow: Int? { get async { backend.contextWindow } }

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

    public func isAvailable() async -> Bool {
        await backend.isAvailable()
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
