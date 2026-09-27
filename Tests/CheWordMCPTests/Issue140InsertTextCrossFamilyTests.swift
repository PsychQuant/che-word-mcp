import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#140 — `insert_text` bounds-checks `paragraph_index`
/// against `doc.getParagraphs()` (the readback family, which recurses into
/// block-level SDTs) but mutates via `doc.updateParagraph(at:)`, which walks
/// only TOP-LEVEL `.paragraph` body children. In a document with a
/// block-level SDT, the two counting schemes diverge for any index at or
/// past the SDT's position: the readback-based bounds check both selects
/// `currentText` from the WRONG paragraph (the SDT-inner one) and reports a
/// misleading valid range, while the actual mutation still resolves the
/// index against the top-level list.
///
/// Fixture: `body.children` = [paragraph("P0"), table, paragraph("P1"),
/// contentControl(SDT wrapping paragraph("sdt-inner")), paragraph("P2")].
/// `getParagraphs()` (readback) = [P0, P1, sdt-inner, P2] (count 4).
/// Top-level `.paragraph` ordinals = [P0, P1, P2] (count 3).
/// `paragraph_index: 2` is readback's `sdt-inner` but top-level's `P2`.
final class Issue140InsertTextCrossFamilyTests: XCTestCase {

    private func mixedShapeFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P1")])))
        let sdt = StructuredDocumentTag(
            id: 14101,
            tag: "issue141_wrapper",
            alias: "Issue 141 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P2")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue141_it_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    /// `paragraph_index: 2` is within BOTH the readback count (4) and the
    /// top-level count (3), so the buggy readback-based bounds check never
    /// rejects it — but readback's index 2 is `sdt-inner`, while the
    /// mutation that always follows resolves top-level index 2 to `P2`.
    /// Pre-fix: `currentText` is read from `sdt-inner` ("sdt-inner") and the
    /// resulting string is written OVER `P2`, discarding `P2`'s own text.
    /// Post-fix: `currentText` must come from `P2` itself (top-level index
    /// 2), and `sdt-inner` must be left completely untouched.
    func testInsertTextAtTopLevelOrdinalDoesNotLeakSDTInnerText() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i141a")]
        )

        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_text",
            arguments: [
                "doc_id": .string("i141a"),
                "paragraph_index": .int(2),
                "text": .string("X")
            ]
        )
        XCTAssertTrue(textOf(r).contains("Inserted text"), "expected success; got: \(textOf(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("i141a"), "path": .string(savePath)]
        )

        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertEqual(saved.body.children.count, 5, "insert_text must never add or remove a body child")

        guard case .paragraph(let p2) = saved.body.children[4] else {
            XCTFail("body.children[4] should still be the 'P2' paragraph")
            return
        }
        XCTAssertEqual(p2.getText(), "P2X", "paragraph_index 2 (top-level ordinal) must append to P2's OWN text, not sdt-inner's")

        guard case .contentControl(_, let children) = saved.body.children[3],
              case .paragraph(let sdtInner) = children.first else {
            XCTFail("body.children[3] should still be the block-level SDT wrapping 'sdt-inner'")
            return
        }
        XCTAssertEqual(sdtInner.getText(), "sdt-inner", "the SDT-inner paragraph must be completely untouched")
    }

    /// `paragraph_index: 3` is within the readback count (4, `P2`) but at/
    /// past the top-level count (3) — top-level ordinal 3 does not exist.
    /// Must be rejected as out of range, not accepted because it happened to
    /// be in bounds for the readback family.
    func testInsertTextRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i141b")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_text",
            arguments: [
                "doc_id": .string("i141b"),
                "paragraph_index": .int(3),
                "text": .string("X")
            ]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist (only 0-2); must be a structured error, not a readback-sized silent acceptance")
    }
}
