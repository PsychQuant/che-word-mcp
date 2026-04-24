import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// E2E tests for che-word-mcp-track-changes-programmatic-generation SDD (#45).
/// Spec coverage:
///   openspec/changes/che-word-mcp-track-changes-programmatic-generation/specs/
///     che-word-mcp-tracked-changes-tools/spec.md
///
/// Tasks 6.1 / 6.2 / 6.3 from tasks.md — covers:
///   - Contract redline workflow round-trip (insert + delete + format change)
///   - Multi-author author-resolution chain (settings author vs explicit override)
///   - Side-effect avoidance (as_revision=true with track changes off)
final class ContractRedlineE2ETests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _): return text
        default: return ""
        }
    }

    // MARK: - Task 6.1: Contract redline round-trip

    func testContractRedlineRoundTrip() async throws {
        let server = await WordMCPServer()
        let docId = "redline-\(UUID().uuidString)"
        let savePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("redline-\(UUID().uuidString).docx").path
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(docId),
            "text": .string("The contract amount is $100,000.")
        ])
        _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
            "doc_id": .string(docId),
            "author": .string("Reviewer A")
        ])

        let appendResult = await server.invokeToolForTesting(name: "insert_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "position": .int(32),
            "text": .string(" (subject to escalation)")
        ])
        XCTAssertTrue(resultText(appendResult).contains("revision id"),
                      "expected success message; got: \(resultText(appendResult))")

        let deleteResult = await server.invokeToolForTesting(name: "delete_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "start": .int(23),
            "end": .int(31)
        ])
        XCTAssertTrue(resultText(deleteResult).contains("revision id"),
                      "expected success message; got: \(resultText(deleteResult))")

        let formatResult = await server.invokeToolForTesting(name: "format_text", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "bold": .bool(true),
            "as_revision": .bool(true),
            "run_index": .int(0)
        ])
        XCTAssertTrue(resultText(formatResult).contains("revision"),
                      "expected revision-mode formatting; got: \(resultText(formatResult))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(savePath)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath))

        let reopened = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertGreaterThanOrEqual(reopened.revisions.revisions.count, 3,
            "expected 3+ revisions after round-trip, got \(reopened.revisions.revisions.count)")

        let authors = Set(reopened.revisions.revisions.map { $0.author })
        XCTAssertTrue(authors.contains("Reviewer A"),
            "expected 'Reviewer A' among authors; got \(authors)")

        let ids = reopened.revisions.revisions.map { $0.id }.sorted()
        XCTAssertEqual(ids.first, 1, "first revision id must be 1 (max+1 from empty)")
    }

    // MARK: - Task 6.2: Multi-author interleaving

    func testMultiAuthorRevisionInterleaving() async throws {
        let server = await WordMCPServer()
        let docId = "multi-author-\(UUID().uuidString)"
        let savePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("multi-author-\(UUID().uuidString).docx").path
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(docId)
        ])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(docId),
            "text": .string("Anchor")
        ])

        // Author A — settings only
        _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
            "doc_id": .string(docId),
            "author": .string("Author A")
        ])
        _ = await server.invokeToolForTesting(name: "insert_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "position": .int(0),
            "text": .string("[A1] ")
        ])

        // Disable + re-enable as Author B
        _ = await server.invokeToolForTesting(name: "disable_track_changes", arguments: [
            "doc_id": .string(docId)
        ])
        _ = await server.invokeToolForTesting(name: "enable_track_changes", arguments: [
            "doc_id": .string(docId),
            "author": .string("Author B")
        ])

        // Insert with explicit override → "Author C"
        _ = await server.invokeToolForTesting(name: "insert_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "position": .int(0),
            "text": .string("[C1] "),
            "author": .string("Author C")
        ])

        // Insert without explicit author → falls back to settings (Author B)
        _ = await server.invokeToolForTesting(name: "insert_text_as_revision", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "position": .int(0),
            "text": .string("[B1] ")
        ])

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(savePath)
        ])
        let reopened = try DocxReader.read(from: URL(fileURLWithPath: savePath))

        XCTAssertGreaterThanOrEqual(reopened.revisions.revisions.count, 3,
            "expected at least 3 revisions; got \(reopened.revisions.revisions.count)")

        let authors = Set(reopened.revisions.revisions.map { $0.author })
        XCTAssertTrue(authors.contains("Author A"), "expected Author A among authors; got \(authors)")
        XCTAssertTrue(authors.contains("Author C"), "expected Author C explicit override; got \(authors)")
        XCTAssertTrue(authors.contains("Author B"), "expected Author B fallback from settings; got \(authors)")

        let ids = reopened.revisions.revisions.map { $0.id }.sorted()
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(id, i + 1, "expected sequential ids starting at 1; got \(ids)")
        }
    }

    // MARK: - Task 6.3: Side-effect avoidance

    /// `create_document` and the storeDocument enforcement layer both auto-enable
    /// track changes by design (see `enforceTrackChangesIfNeeded` in Server.swift).
    /// To exercise the "off" guard at the MCP layer we must `open_document` with
    /// `track_changes: false`, which bypasses enforcement.
    func testFormatTextAsRevisionRejectsWhenTrackChangesOffNoSideEffect() async throws {
        let server = await WordMCPServer()
        let setupDocId = "setup-\(UUID().uuidString)"
        let docId = "no-side-effect-\(UUID().uuidString)"
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nse-\(UUID().uuidString).docx").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Stage 1: create + save a baseline doc.
        _ = await server.invokeToolForTesting(name: "create_document", arguments: [
            "doc_id": .string(setupDocId)
        ])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(setupDocId),
            "text": .string("Untouchable")
        ])
        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(setupDocId),
            "path": .string(path)
        ])
        _ = await server.invokeToolForTesting(name: "close_document", arguments: [
            "doc_id": .string(setupDocId)
        ])

        // Stage 2: re-open WITHOUT track changes enforcement.
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(path),
            "track_changes": .bool(false)
        ])
        _ = await server.invokeToolForTesting(name: "disable_track_changes", arguments: [
            "doc_id": .string(docId)
        ])

        // Stage 3: format_text(as_revision: true) MUST fail with the guard.
        let result = await server.invokeToolForTesting(name: "format_text", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "bold": .bool(true),
            "as_revision": .bool(true)
        ])
        let body = resultText(result)
        XCTAssertTrue(body.contains("track_changes_not_enabled"),
            "expected error mentioning track_changes_not_enabled; got: \(body)")
    }
}
