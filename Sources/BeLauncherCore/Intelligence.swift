import Foundation

/// Bring Your Own Intelligence.
///
/// The model is a swappable part, never the product. Someone can run everything on-device for
/// free, or point BeLauncher at their own provider account and pay that provider directly. What
/// we never do is put ourselves in the middle: no proxy of ours sees the prompts, and no tokens
/// are resold. That is a real difference from launchers whose "bring your own key" still routes
/// every request through their servers.
public struct IntelligenceProvider: Sendable, Equatable, Identifiable {
    public enum Transport: String, Sendable, Equatable, Codable {
        /// Runs on the Mac. No key, no network, no cost per token.
        case local
        /// The user's own key, straight to the provider.
        case directKey
    }

    public let id: String
    public let name: String
    public let transport: Transport
    public let endpoint: String
    public let defaultModel: String
    /// Keychain account holding the key, empty for local providers.
    public let keychainAccount: String
    /// Everything stays on the Mac with this provider.
    public var isPrivate: Bool { transport == .local }

    public init(id: String, name: String, transport: Transport, endpoint: String,
                defaultModel: String, keychainAccount: String = "") {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.defaultModel = defaultModel
        self.keychainAccount = keychainAccount
    }

    public static let all: [IntelligenceProvider] = ModelProviderRegistry
        .supporting(.chat)
        .map {
            .init(id: $0.id, name: $0.name,
                  transport: $0.transport == .local ? .local : .directKey,
                  endpoint: $0.endpoint, defaultModel: $0.defaultModel,
                  keychainAccount: $0.keychainAccount)
        }

    public static func named(_ id: String) -> IntelligenceProvider? {
        all.first { $0.id == id }
    }
}

/// How sensitive a request is. The router uses it to decide what may leave the Mac.
public enum Sensitivity: String, Sendable, Equatable, Codable, CaseIterable {
    /// Nothing private: a definition, a translation of public text.
    case ordinary
    /// The user's own working material.
    case personal
    /// Company memory: decisions, commitments, client material.
    case confidential
}

public enum IntelligenceError: Error, Equatable, CustomStringConvertible {
    case noProviderConfigured
    case missingKey(String)
    case blockedBySensitivity(String)
    case transport(String)
    case emptyAnswer

    public var description: String {
        switch self {
        case .noProviderConfigured:
            // The old text sent people to a screen where everything already looked configured.
            // The usual cause is Ollama simply not running, which nothing was saying out loud.
            L("There is no model available right now. If you use Ollama or LM Studio, open it and try again; if you would rather use one in the cloud, put your key in Settings › Intelligence.")
        case .missingKey(let provider):
            L("The %@ key is missing. Save it in Settings; it stays in your Keychain.", provider)
        case .blockedBySensitivity(let provider):
            L("This content is marked confidential and %@ is not local. Change it in Settings or use a model on your Mac.", provider)
        case .transport(let reason):
            L("The model could not be reached: %@", reason)
        case .emptyAnswer:
            L("The model returned nothing.")
        }
    }
}

/// Decides which provider serves a request, and refuses rather than leaking.
public struct ModelRouter: Sendable {
    public let preferred: String?
    public let localOnlyFor: Set<Sensitivity>

    public init(preferred: String?, localOnlyFor: Set<Sensitivity> = [.confidential]) {
        self.preferred = preferred
        self.localOnlyFor = localOnlyFor
    }

    /// `available` is the set of providers the user has actually set up.
    public func provider(
        for sensitivity: Sensitivity,
        available: [IntelligenceProvider]
    ) throws -> IntelligenceProvider {
        guard let first = try providers(for: sensitivity, available: available).first else {
            throw IntelligenceError.noProviderConfigured
        }
        return first
    }

    /// Orders all usable providers so callers can retry a transiently unavailable local runner.
    /// The preference remains first; fallback is explicit and never bypasses the privacy rule.
    public func providers(
        for sensitivity: Sensitivity,
        available: [IntelligenceProvider]
    ) throws -> [IntelligenceProvider] {
        guard !available.isEmpty else { throw IntelligenceError.noProviderConfigured }

        let ordered = available.sorted { lhs, rhs in
            if lhs.id == preferred { return true }
            if rhs.id == preferred { return false }
            return false
        }
        guard localOnlyFor.contains(sensitivity) else { return ordered }

        let local = ordered.filter(\.isPrivate)
        guard !local.isEmpty else {
            throw IntelligenceError.blockedBySensitivity(ordered[0].name)
        }
        return local
    }
}

public struct IntelligenceRequest: Sendable, Equatable {
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

/// Talks to whichever provider the router picked. One shape in, one shape out, so the rest of the
/// app never learns which vendor answered.
public struct IntelligenceClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Separate from `Transport` because a stream is bytes arriving over time, not a payload
    /// that has finished.
    public typealias ByteTransport =
        @Sendable (URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)

    public var transport: Transport
    public var byteTransport: ByteTransport
    public var keyLookup: @Sendable (String) -> String?

