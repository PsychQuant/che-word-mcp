import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#251 — `insert_column_break` bounds-checked
/// `paragraph_index` against `doc.getParagraphs()` (the readback family,
/// which recurses into block-level SDTs but skips tables) and then inserted
/// the column-break paragraph at `body.children[paragraph_index + 1]` — a
/// DIFFERENT index family (`body.children` insertion index). In a document
/// with a table or block-level SDT before the target paragraph, the two
/// counting schemes diverge: a readback-in-range index can land the break
/// BEFORE the intended paragraph, or target something that isn't the
/// paragraph the caller meant at all.
///
/// Fixture (same shape as #140/#250): `body.children` = [paragraph("P0"),
/// table, paragraph("P1"), contentControl(SDT wrapping
/// paragraph("sdt-inner")), paragraph("P2")].
/// `getParagraphs()` (readback) = [P0, P1, sdt-inner, P2] (count 4).
/// Top-level `.paragraph` ordinals = [P0, P1, P2] at body.children
/// positions [0, 2, 4].
final class Issue251ColumnBreakIndexFamilyTests: XCTestCase {

    private func mixedShapeFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P1")])))
        let sdt = StructuredDocumentTag(
            id: 25101,
            tag: "issue251_wrapper",
            alias: "Issue 251 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P2")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue251_cb_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    /// `paragraph_index: 1` under the TOP-LEVEL family targets `P1`, whose
    /// ACTUAL `body.children` position is 2 (after the table). The break
    /// must land immediately AFTER `P1` — i.e. as the new `body.children[3]`
    /// — not before it. Pre-fix, the buggy code inserted at
    /// `body.children[paragraph_index + 1]` = `body.children[2]`, which is
    /// P1's OWN slot, so the break paragraph landed BEFORE P1 instead of
    /// after it.
    func testColumnBreakLandsAfterTargetParagraphNotBeforeIt() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        let docId = "i251a"

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_column_break",
            arguments: ["doc_id": .string(docId), "paragraph_index": .int(1)]
        )
        XCTAssertNotEqual(r.isError, true, "expected success; got: \(textOf(r))")

        // `insert_column_break` writes a literal U+000C form-feed character
        // as its run text, which is NOT valid XML 1.0 PCDATA — a pre-existing,
        // unrelated quirk of this tool (not in #251's scope) that makes a
        // save+reopen round-trip via DocxReader fail with an XML parse
        // error. Inspect placement directly against the in-memory document
        // via `get_paragraphs` (readback family — recurses into block-level
        // SDTs but skips tables) instead of round-tripping through disk.
        let listed = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string(docId)]
        )
        let listedText = textOf(listed)
        // Expected readback order after inserting the break as the new
        // top-level body child right after P1's actual body.children
        // position: [P0, P1, <break>, sdt-inner, P2].
        XCTAssertTrue(listedText.contains("[0]") && listedText.contains("P0"), listedText)
        guard let p1Range = listedText.range(of: "[1]"),
              let breakRange = listedText.range(of: "[2]"),
              let sdtRange = listedText.range(of: "[3]"),
              let p2Range = listedText.range(of: "[4]") else {
            XCTFail("expected 5 readback paragraphs after insertion, got: \(listedText)")
            return
        }
        let p1Line = String(listedText[p1Range.lowerBound..<breakRange.lowerBound])
        let breakLine = String(listedText[breakRange.lowerBound..<sdtRange.lowerBound])
        let sdtLine = String(listedText[sdtRange.lowerBound..<p2Range.lowerBound])
        let p2Line = String(listedText[p2Range.lowerBound...])
        XCTAssertTrue(p1Line.contains("P1"), "readback index 1 should still be P1 (untouched): \(p1Line)")
        XCTAssertTrue(breakLine.contains("\u{000C}"), "readback index 2 should be the newly-inserted column-break paragraph, immediately after P1: \(breakLine)")
        XCTAssertTrue(sdtLine.contains("sdt-inner"), "readback index 3 should be the SDT-inner paragraph, untouched: \(sdtLine)")
        XCTAssertTrue(p2Line.contains("P2"), "readback index 4 should still be P2: \(p2Line)")
    }

    /// `paragraph_index: 3` is within the readback count (4, `P2`) but at/
    /// past the top-level count (3, only P0/P1/P2 exist as top-level
    /// paragraphs) — top-level ordinal 3 does not exist. Pre-fix this
    /// silently succeeded (readback-based bounds check accepted it) and
    /// inserted at some `body.children` position that did not correspond to
    /// any paragraph the caller could have meant. Post-fix must reject.
    func testColumnBreakRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        let docId = "i251b"

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_column_break",
            arguments: ["doc_id": .string(docId), "paragraph_index": .int(3)]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist (only 0-2); must be a structured error. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("paragraph_index"), textOf(r))
    }
}
