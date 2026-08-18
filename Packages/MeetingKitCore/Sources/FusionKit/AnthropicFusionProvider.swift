import Foundation

/// Typed failures from the Anthropic Messages API transport. No third-party
/// HTTP dependencies — plain URLSession (SPEC §4.5: direct frontier-model
/// API; the `FusionProvider` seam keeps Phase 2 relocation clean).
public enum AnthropicFusionProviderError: Error, Equatable, Sendable {
    /// The API key could not be read (missing from Keychain, or Keychain error).
    case apiKeyUnavailable(String)
    /// Transport-level failure (underlying error description).
    case network(String)
    /// Non-2xx HTTP status; carries a truncated body snippet for diagnostics.
    case httpStatus(Int, String)
    /// The response body was not a decodable Messages API payload.
    case decoding(String)
    /// The endpoint constant failed to parse as a URL (unreachable in practice).
    case invalidEndpoint
}

/// `FusionProvider` conformance over the Anthropic Messages API
/// (`https://api.anthropic.com/v1/messages`). The network layer lives
/// entirely behind this type — unit tests use a mock `FusionProvider`; no
/// API calls happen in tests.
public struct AnthropicFusionProvider: FusionProvider {

    /// Direct Messages API endpoint (SPEC §4.5).
    public static let endpointString = "https://api.anthropic.com/v1/messages"
    /// Claude Sonnet-class model, decided in SPEC §4.5.
    public static let model = "claude-sonnet-4-5"
    /// Required API version header.
    public static let anthropicVersion = "2023-06-01"
    /// Output ceiling for one fusion run (full notes fit comfortably).
    public static let maxTokens = 4096

    public var modelIdentifier: String { Self.model }

    private let urlSession: URLSession
    private let apiKeyProvider: @Sendable () throws -> String

    /// Reads the key from the Keychain on every call, so key changes in
    /// Settings apply to the next fusion run without re-creating the provider.
    public init(keychain: KeychainStore = KeychainStore(), urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.apiKeyProvider = {
            guard let key = try keychain.loadAPIKey() else {
                throw AnthropicFusionProviderError.apiKeyUnavailable("no API key in Keychain")
            }
            return key
        }
    }

    /// Keychain-free initializer (tests, alternative key storage).
    public init(apiKeyProvider: @escaping @Sendable () throws -> String, urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.apiKeyProvider = apiKeyProvider
    }

    public func complete(systemPrompt: String, userPrompt: String, temperature: Double) async throws -> String {
        guard let url = URL(string: Self.endpointString) else {
            throw AnthropicFusionProviderError.invalidEndpoint
        }

        let apiKey: String
        do {
            apiKey = try apiKeyProvider()
        } catch {
            throw AnthropicFusionProviderError.apiKeyUnavailable(String(describing: error))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Fusion outputs are long; give the model room to finish.
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: Self.model,
            maxTokens: Self.maxTokens,
            temperature: temperature,
            system: systemPrompt,
            userMessage: userPrompt
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AnthropicFusionProviderError.network(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicFusionProviderError.network("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicFusionProviderError.httpStatus(http.statusCode, Self.snippet(data))
        }

        do {
            let body = try JSONDecoder().decode(ResponseBody.self, from: data)
            let text = body.content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
            guard !text.isEmpty else {
                throw AnthropicFusionProviderError.decoding("response contained no text blocks")
            }
            return text
        } catch let error as AnthropicFusionProviderError {
            throw error
        } catch {
            throw AnthropicFusionProviderError.decoding(String(describing: error))
        }
    }

    /// Truncated UTF-8 body snippet for error diagnostics.
    private static func snippet(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "<non-UTF-8 body>" }
        return String(text.prefix(512))
    }

    // MARK: Wire types (Messages API schema)

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role = "user"
            let content: String
        }
        let model: String
        let max_tokens: Int
        let temperature: Double
        let system: String
        let messages: [Message]

        init(model: String, maxTokens: Int, temperature: Double, system: String, userMessage: String) {
            self.model = model
            self.max_tokens = maxTokens
            self.temperature = temperature
            self.system = system
            self.messages = [Message(content: userMessage)]
        }
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }
}
