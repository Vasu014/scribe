import XCTest
@testable import FusionKit
import Persistence

final class EvalCaseTests: XCTestCase {

    /// Pinned fixture matching the SPEC §4.5 eval-case JSON schema verbatim —
    /// decoding must never regress; this is the contract with the shared
    /// `evals/` corpus and the weekly merge (SPEC §9).
    private let fixtureJSON = #"""
    {
      "schema_version": 1,
      "prompt_version": "1",
      "model": "claude-sonnet-4-5",
      "session_id": "e621e1f8-c36c-495a-8a27-bf84db2c1ab1",
      "session_started_at": "2026-08-14T09:15:00Z",
      "title": "Acme renewal call",
      "transcript": [
        {"channel": "me", "text": "Let's start with the renewal.", "start_offset": 0.0, "end_offset": 2.5},
        {"channel": "them", "text": "We should defer the migration.", "start_offset": 860.0, "end_offset": 890.0}
      ],
      "fragments": [
        {"text": "pricing objection", "anchor_offset": 140.0}
      ],
      "output": "Title: Acme renewal call\n\n## Summary\nDiscussed renewal terms and timeline.",
      "corrected_output": null,
      "validator_result": "pass",
      "exported_at": "2026-08-14T10:00:00Z",
      "machine_id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    }
    """#

    private func decodeFixture() throws -> EvalCase {
        try EvalCase.makeDecoder().decode(EvalCase.self, from: Data(fixtureJSON.utf8))
    }

    // MARK: Pinned-schema decode

    func testDecodePinnedFixture() throws {
        let decoded = try decodeFixture()
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.promptVersion, "1")
        XCTAssertEqual(decoded.model, "claude-sonnet-4-5")
        XCTAssertEqual(decoded.sessionId.uuidString, "E621E1F8-C36C-495A-8A27-BF84DB2C1AB1")
        XCTAssertEqual(decoded.sessionStartedAt, ISO8601DateFormatter().date(from: "2026-08-14T09:15:00Z"))
        XCTAssertEqual(decoded.title, "Acme renewal call")
        XCTAssertEqual(decoded.transcript.count, 2)
        XCTAssertEqual(decoded.transcript[0].channel, "me")
        XCTAssertEqual(decoded.transcript[0].text, "Let's start with the renewal.")
        XCTAssertEqual(decoded.transcript[0].startOffset, 0)
        XCTAssertEqual(decoded.transcript[1].channel, "them")
        XCTAssertEqual(decoded.transcript[1].startOffset, 860)
        XCTAssertEqual(decoded.transcript[1].endOffset, 890)
        XCTAssertEqual(decoded.fragments.count, 1)
        XCTAssertEqual(decoded.fragments[0].text, "pricing objection")
        XCTAssertEqual(decoded.fragments[0].anchorOffset, 140)
        XCTAssertEqual(decoded.output, "Title: Acme renewal call\n\n## Summary\nDiscussed renewal terms and timeline.")
        XCTAssertNil(decoded.correctedOutput)
        XCTAssertEqual(decoded.validatorResult, "pass")
        XCTAssertEqual(decoded.machineId, "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    }

    // MARK: Round trip

    func testRoundTripCodableAgainstFixture() throws {
        let decoded = try decodeFixture()
        let encoded = try decoded.encodedJSON()
        let redecoded = try EvalCase.makeDecoder().decode(EvalCase.self, from: encoded)
        XCTAssertEqual(redecoded, decoded, "encode → decode must be lossless")

        // Key set stays pinned to SPEC §4.5 — no schema drift.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "schema_version", "prompt_version", "model", "session_id", "session_started_at",
            "title", "transcript", "fragments", "output", "corrected_output",
            "validator_result", "exported_at", "machine_id",
        ])
    }

    // MARK: Builder

    func testBuildFromStoreRecords() throws {
        let store = try MeetingStore.inMemory()
        // Pinned whole-second dates: ISO-8601 round-trips truncate
        // sub-second precision, which would break full-value equality.
        let session = try store.createSession(startedAt: Date(timeIntervalSince1970: 1000))
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .local, text: "hello there",
            startOffset: 0, endOffset: 2, isFinal: true
        ))
        try store.upsertSegment(SegmentRecord(
            sessionId: session.id, channel: .remote, text: "defer the migration",
            startOffset: 10, endOffset: 12, isFinal: true
        ))
        try store.upsertFragment(FragmentRecord(sessionId: session.id, text: "note one", anchorOffset: 30))
        let note = NoteRecord(sessionId: session.id, markdown: "Title: X", model: "m1", promptVersion: "1")

        let evalCase = EvalCase.build(
            session: session,
            segments: try store.segments(sessionId: session.id),
            fragments: try store.fragments(sessionId: session.id),
            note: note,
            validatorFindings: [NotesValidator.Finding(kind: .quoteMismatch, detail: "no match")],
            correctedOutput: "Title: Fixed",
            exportedAt: Date(timeIntervalSince1970: 0),
            machineId: "fixed-machine"
        )

        XCTAssertEqual(evalCase.schemaVersion, 1)
        XCTAssertEqual(evalCase.sessionId, session.id)
        XCTAssertEqual(evalCase.sessionStartedAt, session.startedAt)
        XCTAssertEqual(evalCase.transcript.map(\.channel), ["me", "them"])
        XCTAssertEqual(evalCase.transcript[1].text, "defer the migration")
        XCTAssertEqual(evalCase.transcript[1].startOffset, 10)
        XCTAssertEqual(evalCase.fragments.first?.text, "note one")
        XCTAssertEqual(evalCase.fragments.first?.anchorOffset, 30)
        XCTAssertEqual(evalCase.output, "Title: X")
        XCTAssertEqual(evalCase.model, "m1")
        XCTAssertEqual(evalCase.promptVersion, "1")
        XCTAssertEqual(evalCase.correctedOutput, "Title: Fixed")
        XCTAssertEqual(evalCase.validatorResult, "quoteMismatch: no match")
        XCTAssertEqual(evalCase.machineId, "fixed-machine")

        // Built cases round-trip through the canonical coder too.
        let redecoded = try EvalCase.makeDecoder().decode(EvalCase.self, from: evalCase.encodedJSON())
        XCTAssertEqual(redecoded, evalCase)
    }

    func testValidatorResultText() {
        XCTAssertEqual(EvalCase.validatorResultText([]), "pass")
        XCTAssertEqual(
            EvalCase.validatorResultText([
                NotesValidator.Finding(kind: .missingTimestamp, detail: "out of range"),
                NotesValidator.Finding(kind: .quoteMismatch, detail: "no span"),
            ]),
            "missingTimestamp: out of range\nquoteMismatch: no span"
        )
    }

    // MARK: Machine id

    func testMachineIdGeneratedOnceAndPersisted() throws {
        let suiteName = "scribe-evalcase-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = EvalCase.machineId(defaults: defaults)
        XCTAssertEqual(EvalCase.machineId(defaults: defaults), first,
                       "id is generated once and then read back")
        XCTAssertNotNil(UUID(uuidString: first), "expected a UUID string")
    }
}