    public init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        byteTransport: @escaping ByteTransport = { try await URLSession.shared.bytes(for: $0) },
        keyLookup: @escaping @Sendable (String) -> String? = { Keychain.get($0) }
    ) {
        self.transport = transport
        self.byteTransport = byteTransport
        self.keyLookup = keyLookup
    }

    public func answer(
        _ request: IntelligenceRequest,
        using provider: IntelligenceProvider,
        model: String? = nil
    ) async throws -> String {
        let urlRequest = try build(request, provider: provider, model: model ?? provider.defaultModel)
        let data: Data
        do {
            (data, _) = try await transport(urlRequest)
        } catch {
            throw IntelligenceError.transport(error.localizedDescription)
        }
        guard let text = Self.extractText(from: data), !text.isEmpty else {
            throw IntelligenceError.emptyAnswer
        }
        return text
    }

    /// Asks and reports each fragment as it arrives.
    ///
    /// Waiting for the whole answer was the bug people actually felt. A local model on this
    /// machine generates about 14 tokens a second, so a 400-token answer is 28 seconds of a
    /// spinner with nothing in it, and anything longer than about 850 tokens simply blew past the
    /// 60-second timeout and reported a failure for work that was going fine.
    ///
    /// Streaming fixes both at once: the first words appear in under a second, and the timeout
    /// goes back to meaning what it should — the gap between packets, not the length of the
    /// answer. The whole text is still returned at the end for whoever wants it in one piece.
    @discardableResult
    public func stream(
        _ request: IntelligenceRequest,
        using provider: IntelligenceProvider,
        model: String? = nil,
        onFragment: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var urlRequest = try build(request, provider: provider,
                                   model: model ?? provider.defaultModel, streaming: true)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await byteTransport(urlRequest)
        } catch {
            throw IntelligenceError.transport(error.localizedDescription)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode

        var whole = ""
        var providerError: String?
        do {
            for try await line in bytes.lines {
                if let fragment = Self.fragment(fromSSE: line) {
                    whole += fragment
                    onFragment(fragment)
                } else if let data = line.data(using: .utf8),
                          let text = Self.extractText(from: data), !text.isEmpty {
                    // Ollama can return newline-delimited JSON even when the endpoint is asked
                    // for a stream, while OpenAI-compatible servers usually prefix it with data:.
                    if text.hasPrefix("⚠︎ ") { providerError = text }
                    else { whole += text; onFragment(text) }
                }
            }
        } catch {
            // Something already arrived: better a partial answer than losing it to a hiccup.
            guard whole.isEmpty else { return whole.trimmingCharacters(in: .whitespacesAndNewlines) }
            throw IntelligenceError.transport(error.localizedDescription)
        }

        if let statusCode, !(200..<300).contains(statusCode) {
            throw IntelligenceError.transport(providerError ??
                L("The provider answered HTTP %@.", String(statusCode)))
        }

        let text = whole.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw IntelligenceError.transport(L("%@ returned no text.", provider.name))
        }
        return text
    }

    /// One line of a server-sent event stream, or nil when it carries nothing to show.
    ///
    /// Pure so the parsing is testable without a server: this is the part that breaks silently
    /// when a provider changes shape, and a stream that quietly yields nothing looks exactly like
    /// a model that has hung.
    public static func fragment(fromSSE line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // OpenAI-compatible, which also covers Ollama and LM Studio.
        if let choices = root["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String, !content.isEmpty {
            return content
        }
        // Anthropic sends the text inside a content_block_delta.
        if let delta = root["delta"] as? [String: Any],
           let text = delta["text"] as? String, !text.isEmpty {
            return text
        }
        return nil
    }

    func build(_ request: IntelligenceRequest, provider: IntelligenceProvider, model: String,
               streaming: Bool = false) throws -> URLRequest {
        guard let url = URL(string: provider.endpoint) else {
            throw IntelligenceError.transport(L("invalid endpoint"))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if provider.transport == .directKey {
            guard let key = keyLookup(provider.keychainAccount), !key.isEmpty else {
                throw IntelligenceError.missingKey(provider.name)
            }
            switch provider.id {
            case "anthropic":
                urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
                urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            default:
                urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        var messages: [[String: String]] = []
        if !request.system.isEmpty, provider.id != "anthropic" {
            messages.append(["role": "system", "content": request.system])
        }
        messages.append(["role": "user", "content": request.prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        // GPT-5 rejects the legacy max_tokens name. Keep the old field for local
        // OpenAI-compatible servers, which still expect it.
        body[provider.id == "openai" ? "max_completion_tokens" : "max_tokens"] = request.maxTokens
        if streaming { body["stream"] = true }
        if provider.id == "anthropic", !request.system.isEmpty {
            body["system"] = request.system
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// Providers disagree on the shape of an answer; this reads all of the common ones so the
    /// caller never has to care which one replied.
    static func extractText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // OpenAI-compatible, which also covers Ollama and LM Studio.
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Ollama's native newline-delimited stream uses message.content at the root.
        if let message = root["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some newer OpenAI-compatible responses return content parts instead of one string.
        if let choices = root["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Anthropic.
        if let content = root["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // An error the provider bothered to explain.
        if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
            return "⚠︎ " + message
        }
        return nil
    }
}
