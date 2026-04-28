import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#61 — `insert_paragraph` should accept the same
/// anchor parameters as `insert_image_from_path`: `after_text` / `before_text`
/// / `text_instance` / `into_table_cell`. Pre-fix only `index` works; passing
/// any anchor argument silently falls through to "append at end".
///
/// These RED tests pin the MCP-layer schema/dispatch wire-up. The lib API
/// (`Document.insertParagraph(_: at: InsertLocation)`) has supported all six
/// anchor cases since #44; #61 closes the MCP-side coverage gap.
final class Issue61InsertParagraphAnchorsSmokeTests: XCTestCase {

    private func minimalDocxWithAnchorPara() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "ABSTRACT_ANCHOR")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "tail")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_para_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    func testInsertParagraphAfterTextResolvesAnchor() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        let openR = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61")]
        )
        XCTAssertFalse(openR.isError == true, "open_document must succeed")

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61"),
                "text": .string("INSERTED_AFTER"),
                "after_text": .string("ABSTRACT_ANCHOR")
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_paragraph after_text should succeed; got: \(r.content)")

        // Verify position: INSERTED_AFTER should land between ABSTRACT_ANCHOR and tail.
        let getR = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("p61")]
        )
        let text = textOf(getR)
        guard let anchorPos = text.range(of: "ABSTRACT_ANCHOR")?.lowerBound,
              let insertPos = text.range(of: "INSERTED_AFTER")?.lowerBound,
              let tailPos = text.range(of: "tail")?.lowerBound else {
            return XCTFail("expected all three markers in get_paragraphs output: \(text)")
        }
        XCTAssertLessThan(anchorPos, insertPos, "INSERTED_AFTER must come AFTER ABSTRACT_ANCHOR")
        XCTAssertLessThan(insertPos, tailPos, "INSERTED_AFTER must come BEFORE tail")
    }

    func testInsertParagraphBeforeTextResolvesAnchor() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61b")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61b"),
                "text": .string("INSERTED_BEFORE"),
                "before_text": .string("ABSTRACT_ANCHOR")
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_paragraph before_text should succeed; got: \(r.content)")

        let getR = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("p61b")]
        )
        let text = textOf(getR)
        guard let insertPos = text.range(of: "INSERTED_BEFORE")?.lowerBound,
              let anchorPos = text.range(of: "ABSTRACT_ANCHOR")?.lowerBound else {
            return XCTFail("expected both markers: \(text)")
        }
        XCTAssertLessThan(insertPos, anchorPos, "INSERTED_BEFORE must come BEFORE ABSTRACT_ANCHOR")
    }

    func testInsertParagraphTextInstanceDisambiguates() async throws {
        // Two paragraphs both contain "DUPLICATE"; text_instance=2 should target the second.
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "first DUPLICATE here")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "middle filler")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "second DUPLICATE here")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "tail")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_dup_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61i")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61i"),
                "text": .string("AFTER_SECOND"),
                "after_text": .string("DUPLICATE"),
                "text_instance": .int(2)
            ]
        )
        XCTAssertFalse(r.isError == true, "text_instance=2 should resolve")

        let getR = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("p61i")]
        )
        let text = textOf(getR)
        guard let secondPos = text.range(of: "second DUPLICATE")?.lowerBound,
              let insertPos = text.range(of: "AFTER_SECOND")?.lowerBound,
              let tailPos = text.range(of: "tail")?.lowerBound else {
            return XCTFail("expected all markers: \(text)")
        }
        XCTAssertLessThan(secondPos, insertPos, "AFTER_SECOND must come AFTER second DUPLICATE")
        XCTAssertLessThan(insertPos, tailPos, "AFTER_SECOND must come BEFORE tail")
    }

    func testInsertParagraphIntoTableCellAppendsToCell() async throws {
        var doc = WordDocument()
        // Paragraph + 1x1 table.
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before table")])))
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell content")])])])
        ])
        doc.body.children.append(.table(table))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "after table")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_cell_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61c")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61c"),
                "text": .string("CELL_APPENDED"),
                "into_table_cell": .object([
                    "table_index": .int(0),
                    "row": .int(0),
                    "col": .int(0)
                ])
            ]
        )
        XCTAssertFalse(r.isError == true, "into_table_cell should succeed; got: \(r.content)")
    }

    func testInsertParagraphAfterTextNotFoundReturnsError() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61n")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61n"),
                "text": .string("WONT_LAND"),
                "after_text": .string("NONEXISTENT_ANCHOR")
            ]
        )
        // Pre-fix: the after_text param is silently dropped → no error returned, paragraph appended at end.
        // Post-fix: missing anchor must return a structured error message.
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("not found"),
            "missing anchor should report textNotFound, got: \(txt)"
        )
    }

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
