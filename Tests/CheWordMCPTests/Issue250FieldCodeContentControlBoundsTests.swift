import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#250 — the field-code family (`insert_if_field`,
/// `insert_calculation_field`, `insert_date_field`, `insert_page_field`,
/// `insert_merge_field`, `insert_sequence_field`) and `insert_content_control`
/// each bounds-check `paragraph_index` inside ooxml-swift's
/// `insertFieldCode`/`insertContentControl` against `doc.getParagraphs()`
/// (the readback family, which recurses into block-level SDTs) but their own
/// "not found" fallback walks only TOP-LEVEL `.paragraph` body children. In
/// a document with a table or block-level SDT, an index that is in-bounds
/// for the readback count but at/past the top-level count falls through
/// that fallback and silently APPENDS a brand-new paragraph at the very end
/// of the document, reporting success — never targeting the paragraph the
/// caller asked for.
///
/// Fixture (same shape as #140's Issue140InsertTextCrossFamilyTests):
/// `body.children` = [paragraph("P0"), table, paragraph("P1"),
/// contentControl(SDT wrapping paragraph("sdt-inner")), paragraph("P2")].
/// `getParagraphs()` (readback) = [P0, P1, sdt-inner, P2] (count 4).
/// Top-level `.paragraph` ordinals = [P0, P1, P2] (count 3).
final class Issue250FieldCodeContentControlBoundsTests: XCTestCase {

    private func mixedShapeFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P1")])))
        let sdt = StructuredDocumentTag(
            id: 25001,
            tag: "issue250_wrapper",
            alias: "Issue 250 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P2")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue250_fc_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func open(_ server: WordMCPServer, docId: String) async throws -> URL {
        let url = try mixedShapeFixture()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )
        return url
    }

    private func minimalArgs(for tool: String, docId: String, paragraphIndex: Int) -> [String: Value] {
        var args: [String: Value] = ["doc_id": .string(docId), "paragraph_index": .int(paragraphIndex)]
        switch tool {
        case "insert_if_field":
            args["left_operand"] = .string("1")
            args["operator"] = .string("=")
            args["right_operand"] = .string("1")
            args["true_text"] = .string("yes")
            args["false_text"] = .string("no")
        case "insert_calculation_field":
            args["expression"] = .string("SUM(ABOVE)")
        case "insert_date_field":
            break
        case "insert_page_field":
            break
        case "insert_merge_field":
            args["field_name"] = .string("Name")
        case "insert_sequence_field":
            args["identifier"] = .string("Figure")
        default:
            break
        }
        return args
    }

    /// `paragraph_index: 3` is within the readback count (4, `P2`) but at/
    /// past the top-level count (3, only P0/P1/P2 exist) — top-level
    /// ordinal 3 does not exist. Pre-fix, every one of these six field-code
    /// tools silently APPENDED a new paragraph containing just the field run
    /// at the very end of the document and reported success (`body.children`
    /// grew from 5 to 6). Post-fix, all six must reject.
    func testFieldCodeToolsRejectIndexPastTopLevelCount() async throws {
        let fieldCodeTools = [
            "insert_if_field", "insert_calculation_field", "insert_date_field",
            "insert_page_field", "insert_merge_field", "insert_sequence_field"
        ]
        for tool in fieldCodeTools {
            let server = await WordMCPServer()
            let docId = "i250-\(tool)"
            _ = try await open(server, docId: docId)

            let r = await server.invokeToolForTesting(
                name: tool,
                arguments: minimalArgs(for: tool, docId: docId, paragraphIndex: 3)
            )
            XCTAssertEqual(
                r.isError, true,
                "\(tool): top-level ordinal 3 does not exist (only 0-2); must be a structured error, not a readback-sized silent append. Got: \(textOf(r))"
            )
            XCTAssertTrue(
                textOf(r).contains("paragraph_index"),
                "\(tool): error should name paragraph_index. Got: \(textOf(r))"
            )
        }
    }

    /// A valid top-level index (2, targeting `P2`) must still succeed and
    /// must NOT grow `body.children` — the field/control is attached to the
    /// existing paragraph, not appended as a new one.
    func testFieldCodeToolsAcceptValidTopLevelIndexWithoutAppending() async throws {
        let fieldCodeTools = [
            "insert_if_field", "insert_calculation_field", "insert_date_field",
            "insert_page_field", "insert_merge_field", "insert_sequence_field"
        ]
        for tool in fieldCodeTools {
            let server = await WordMCPServer()
            let docId = "i250v-\(tool)"
            let url = try await open(server, docId: docId)

            let r = await server.invokeToolForTesting(
                name: tool,
                arguments: minimalArgs(for: tool, docId: docId, paragraphIndex: 2)
            )
            XCTAssertNotEqual(r.isError, true, "\(tool): valid top-level index 2 should succeed. Got: \(textOf(r))")

            let savePath = url.path + ".\(tool).out"
            defer { try? FileManager.default.removeItem(atPath: savePath) }
            _ = await server.invokeToolForTesting(
                name: "save_document",
                arguments: ["doc_id": .string(docId), "path": .string(savePath)]
            )
            let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
            XCTAssertEqual(
                saved.body.children.count, 5,
                "\(tool): must attach to the existing P2 paragraph, not append a 6th body child"
            )
        }
    }

    /// `insert_content_control` is different: `paragraph_index ==
    /// topLevelParagraphCount` (3, one past P2) is an established, tested
    /// "append as new last paragraph" convention (see
    /// ContentControlToolsTests / InvoiceTemplateE2ETests) and must keep
    /// working. Two INDEPENDENT documents (not the same doc after a
    /// mutation, since appending itself changes topLevelParagraphCount):
    /// index 3 (== topLevelParagraphCount) succeeds; index 4 (strictly past
    /// it, inside the SDT-widened readback gap of 4) must be rejected.
    func testInsertContentControlAllowsAppendAtTopLevelCount() async throws {
        let server = await WordMCPServer()
        let docId = "i250-cc-append"
        _ = try await open(server, docId: docId)

        let appended = await server.invokeToolForTesting(
            name: "insert_content_control",
            arguments: [
                "doc_id": .string(docId),
                "paragraph_index": .int(3),
                "type": .string("text"),
                "tag": .string("issue250_tag"),
                "content": .string("hello")
            ]
        )
        XCTAssertNotEqual(
            appended.isError, true,
            "insert_content_control: paragraph_index == topLevelParagraphCount (append convention) must still work. Got: \(textOf(appended))"
        )
    }

    func testInsertContentControlRejectsIndexStrictlyPastTopLevelCount() async throws {
        let server = await WordMCPServer()
        let docId = "i250-cc-reject"
        _ = try await open(server, docId: docId)

        let rejected = await server.invokeToolForTesting(
            name: "insert_content_control",
            arguments: [
                "doc_id": .string(docId),
                "paragraph_index": .int(4),
                "type": .string("text"),
                "tag": .string("issue250_tag2"),
                "content": .string("world")
            ]
        )
        XCTAssertEqual(
            rejected.isError, true,
            "insert_content_control: paragraph_index 4 is strictly past topLevelParagraphCount (3) and inside the readback gap (4); must reject, not silently append. Got: \(textOf(rejected))"
        )
        XCTAssertTrue(textOf(rejected).contains("paragraph_index"), textOf(rejected))
    }
}
