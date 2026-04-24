import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// MCP-tool-level tests for che-word-mcp-track-changes-programmatic-generation
/// SDD (#45). Spec coverage:
///   openspec/changes/che-word-mcp-track-changes-programmatic-generation/specs/
///     che-word-mcp-tracked-changes-tools/spec.md
///
/// Scaffold landed by task 1.2. Tool tests fill in across tasks 5.x:
///   - 5.1 insert_text_as_revision
///   - 5.2 delete_text_as_revision
///   - 5.3 move_text_as_revision
///   - 5.4 format_text(as_revision: true)
///   - 5.5 set_paragraph_format(as_revision: true)
///
/// Until each task lands, the scenario tests XCTSkip so the suite stays green.
final class TrackChangesProgrammaticToolsTests: XCTestCase {

    // MARK: - Helpers (mirror StylesNumberingSectionsToolsTests shape)

    func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    /// Open a fresh document and insert one anchor paragraph "Hello World" so
    /// callers have a body that can be revised in subsequent calls.
    func openFreshDocument(_ server: WordMCPServer, id: String) async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(id), "text": .string("Hello World")]
        )
    }

    /// Open a fresh document AND enable track changes with the given author.
    /// Use this when the test exercises the happy path; tests that verify
    /// the track_changes_not_enabled guard should call `openFreshDocument`
    /// directly without enabling.
    func openWithTrackChanges(_ server: WordMCPServer, id: String,
                              author: String) async {
        await openFreshDocument(server, id: id)
        _ = await server.invokeToolForTesting(
            name: "enable_track_changes",
            arguments: ["doc_id": .string(id), "author": .string(author)]
        )
    }

    func discardDocument(_ server: WordMCPServer, id: String) async {
        _ = await server.invokeToolForTesting(
            name: "discard_changes",
            arguments: ["doc_id": .string(id)]
        )
    }

    // MARK: - Substring Assertions

    /// Assert the JSON-stringified tool result contains the substring (case-
    /// sensitive). Wraps both successful payloads and error JSON since both
    /// surface as the first content text item.
    func assertResultContains(_ result: CallTool.Result, _ substring: String,
                              file: StaticString = #file, line: UInt = #line) {
        let body = resultText(result)
        XCTAssertTrue(body.contains(substring),
                      "expected substring \"\(substring)\" in result; got: \(body)",
                      file: file, line: line)
    }

    func assertResultIsTrackChangesNotEnabled(_ result: CallTool.Result,
                                              file: StaticString = #file,
                                              line: UInt = #line) {
        assertResultContains(result, "track_changes_not_enabled",
                             file: file, line: line)
    }

    // MARK: - Smoke Tests (always pass; verify scaffold compiles)

    func testScaffoldCompiles() async {
        let server = await WordMCPServer()
        let docId = "tc-scaffold-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        await discardDocument(server, id: docId)
    }

    // MARK: - Task 5.1: insert_text_as_revision
    // (filled in by task 5.1)

    func testInsertTextAsRevisionAddsInsRevision() async throws {
        try XCTSkipIf(true, "implemented in task 5.1")
    }

    func testInsertTextAsRevisionRejectsWhenTrackChangesOff() async throws {
        try XCTSkipIf(true, "implemented in task 5.1")
    }

    // MARK: - Task 5.2: delete_text_as_revision
    // (filled in by task 5.2)

    func testDeleteTextAsRevisionAddsDelRevision() async throws {
        try XCTSkipIf(true, "implemented in task 5.2")
    }

    func testDeleteTextAsRevisionRejectsOutOfBoundsRange() async throws {
        try XCTSkipIf(true, "implemented in task 5.2")
    }

    // MARK: - Task 5.3: move_text_as_revision
    // (filled in by task 5.3)

    func testMoveTextAsRevisionAllocatesPairedIds() async throws {
        try XCTSkipIf(true, "implemented in task 5.3")
    }

    // MARK: - Task 5.4: format_text as_revision arg
    // (filled in by task 5.4)

    func testFormatTextAsRevisionEmitsRPrChange() async throws {
        try XCTSkipIf(true, "implemented in task 5.4")
    }

    func testFormatTextAsRevisionDefaultFalsePreservesV311Behavior() async throws {
        try XCTSkipIf(true, "implemented in task 5.4")
    }

    // MARK: - Task 5.5: set_paragraph_format as_revision arg
    // (filled in by task 5.5)

    func testSetParagraphFormatAsRevisionEmitsPPrChange() async throws {
        try XCTSkipIf(true, "implemented in task 5.5")
    }
}
