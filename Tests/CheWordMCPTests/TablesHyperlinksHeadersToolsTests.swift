import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// MCP-tool-level tests for che-word-mcp-tables-hyperlinks-headers-builtin
/// SDD (#49 / #50 / #51). Spec coverage:
/// - openspec/changes/.../specs/che-word-mcp-tables-tools/spec.md
/// - openspec/changes/.../specs/che-word-mcp-hyperlinks-tools/spec.md
/// - openspec/changes/.../specs/che-word-mcp-headers-footers-tools/spec.md
///
/// Implementation tasks 6.x / 7.x / 8.x will populate these tests; until then
/// they XCTSkip so the suite stays green.
final class TablesHyperlinksHeadersToolsTests: XCTestCase {

    // MARK: - Helpers

    func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    func openFreshDocument(_ server: WordMCPServer, id: String = "thh-test") async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
    }

    func discardDocument(_ server: WordMCPServer, id: String) async {
        _ = await server.invokeToolForTesting(
            name: "discard_changes",
            arguments: ["doc_id": .string(id)]
        )
    }

    // MARK: - Phase 6: Table tools

    /// Helper: insert a 2x2 table at the end of the doc so we have something to mutate.
    func insertTable(_ server: WordMCPServer, docId: String, rows: Int = 2, cols: Int = 2) async {
        _ = await server.invokeToolForTesting(name: "insert_table", arguments: [
            "doc_id": .string(docId),
            "rows": .int(rows),
            "cols": .int(cols)
        ])
    }

    func testSetTableConditionalStyleFirstRowBoldAfterTask61() async throws {
        let server = await WordMCPServer()
        let docId = "tcs-61-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }
        await insertTable(server, docId: docId)

        let r = await server.invokeToolForTesting(name: "set_table_conditional_style", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "type": .string("firstRow"),
            "properties": .object(["bold": .bool(true)])
        ])
        XCTAssertTrue(resultText(r).contains("firstRow"), "tool failed: \(resultText(r))")
    }

    func testInsertNestedTable2By2InCellAfterTask62() async throws {
        let server = await WordMCPServer()
        let docId = "int-62-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }
        await insertTable(server, docId: docId, rows: 3, cols: 3)

        let r = await server.invokeToolForTesting(name: "insert_nested_table", arguments: [
            "doc_id": .string(docId),
            "parent_table_index": .int(0),
            "row_index": .int(1),
            "col_index": .int(1),
            "rows": .int(2),
            "cols": .int(2)
        ])
        XCTAssertTrue(resultText(r).contains("Inserted") && resultText(r).contains("nested"),
            "tool failed: \(resultText(r))")
    }

    func testSetTableLayoutFixedAfterTask63() async throws {
        let server = await WordMCPServer()
        let docId = "stl-63-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }
        await insertTable(server, docId: docId)

        let r = await server.invokeToolForTesting(name: "set_table_layout", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "type": .string("fixed")
        ])
        XCTAssertTrue(resultText(r).contains("fixed"), "tool failed: \(resultText(r))")
    }

    func testSetHeaderRowOnRow0AfterTask63() async throws {
        let server = await WordMCPServer()
        let docId = "shr-63-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }
        await insertTable(server, docId: docId)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_index": .int(0)
        ])
        XCTAssertTrue(resultText(r).contains("header"), "tool failed: \(resultText(r))")
    }

    // MARK: - #230: set_header_row dedupe (row_index / row_count merged schema)

    /// row_index marks exactly that row as header — verified against the
    /// actual `<w:tblHeader/>` in the saved document, not just the reply text.
    func testSetHeaderRowRowIndexEmitsTblHeaderOnlyOnThatRow() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-idx-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-idx-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 3, cols: 2)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_index": .int(1)
        ])
        XCTAssertTrue(resultText(r).contains("row 1"), "tool failed: \(resultText(r))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [false, true, false])
    }

    /// row_count marks the first N rows (from row 0) as header — the
    /// semantic the dead duplicate schema promised but its handler never
    /// actually ran (#230).
    func testSetHeaderRowRowCountEmitsTblHeaderOnFirstNRows() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-cnt-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-cnt-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 3, cols: 2)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_count": .int(2)
        ])
        XCTAssertTrue(resultText(r).contains("first 2"), "tool failed: \(resultText(r))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [true, true, false])
    }

    /// Neither parameter given: backward-compatible default of row_index=0 —
    /// the behavior every existing caller of the (dispatch-reachable) schema
    /// already depended on.
    func testSetHeaderRowDefaultsToRowZeroWhenNeitherProvided() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-default-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-default-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 2, cols: 2)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0)
        ])
        XCTAssertTrue(resultText(r).contains("row 0"), "tool failed: \(resultText(r))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [true, false])
    }

    /// Supplying both row_index and row_count is ambiguous — the two dead
    /// schemas never agreed on precedence, so we refuse instead of silently
    /// picking one (per #230's "呼叫端不能在沒有錯誤訊息的情況下得到不同結果").
    /// Also proves the rejected call is a true no-op: saving afterwards shows
    /// no row was marked as header.
    func testSetHeaderRowRejectsBothRowIndexAndRowCount() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-both-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-both-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 3, cols: 2)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_index": .int(0),
            "row_count": .int(2)
        ])
        XCTAssertEqual(r.isError, true, "expected a parameter error: \(resultText(r))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [false, false, false],
                        "a rejected call must not mutate the document")
    }

    /// row_count outside 1...rows.count must error, not silently clamp or
    /// no-op, and (like the mutual-exclusivity case above) must not mutate
    /// the document.
    func testSetHeaderRowRowCountOutOfBoundsReturnsError() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-oob-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-oob-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 2, cols: 2)

        let r = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_count": .int(5)
        ])
        XCTAssertEqual(r.isError, true, "expected an out-of-bounds error: \(resultText(r))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [false, false],
                        "a rejected call must not mutate the document")
    }

    /// row_count = 0 and negative row_count are both outside 1...rows.count
    /// and must error, matching the dead schema's own documented bound
    /// ("Row count must be between 1 and N") rather than being treated as
    /// "no rows" or silently clamped. Both rejections must also be true
    /// no-ops (Codex round 2: the changelog claims this, so the test must
    /// actually check it, not just `isError`).
    func testSetHeaderRowRowCountZeroOrNegativeReturnsError() async throws {
        let server = await WordMCPServer()
        let docId = "shr-230-zero-\(UUID().uuidString)"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("shr-230-zero-\(UUID().uuidString).docx")
        defer {
            Task { await discardDocument(server, id: docId) }
            try? FileManager.default.removeItem(at: output)
        }
        await openFreshDocument(server, id: docId)
        await insertTable(server, docId: docId, rows: 2, cols: 2)

        let zero = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_count": .int(0)
        ])
        XCTAssertEqual(zero.isError, true, "row_count=0 must error: \(resultText(zero))")

        let negative = await server.invokeToolForTesting(name: "set_header_row", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "row_count": .int(-1)
        ])
        XCTAssertEqual(negative.isError, true, "row_count=-1 must error: \(resultText(negative))")

        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId),
            "path": .string(output.path)
        ])
        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let table = try XCTUnwrap(reopened.getTables().first)
        XCTAssertEqual(table.rows.map(\.properties.isHeader), [false, false],
                        "both rejected calls (row_count=0 and row_count=-1) must not mutate the document")
    }

    func testSetTableIndent720TwipsAfterTask63() async throws {
        let server = await WordMCPServer()
        let docId = "sti-63-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }
        await insertTable(server, docId: docId)

        let r = await server.invokeToolForTesting(name: "set_table_indent", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0),
            "value": .int(720)
        ])
        XCTAssertTrue(resultText(r).contains("720"), "tool failed: \(resultText(r))")
    }

    // MARK: - Phase 7: Hyperlink tools

    func testInsertUrlHyperlinkWithTooltipAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "iuhl-71-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_url_hyperlink", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "url": .string("https://example.com"),
            "text": .string("Example"),
            "tooltip": .string("Visit example")
        ])
        XCTAssertTrue(resultText(r).contains("Inserted URL hyperlink"), "tool failed: \(resultText(r))")
    }

    func testInsertBookmarkHyperlinkAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "ibhl-71-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_bookmark_hyperlink", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "anchor": .string("ChapterTwo"),
            "text": .string("See Chapter 2")
        ])
        XCTAssertTrue(resultText(r).contains("ChapterTwo"), "tool failed: \(resultText(r))")
    }

    func testInsertEmailHyperlinkWithSubjectAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "iehl-71-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_email_hyperlink", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "email": .string("support@example.com"),
            "text": .string("Contact"),
            "subject": .string("Question")
        ])
        XCTAssertTrue(resultText(r).contains("support@example.com"), "tool failed: \(resultText(r))")
    }

    // MARK: - Phase 8: Header tools

    func testEnableEvenOddHeadersAfterTask82() async throws {
        let server = await WordMCPServer()
        let docId = "eoh-82-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "enable_even_odd_headers", arguments: [
            "doc_id": .string(docId),
            "enabled": .bool(true)
        ])
        XCTAssertTrue(resultText(r).contains("true"), "tool failed: \(resultText(r))")
    }

    func testGetSectionHeaderMapReturnsArrayAfterTask84() async throws {
        let server = await WordMCPServer()
        let docId = "gshm-84-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "get_section_header_map", arguments: [
            "doc_id": .string(docId)
        ])
        let body = resultText(r)
        XCTAssertTrue(body.hasPrefix("["), "expected JSON array: \(body)")
        XCTAssertTrue(body.contains("\"section_index\": 0"), "missing section_index: \(body)")
    }

    // MARK: - Pre-existing sanity

    func testScaffoldBootsWordMCPServer() async {
        let server = await WordMCPServer()
        await openFreshDocument(server, id: "thh-boot")
        await discardDocument(server, id: "thh-boot")
    }
}
