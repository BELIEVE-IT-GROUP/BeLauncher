import Foundation

/// Canonical catalogue shared by routing, settings and diagnostics.
public enum ModelCapability: String, Codable, Sendable, Equatable, CaseIterable {
    case chat
    case embeddings
    case transcription
    /// A provider that can retrieve fresh external information, not merely generate text.
    case web
}

public struct ModelProviderDescriptor: Codable, Sendable, Equatable, Identifiable {
    public enum Transport: String, Codable, Sendable, Equatable { case local, directKey }
    public enum State: String, Codable, Sendable, Equatable {
        /// A generation request has succeeded recently enough for the caller to trust it.
        case ready
        /// The local endpoint or cloud credential exists, but generation has not been verified.
        case configured
        case needsSetup
        case offline
    }

    public let id: String
    public let name: String
    public let transport: Transport
    public let endpoint: String
    /// Local discovery endpoint, when the provider exposes its installed models over HTTP.
    /// Keeping this beside the provider descriptor prevents Settings, search and installers from
    /// drifting into separate hardcoded catalogues.
    public let modelsEndpoint: String?
    /// Local management API root, used by an installer to pull or inspect a model.
    public let managementEndpoint: String?
    public let defaultModel: String
    public let keychainAccount: String
    public let capabilities: Set<ModelCapability>

    public init(id: String, name: String, transport: Transport, endpoint: String,
                modelsEndpoint: String? = nil, managementEndpoint: String? = nil,
                defaultModel: String, keychainAccount: String = "",
                capabilities: Set<ModelCapability> = [.chat]) {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.modelsEndpoint = modelsEndpoint
        self.managementEndpoint = managementEndpoint
        self.defaultModel = defaultModel
        self.keychainAccount = keychainAccount
        self.capabilities = capabilities
    }

    public var isPrivate: Bool { transport == .local }

    public func state(localProviderIDs: Set<String> = [],
                      configuredKeyAccounts: Set<String> = [],
                      readyProviderIDs: Set<String> = []) -> State {
        if readyProviderIDs.contains(id) { return .ready }
        if isPrivate { return localProviderIDs.contains(id) ? .configured : .offline }
        return configuredKeyAccounts.contains(keychainAccount) ? .configured : .needsSetup
    }
}

public enum ModelProviderRegistry {
    public static let all: [ModelProviderDescriptor] = [
        .init(id: "ollama", name: "Ollama (local)", transport: .local,
              endpoint: "http://127.0.0.1:11434/v1/chat/completions",
              modelsEndpoint: "http://127.0.0.1:11434/api/tags",
              managementEndpoint: "http://127.0.0.1:11434",
              defaultModel: "llama3.2", capabilities: [.chat, .embeddings]),
        .init(id: "lmstudio", name: "LM Studio (local)", transport: .local,
              endpoint: "http://127.0.0.1:1234/v1/chat/completions",
              modelsEndpoint: "http://127.0.0.1:1234/v1/models",
              managementEndpoint: nil,
              defaultModel: "local-model", capabilities: [.chat, .embeddings]),
        .init(id: "anthropic", name: "Anthropic", transport: .directKey,
              endpoint: "https://api.anthropic.com/v1/messages",
              modelsEndpoint: "https://api.anthropic.com/v1/models",
              defaultModel: "claude-sonnet-5", keychainAccount: "anthropic_api_key"),
        .init(id: "openai", name: "OpenAI", transport: .directKey,
              endpoint: "https://api.openai.com/v1/chat/completions",
              defaultModel: "gpt-5", keychainAccount: "openai_api_key"),
        .init(id: "gemini", name: "Google Gemini", transport: .directKey,
              endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
              modelsEndpoint: "https://generativelanguage.googleapis.com/v1beta/models",
              defaultModel: "gemini-2.5-pro", keychainAccount: "gemini_api_key"),
    ]

    public static func named(_ id: String) -> ModelProviderDescriptor? {
        all.first { $0.id == id }
    }

    public static func supporting(_ capability: ModelCapability) -> [ModelProviderDescriptor] {
        all.filter { $0.capabilities.contains(capability) }
    }
}
