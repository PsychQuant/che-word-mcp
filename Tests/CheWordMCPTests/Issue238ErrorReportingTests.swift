import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#238 — two error-reporting bugs surfaced by #234's
/// eighth-round independent review:
///
/// 1. `delete_text_as_revision` names the wrong parameter in its error.
///    ooxml-swift's `WordDocument.deleteTextAsRevision` guards
///    `start >= 0, end >= start, end <= totalLength` as one compound
///    condition and always throws `WordError.invalidIndex(end)` — so
///    `start: -1, end: 3` and `start: 1000, end: 3` both say
///    "Invalid index: 3", blaming `end` when `start` is what is actually
///    out of range. The wrapper now pre-validates start/end itself (using
///    the same paragraph-lookup precondition order as the library —
///    track-changes-off and an out-of-range paragraph_index still surface
///    exactly as before) and names the true culprit.
///
/// 2. `create_numbering_definition` reports a `WordError.invalidIndex`
///    ("no valid levels" / "too many levels") from the library as a plain
///    success string (`{ "error": "invalid_levels", "count": 0 }`) with
///    `isError` unset — a client that only checks `isError` believes the
///    call succeeded. The wrapper now throws `ToolRefusal` for this case.
final class Issue238ErrorReportingTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _): return text
        default: return ""
        }
    }

    /// Sets up a doc with one paragraph of known text length, track changes on.
    private func makeTrackedDoc(_ server: WordMCPServer, docId: String, text: String) async {
        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(docId),
            "text": .string(text)
        ])
        _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
            "doc_id": .string(docId),
            "author": .string("Reviewer A")
        ])
    }

    // MARK: - delete_text_as_revision

    /// `start: -1, end: 3` — negative start is the actual problem.
    func testDeleteTextAsRevisionNegativeStartNamesStartNotEnd() async throws {
        let server = await WordMCPServer()
        let docId = "s238-del-negstart"
        await makeTrackedDoc(server, docId: docId, text: "Hello world")

        let r = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(-1),
            "end": .int(3)
        ])
        let text = resultText(r)
        XCTAssertEqual(r.isError, true, "negative start SHALL fail. Got: \(text)")
        XCTAssertTrue(text.contains("start"), "error SHALL name 'start'. Got: \(text)")
        XCTAssertTrue(text.contains("-1"), "error SHALL name start's actual value -1. Got: \(text)")
        XCTAssertFalse(text.contains("Invalid index: 3"),
            "the old wrong-parameter message (blaming end=3) must not reappear. Got: \(text)")
    }

    /// `start: 1000, end: 3` — start far exceeds the paragraph; start is the problem, not end.
    func testDeleteTextAsRevisionStartExceedsEndNamesStartNotEnd() async throws {
        let server = await WordMCPServer()
        let docId = "s238-del-startexceeds"
        await makeTrackedDoc(server, docId: docId, text: "Hello world") // length 11

        let r = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(1000),
            "end": .int(3)
        ])
        let text = resultText(r)
        XCTAssertEqual(r.isError, true, "start > end SHALL fail. Got: \(text)")
        XCTAssertTrue(text.contains("start"), "error SHALL name 'start'. Got: \(text)")
        XCTAssertTrue(text.contains("1000"), "error SHALL name start's actual value 1000. Got: \(text)")
        XCTAssertFalse(text.contains("Invalid index: 3"),
            "the old wrong-parameter message (blaming end=3) must not reappear. Got: \(text)")
    }

    /// `end` beyond the paragraph's own length IS the real problem in this
    /// case — naming `end` here is correct and must keep working.
    func testDeleteTextAsRevisionEndExceedsParagraphLengthNamesEnd() async throws {
        let server = await WordMCPServer()
        let docId = "s238-del-endexceeds"
        await makeTrackedDoc(server, docId: docId, text: "Hi") // length 2

        let r = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(0),
            "end": .int(50)
        ])
        let text = resultText(r)
        XCTAssertEqual(r.isError, true, "end beyond paragraph length SHALL fail. Got: \(text)")
        XCTAssertTrue(text.contains("end"), "error SHALL name 'end'. Got: \(text)")
        XCTAssertTrue(text.contains("50"), "error SHALL name end's actual value 50. Got: \(text)")
    }

    /// A valid range still succeeds — the fix must not break the working path.
    func testDeleteTextAsRevisionValidRangeStillSucceeds() async throws {
        let server = await WordMCPServer()
        let docId = "s238-del-valid"
        await makeTrackedDoc(server, docId: docId, text: "Hello world")

        let r = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(0),
            "end": .int(5)
        ])
        let text = resultText(r)
        XCTAssertNotEqual(r.isError, true, "a valid range SHALL still succeed. Got: \(text)")
        XCTAssertTrue(text.contains("revision id"), "Got: \(text)")
    }

    /// Track-changes-off still refuses with its own message — untouched by
    /// this fix's start/end pre-check (order must not change).
    func testDeleteTextAsRevisionStillRejectsWhenTrackChangesOff() async throws {
        let server = await WordMCPServer()
        let docId = "s238-del-notracking"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(docId),
            "text": .string("Hello world")
        ])
        // Track changes deliberately left off.

        let r = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(0),
            "end": .int(3)
        ])
        let text = resultText(r)
        XCTAssertEqual(r.isError, true, "track changes off SHALL still fail. Got: \(text)")
    }

    // MARK: - create_numbering_definition

    /// Every level missing `ilvl` → no valid levels at all → SHALL be `isError: true`.
    func testCreateNumberingDefinitionAllLevelsMissingIlvlFailsHonestly() async throws {
        let server = await WordMCPServer()
        let docId = "s238-numdef-noilvl"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])

        let r = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([
                .object(["num_format": .string("decimal"), "lvl_text": .string("%1.")])
            ])
        ])
        let text = resultText(r)
        XCTAssertEqual(r.isError, true,
            "no valid levels (all missing ilvl) SHALL fail, not return isError:false with an 'error' JSON body. Got: \(text)")
        XCTAssertTrue(text.contains("levels"), "error SHALL name 'levels'. Got: \(text)")

        _ = await server.invokeToolForTesting(name: "close_document",
            arguments: ["doc_id": .string(docId), "discard_changes": .bool(true)])
    }

    /// A real, valid level list still succeeds — the fix must not break the working path.
    func testCreateNumberingDefinitionValidLevelStillSucceeds() async throws {
        let server = await WordMCPServer()
        let docId = "s238-numdef-valid"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])

        let r = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([
                .object([
                    "ilvl": .int(0),
                    "num_format": .string("decimal"),
                    "lvl_text": .string("%1.")
                ])
            ])
        ])
        let text = resultText(r)
        XCTAssertNotEqual(r.isError, true, "a valid level list SHALL still succeed. Got: \(text)")
        XCTAssertTrue(text.contains("num_id"), "Got: \(text)")

        _ = await server.invokeToolForTesting(name: "close_document",
            arguments: ["doc_id": .string(docId), "discard_changes": .bool(true)])
    }
}
