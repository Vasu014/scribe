import XCTest
@testable import FusionKit

/// Stubs the Messages API at the URLLoadingSystem level so the request shape
/// and the error taxonomy are asserted without a network call.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` is stripped by the loading system; the stream survives.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }

        let (status, body) = Self.handler?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnthropicFusionProviderTests: XCTestCase {

    private func makeProvider(status: Int, body: String) -> AnthropicFusionProvider {
        StubURLProtocol.lastBody = nil
        StubURLProtocol.handler = { _ in (status, Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return AnthropicFusionProvider(
            apiKeyProvider: { "sk-test" },
            urlSession: URLSession(configuration: config)
        )
    }

    private func sentBody() throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Request shape

    /// The model id is provenance: it lands in `notes.model` and in every
    /// exported eval case (SPEC §4.5/§4.6). `claude-sonnet-4-5` is not a
    /// current model.
    func testModelIdentifierIsCurrent() {
        XCTAssertEqual(AnthropicFusionProvider.model, "claude-sonnet-5")
        XCTAssertNotEqual(AnthropicFusionProvider.model, "claude-sonnet-4-5")
    }

    /// SPEC §4.5 pins "temperature 0–0.3", but current models removed the
    /// sampling parameters — sending `temperature` is a 400, not a nudge
    /// toward grounding. The key must be absent from the body entirely (a
    /// JSON `null` is rejected the same way a number is).
    func testTemperatureIsOmittedForModelsThatRejectSamplingParameters() async throws {
        XCTAssertFalse(AnthropicFusionProvider.acceptsSamplingParameters)
        let provider = makeProvider(status: 200, body: #"{"content":[{"type":"text","text":"Title: x"}]}"#)
        _ = try await provider.complete(systemPrompt: "sys", userPrompt: "user", temperature: 0.2)

        let body = try sentBody()
        XCTAssertNil(body["temperature"], "current models reject `temperature` with a 400")
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicFusionProvider.maxTokens)
        XCTAssertEqual(body["system"] as? String, "sys")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "user")
    }

    /// The `FusionProvider` seam still carries the temperature for providers
    /// that accept sampling parameters — it is omitted, not deleted.
    func testRequestBodyKeepsTemperatureWhenSupplied() throws {
        let withValue = AnthropicFusionProvider.RequestBody(
            model: "claude-sonnet-4-6", maxTokens: 100, temperature: 0.2, system: "s", userMessage: "u"
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(withValue)) as? [String: Any]
        XCTAssertEqual(encoded?["temperature"] as? Double, 0.2)
    }

    // MARK: Error taxonomy — a bad key must not look like an API outage

    func testRejectedKeyIsDistinctFromAPIFailure() async {
        let unauthorized = makeProvider(status: 401, body: #"{"type":"error","error":{"type":"authentication_error"}}"#)
        do {
            _ = try await unauthorized.complete(systemPrompt: "s", userPrompt: "u", temperature: 0.2)
            XCTFail("expected a throw")
        } catch let error as AnthropicFusionProviderError {
            guard case .apiKeyRejected(401, _) = error else {
                return XCTFail("401 must map to .apiKeyRejected, got \(error)")
            }
            let message = FusionService.describe(error)
            XCTAssertTrue(message.contains("API key"), "user-facing text must name the key: \(message)")
            XCTAssertTrue(message.contains("Settings"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testServerErrorStaysAnAPIFailure() async {
        let failing = makeProvider(status: 503, body: "upstream unavailable")
        do {
            _ = try await failing.complete(systemPrompt: "s", userPrompt: "u", temperature: 0.2)
            XCTFail("expected a throw")
        } catch let error as AnthropicFusionProviderError {
            guard case .httpStatus(503, _) = error else {
                return XCTFail("503 must stay .httpStatus, got \(error)")
            }
            let message = FusionService.describe(error)
            XCTAssertFalse(message.contains("API key"),
                           "an outage must not be reported as a key problem: \(message)")
            XCTAssertTrue(message.contains("503"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingKeyIsItsOwnMessage() {
        let message = FusionService.describe(AnthropicFusionProviderError.apiKeyUnavailable("no API key in Keychain"))
        XCTAssertTrue(message.contains("No Anthropic API key is saved"))
        XCTAssertNotEqual(
            message,
            FusionService.describe(AnthropicFusionProviderError.apiKeyRejected(401, "")),
            "missing key and rejected key must read differently"
        )
    }

    func testSuccessfulResponseJoinsTextBlocks() async throws {
        let provider = makeProvider(
            status: 200,
            body: #"{"content":[{"type":"text","text":"Title: x"},{"type":"text","text":"body"}]}"#
        )
        let text = try await provider.complete(systemPrompt: "s", userPrompt: "u", temperature: 0.2)
        XCTAssertEqual(text, "Title: x\nbody")
    }
}
