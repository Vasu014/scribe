import Foundation
import XCTest
@testable import FusionKit
import Persistence

// MARK: - Transports that fail in each distinct way

/// Answers with a canned status + body, like `StubURLProtocol`, but also able
/// to fail at the TRANSPORT level and to return a non-HTTP response — the two
/// failure shapes a status-code stub cannot produce.
final class FailingURLProtocol: URLProtocol {
    enum Mode: @unchecked Sendable {
        case status(Int, String)
        case transportError(Error)
        case nonHTTPResponse
    }

    nonisolated(unsafe) static var mode: Mode = .status(200, "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.mode {
        case .status(let code, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .transportError(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .nonHTTPResponse:
            let response = URLResponse(
                url: request.url!, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A `FusionProvider` that always throws a given error — for driving
/// `FusionService`'s surfacing without any transport at all.
struct ThrowingFusionProvider: FusionProvider {
    let error: Error
    var modelIdentifier: String { "throwing-model" }
    func complete(systemPrompt: String, userPrompt: String, temperature: Double) async throws -> String {
        throw error
    }
}

/// Every failure path must arrive somewhere a human can act on, as a TYPED,
/// DISTINGUISHABLE value (SPEC §4.5 failure semantics).
///
/// Both independent audits named silent failure as this app's defining
/// defect, and the fusion transport is where the three failures a user must
/// tell apart all converge: a key they typed wrong, an API having a bad hour,
/// and a response the app could not read. The first is fixed in Settings and
/// retrying will never help; the second is fixed by waiting and retrying is
/// the whole answer; the third is a bug. One shared "fusion failed" string
/// makes all three look the same and sends the user to the wrong place.
final class FusionFailureSurfacingTests: XCTestCase {

    private func provider(_ mode: FailingURLProtocol.Mode) -> AnthropicFusionProvider {
        FailingURLProtocol.mode = mode
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        return AnthropicFusionProvider(
            apiKeyProvider: { "sk-test" },
            urlSession: URLSession(configuration: config)
        )
    }

    private func failure(_ mode: FailingURLProtocol.Mode) async -> AnthropicFusionProviderError? {
        do {
            _ = try await provider(mode).complete(systemPrompt: "s", userPrompt: "u", temperature: 0.2)
            XCTFail("expected a throw for \(mode)")
            return nil
        } catch let error as AnthropicFusionProviderError {
            return error
        } catch {
            XCTFail("untyped error escaped the provider: \(error)")
            return nil
        }
    }

    // MARK: - The taxonomy

    /// 403 is a rejected key just as much as 401 is — an org-level block, a
    /// revoked key, a key without access to the model. Only 401 was pinned,
    /// so a 403 read to the user as "Anthropic API returned HTTP 403. Retry
    /// is worth a try", which it is not.
    func testBothRejectionStatusesAreReportedAsAKeyProblem() async {
        for status in [401, 403] {
            let error = await failure(.status(status, #"{"type":"error","error":{"type":"permission_error"}}"#))
            guard case .apiKeyRejected(status, _)? = error else {
                XCTFail("HTTP \(status) must be .apiKeyRejected, got \(String(describing: error))")
                continue
            }
            let message = FusionService.describe(error!)
            XCTAssertTrue(message.contains("API key"), "must name the key: \(message)")
            XCTAssertTrue(message.contains("retrying will not help"),
                          "must say retrying is pointless: \(message)")
        }
    }

    /// Rate limiting and an outage are both "the API, not you" — but they are
    /// not the same advice, and neither is a key problem.
    func testRateLimitingAndOutagesStayAPIProblemsAndReadDifferently() async {
        let limited = await failure(.status(429, "too many requests"))
        guard case .httpStatus(429, _)? = limited else {
            return XCTFail("429 must stay .httpStatus, got \(String(describing: limited))")
        }
        let outage = await failure(.status(503, "upstream unavailable"))
        guard case .httpStatus(503, _)? = outage else {
            return XCTFail("503 must stay .httpStatus, got \(String(describing: outage))")
        }

        let limitedText = FusionService.describe(limited!)
        let outageText = FusionService.describe(outage!)
        XCTAssertTrue(limitedText.contains("Rate limited"), limitedText)
        XCTAssertTrue(outageText.contains("Anthropic API error"), outageText)
        XCTAssertNotEqual(limitedText, outageText)
        for text in [limitedText, outageText] {
            XCTAssertFalse(text.contains("API key"), "an API problem must not be blamed on the key: \(text)")
        }
    }

    /// A 200 the app cannot parse is a THIRD thing: not the key, not the API
    /// being down, but a response shape nobody expected. Degrading it into
    /// "fusion failed" hides a bug behind a retry button.
    func testAMalformedSuccessResponseIsItsOwnFailure() async {
        let bodies = [
            "not json at all":        "<html>502 Bad Gateway</html>",
            "json of the wrong shape": #"{"choices":[{"message":{"content":"hi"}}]}"#,
            "no content blocks":       #"{"content":[]}"#,
            "no text blocks":          #"{"content":[{"type":"thinking"}]}"#,
            "empty text":              #"{"content":[{"type":"text","text":""}]}"#,
        ]
        for (label, body) in bodies {
            let error = await failure(.status(200, body))
            guard case .decoding? = error else {
                XCTFail("\(label) must be .decoding, got \(String(describing: error))")
                continue
            }
            let message = FusionService.describe(error!)
            XCTAssertTrue(message.contains("could not be read"), "\(label): \(message)")
            XCTAssertFalse(message.contains("API key"), "\(label) is not a key problem: \(message)")
        }
    }

    /// A transport failure (no network, DNS, TLS) never reaches an HTTP
    /// status, and must not be laundered into one.
    func testATransportFailureIsReportedAsNetworkNotAsAStatus() async {
        let error = await failure(.transportError(URLError(.notConnectedToInternet)))
        guard case .network(let detail)? = error else {
            return XCTFail("expected .network, got \(String(describing: error))")
        }
        XCTAssertFalse(detail.isEmpty, "the underlying cause must be carried, not swallowed")
        let message = FusionService.describe(error!)
        XCTAssertTrue(message.contains("Could not reach the Anthropic API"), message)
    }

    /// A response that is not HTTP at all (a proxy, a captive portal) must
    /// not slip past the status check as a success.
    func testANonHTTPResponseIsRejectedRatherThanTreatedAsSuccess() async {
        let error = await failure(.nonHTTPResponse)
        guard case .network(let detail)? = error else {
            return XCTFail("expected .network, got \(String(describing: error))")
        }
        XCTAssertTrue(detail.contains("not HTTP"), detail)
    }

    /// No key at all is a fourth, distinct state — a first-run condition, not
    /// a failure of anything.
    func testAMissingKeyNeverReachesTheNetwork() async {
        FailingURLProtocol.mode = .status(200, #"{"content":[{"type":"text","text":"nope"}]}"#)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        struct NoKey: Error {}
        let provider = AnthropicFusionProvider(
            apiKeyProvider: { throw NoKey() },
            urlSession: URLSession(configuration: config)
        )
        do {
            _ = try await provider.complete(systemPrompt: "s", userPrompt: "u", temperature: 0.2)
            XCTFail("expected a throw")
        } catch let error as AnthropicFusionProviderError {
            guard case .apiKeyUnavailable = error else {
                return XCTFail("expected .apiKeyUnavailable, got \(error)")
            }
            XCTAssertTrue(FusionService.describe(error).contains("Add one in Settings"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The property the whole taxonomy exists for: no two failures read the
    /// same. A user who sees identical text for a wrong key and an outage
    /// cannot act on either.
    func testEveryFailureCaseProducesADistinctUserFacingMessage() {
        let cases: [AnthropicFusionProviderError] = [
            .apiKeyUnavailable("no API key in Keychain"),
            .apiKeyRejected(401, "{}"),
            .network("The Internet connection appears to be offline."),
            .httpStatus(429, "{}"),
            .httpStatus(500, "{}"),
            .decoding("dataCorrupted"),
            .invalidEndpoint,
        ]
        let messages = cases.map { FusionService.describe($0) }
        XCTAssertEqual(Set(messages).count, cases.count, "collisions in: \(messages)")
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(
                message.contains("AnthropicFusionProviderError"),
                "the Retry UI shows this verbatim — it must not be an enum dump: \(message)"
            )
        }
    }

    // MARK: - Surfacing through FusionService

    /// `FusionService` is the only thing between the transport and the Retry
    /// UI. `String(describing:)` on a provider error renders the enum case —
    /// `apiKeyRejected(401, "{\"type\":\"error\"…")` — which is what the user
    /// used to be shown, and reads identically whether their key is wrong or
    /// Anthropic is down.
    func testServiceCarriesTheDistinguishableMessageNotTheEnumDump() async throws {
        let store = try MeetingStore.inMemory()
        var session = try store.createSession()
        session.state = .processing
        try store.updateSession(session)
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote, text: "some talk",
            startOffset: 10, endOffset: 20, isFinal: true
        ))

        let rejected = AnthropicFusionProviderError.apiKeyRejected(401, #"{"type":"error"}"#)
        let outcome = await FusionService(store: store)
            .fuse(session: session, provider: ThrowingFusionProvider(error: rejected))

        guard case .failure(.provider(let message)) = outcome else {
            return XCTFail("expected .failure(.provider), got \(outcome)")
        }
        XCTAssertTrue(message.contains("rejected the saved API key"), message)
        XCTAssertNotEqual(message, String(describing: rejected),
                          "the old behaviour: the raw enum case reaching the user")

        // …and the session is still retryable, with nothing stored.
        let updated = try XCTUnwrap(try store.session(id: session.id))
        XCTAssertEqual(updated.state, .processing)
        XCTAssertTrue(try store.notes(sessionId: session.id).isEmpty)
    }

    /// The three outcomes a user must be able to tell apart, driven end to
    /// end through the service and compared as text.
    func testKeyRejectionOutageAndMalformedResponseStayDistinctThroughTheService() async throws {
        let errors: [AnthropicFusionProviderError] = [
            .apiKeyRejected(403, "{}"),
            .httpStatus(500, "{}"),
            .decoding("response contained no text blocks"),
        ]
        var messages: [String] = []
        for error in errors {
            let store = try MeetingStore.inMemory()
            var session = try store.createSession()
            session.state = .processing
            try store.updateSession(session)
            try store.upsertSegment(SegmentRecord(
                sessionId: session.id, channel: .remote, text: "talk", startOffset: 0, endOffset: 5, isFinal: true
            ))
            let outcome = await FusionService(store: store)
                .fuse(session: session, provider: ThrowingFusionProvider(error: error))
            guard case .failure(.provider(let message)) = outcome else {
                return XCTFail("expected .failure(.provider) for \(error), got \(outcome)")
            }
            messages.append(message)
        }
        XCTAssertEqual(Set(messages).count, 3, "three different problems, three different messages: \(messages)")
    }

    /// The reason must survive the process that produced it. A failure held
    /// only in memory turned a permanently failed session into an eternal
    /// spinner after a relaunch (SPEC §4.5) — and the message it persists has
    /// to be the DISTINGUISHABLE one, or the durability bought nothing.
    func testTheSurfacedReasonIsWhatSurvivesARelaunch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-surfacing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("store.sqlite").path

        let sessionId: UUID
        let message: String
        do {
            let store = try MeetingStore(path: path)
            var session = try store.createSession()
            session.state = .processing
            try store.updateSession(session)
            try store.upsertSegment(SegmentRecord(
                sessionId: session.id, channel: .remote, text: "talk", startOffset: 0, endOffset: 5, isFinal: true
            ))
            let outcome = await FusionService(store: store).fuse(
                session: session,
                provider: ThrowingFusionProvider(error: AnthropicFusionProviderError.apiKeyRejected(401, "{}"))
            )
            guard case .failure(.provider(let text)) = outcome else {
                return XCTFail("expected .failure(.provider), got \(outcome)")
            }
            // What SessionCoordinator does with that outcome (SPEC §4.5).
            try store.recordFusionFailure(sessionId: session.id, message: text)
            sessionId = session.id
            message = text
        }

        let reopened = try MeetingStore(path: path)
        let row = try XCTUnwrap(try reopened.session(id: sessionId))
        XCTAssertEqual(row.state, .processing, "still retryable after the relaunch")
        XCTAssertEqual(row.fusionErrorMessage, message)
        XCTAssertTrue(try XCTUnwrap(row.fusionErrorMessage).contains("Check the key in Settings"),
                      "the actionable half of the message must survive too")
    }

    // MARK: - A meeting that produced no transcript

    /// When the speech model is missing, the app records the meeting and
    /// transcribes nothing (the fallback in `LazyWhisperKitTranscriber`).
    /// The package's half of "that must not be silent" is this: fusion
    /// reports a TYPED `emptyTranscript` rather than burning an API call and
    /// storing an invented note over no evidence, and the user's typed
    /// fragments — the only record of the meeting that survived — are still
    /// in the store afterwards.
    ///
    /// GAP: the warning that tells the user BEFORE the meeting lives in
    /// `App/LazyWhisperKitTranscriber.swift` (`onModelUnavailable`) and
    /// cannot be asserted from this package.
    func testAMeetingWithNoTranscriptFailsTypedAndKeepsTheTypedNotes() async throws {
        let store = try MeetingStore.inMemory()
        var session = try store.createSession()
        session.state = .processing
        try store.updateSession(session)
        // The scratchpad worked even though transcription did not.
        try store.upsertFragment(FragmentRecord(sessionId: session.id, text: "pricing objection", anchorOffset: 612))
        try store.upsertFragment(FragmentRecord(sessionId: session.id, text: "send the DPA", anchorOffset: 900))

        let provider = MockFusionProvider(responses: ["Title: invented from nothing"])
        let outcome = await FusionService(store: store).fuse(session: session, provider: provider)

        guard case .failure(.emptyTranscript) = outcome else {
            return XCTFail("expected .failure(.emptyTranscript), got \(outcome)")
        }
        XCTAssertTrue(provider.calls.isEmpty, "no notes may be invented over an empty transcript")
        XCTAssertTrue(try store.notes(sessionId: session.id).isEmpty)
        XCTAssertEqual(try store.session(id: session.id)?.state, .processing, "retryable once a model exists")
        XCTAssertEqual(try store.fragments(sessionId: session.id).map(\.text),
                       ["pricing objection", "send the DPA"],
                       "the user's own notes must survive a transcription failure")
    }

    /// `emptyTranscript` must stay distinguishable from a provider failure —
    /// they need opposite responses from the user (download a model vs retry).
    func testAnEmptyTranscriptIsNotReportedAsAProviderFailure() async throws {
        let store = try MeetingStore.inMemory()
        var session = try store.createSession()
        session.state = .processing
        try store.updateSession(session)

        let outcome = await FusionService(store: store)
            .fuse(session: session, provider: ThrowingFusionProvider(error: URLError(.timedOut)))

        XCTAssertEqual(outcome, .failure(.emptyTranscript))
        if case .failure(.provider) = outcome {
            XCTFail("a missing transcript must not be reported as an API failure")
        }
    }
}
