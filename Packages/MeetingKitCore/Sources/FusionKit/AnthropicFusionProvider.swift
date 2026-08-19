import Foundation

/// Typed failures from the Anthropic Messages API transport. No third-party
/// HTTP dependencies — plain URLSession (SPEC §4.5: direct frontier-model
/// API; the `FusionProvider` seam keeps Phase 2 relocation clean).
public enum AnthropicFusionProviderError: Error, Equatable, Sendable {
    /// The API key could not be read (missing from Keychain, or Keychain error).
    case apiKeyUnavailable(String)
    /// The API key was read but the server rejected it (401/403). Distinct
    /// from `httpStatus` on purpose: "your key is wrong" and "the API is
    /// having a bad day" need different things from the user, and the Retry
    /// UI is the only place they find out.
    case apiKeyRejected(Int, String)
    /// Transport-level failure (underlying error description).
    case network(String)
    /// Non-2xx HTTP status; carries a truncated body snippet for diagnostics.
    case httpStatus(Int, String)
    /// The response body was not a decodable Messages API payload.
    case decoding(String)
    /// The endpoint constant failed to parse as a URL (unreachable in practice).
    case invalidEndpoint
}

/// Human-readable text for the Retry UI. `FusionService` prefers this over
/// `String(describing:)`, so a rejected key no longer reaches the user as an
/// opaque `httpStatus(401, "{\"type\":\"error\"…")` dump indistinguishable
/// from a 500.
extension AnthropicFusionProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .apiKeyUnavailable:
            return "No Anthropic API key is saved. Add one in Settings, then retry."
        case .apiKeyRejected(let status, _):
            return "Anthropic rejected the saved API key (HTTP \(status)). Check the key in Settings — retrying will not help until it is fixed."
        case .network(let message):
            return "Could not reach the Anthropic API: \(message)"
        case .httpStatus(let status, let snippet):
            let reason: String
            switch status {
            case 429: reason = "Rate limited by Anthropic"
            case 500...599: reason = "Anthropic API error"
            default: reason = "Anthropic API returned HTTP \(status)"
            }
            return "\(reason) (HTTP \(status)). Retry is worth a try. \(snippet)"
        case .decoding(let message):
            return "The Anthropic API response could not be read: \(message)"
        case .invalidEndpoint:
            return "The Anthropic API endpoint is misconfigured."
        }
    }
}

/// `FusionProvider` conformance over the Anthropic Messages API
/// (`https://api.anthropic.com/v1/messages`). The network layer lives
/// entirely behind this type — unit tests use a mock `FusionProvider`; no
/// API calls happen in tests.
public struct AnthropicFusionProvider: FusionProvider {

    /// Direct Messages API endpoint (SPEC §4.5).
    public static let endpointString = "https://api.anthropic.com/v1/messages"
    /// Claude Sonnet-class model, decided in SPEC §4.5. `claude-sonnet-5` is
    /// the current Sonnet-class id; the previous value (`claude-sonnet-4-5`)
    /// named a snapshot that is no longer a current model, so every fusion
    /// run risked a 404-class failure — and the stale string was written into
    /// `notes.model` and every exported eval case as provenance.
    ///
    /// The model id is part of the eval corpus's provenance: changing it
    /// changes what the corpus is a regression suite *for*.
    public static let model = "claude-sonnet-5"
    /// Required API version header.
    public static let anthropicVersion = "2023-06-01"
    /// Output ceiling for one fusion run (full notes fit comfortably).
    public static let maxTokens = 4096

    /// Whether `model` accepts `temperature` / `top_p` / `top_k`.
    ///
    /// **SPEC §4.5 CONTRADICTION — read before "restoring" the temperature.**
    /// SPEC §4.5 pins "Temperature 0–0.3" for the grounding task. Current
    /// Anthropic models (Sonnet 5, Opus 5, Opus 4.7/4.8, Fable 5) **removed
    /// the sampling parameters entirely**: sending `temperature` returns HTTP
    /// 400, so the spec's rule cannot be honoured literally on any current
    /// model. Sending it would not make fusion more grounded, it would make
    /// fusion fail outright.
    ///
    /// What replaces it: those models reason adaptively by default and are
    /// steered by `output_config.effort` rather than by sampling temperature,
    /// and the grounding the spec was buying is carried by the system
    /// prompt's hard grounding rules plus this validator. The
    /// `FusionProvider.complete(…temperature:)` seam is kept intact — the
    /// value still reaches providers that accept it (e.g. a pinned
    /// `claude-sonnet-4-6`), it is simply omitted from the request body for
    /// models that reject it.
    ///
    /// SPEC §4.5 needs updating to say "temperature 0–0.3 where the model
    /// accepts sampling parameters; otherwise omit them". Flagged, not
    /// silently dropped.
    public static let acceptsSamplingParameters = false

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
            // Omitted entirely on models that removed sampling parameters —
            // see `acceptsSamplingParameters` for the SPEC §4.5 conflict.
            temperature: Self.acceptsSamplingParameters ? temperature : nil,
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
            // A rejected key is not "the API failed" — it is a settings
            // problem the user can fix, and retrying will never help.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AnthropicFusionProviderError.apiKeyRejected(http.statusCode, Self.snippet(data))
            }
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

    /// `temperature` is `Optional` and encoded with `encodeIfPresent`, so a
    /// `nil` leaves the key OUT of the JSON entirely — a `null` would be
    /// rejected the same way a number is.
    struct RequestBody: Encodable {
        struct Message: Encodable {
            let role = "user"
            let content: String
        }
        let model: String
        let max_tokens: Int
        let temperature: Double?
        let system: String
        let messages: [Message]

        init(model: String, maxTokens: Int, temperature: Double?, system: String, userMessage: String) {
            self.model = model
            self.max_tokens = maxTokens
            self.temperature = temperature
            self.system = system
            self.messages = [Message(content: userMessage)]
        }

        private enum CodingKeys: String, CodingKey {
            case model, max_tokens, temperature, system, messages
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(max_tokens, forKey: .max_tokens)
            try container.encodeIfPresent(temperature, forKey: .temperature)
            try container.encode(system, forKey: .system)
            try container.encode(messages, forKey: .messages)
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
