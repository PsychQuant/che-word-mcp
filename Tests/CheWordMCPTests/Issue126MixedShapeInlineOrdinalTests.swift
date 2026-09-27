import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#126 — the existing `insert_equation` runtime tests
/// (`Issue98InsertEquationLibBypassTests`) only ever use a five-paragraph
/// fixture with no `.table` / block-level SDT body children, so inline
/// mode's "top-level `.paragraph` ordinal, skipping non-paragraph body
/// children" contract (closed by #105) was only ever pinned by source-string
/// grep tests (`testParagraphIndexSchemaDocumentsDisplayAndInlineOrdinals`,
/// `testHandlerDocumentsDisplayAppendFallback`,
/// `testServerNoLongerThrowsOrCatchesDeadInlineModeRequiresParagraphIndex`),
/// never by an actual document with a table in the middle. A regression that
/// re-widened inline mode's paragraph counter to `body.children.count`
/// (undoing #105) would pass all three of those source-grep tests untouched.
///
/// This file adds a mixed-shape fixture — `[paragraph, table, paragraph,
/// block-level SDT, paragraph]` — modeled on the same shape
/// `Issue97ParagraphIndexConventionTests.conventionFixture()` already uses
/// for the non-equation insert tools, and two runtime tests that actually
/// open/insert/save/read-back a document with that shape.
final class Issue126MixedShapeInlineOrdinalTests: XCTestCase {

    /// `body.children` = [paragraph("P0"), table, paragraph("P1"),
    /// contentControl(SDT wrapping paragraph("sdt-inner")), paragraph("P2")].
    /// `body.children.count` = 5. Top-level `.paragraph` ordinals (what
    /// inline mode counts): P0=0, P1=1, P2=2 — the table and the SDT are
    /// skipped, matching `Document.swift:3990-3997`'s counting rule that the
    /// inline-mode handler mirrors.
    private func mixedShapeFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P1")])))
        let sdt = StructuredDocumentTag(
            id: 12601,
            tag: "issue126_wrapper",
            alias: "Issue 126 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P2")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue126_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func isTable(_ child: BodyChild) -> Bool {
        if case .table = child { return true }
        return false
    }

    // MARK: - Inline mode: paragraph_index=1 must land on P1 (top-level
    // paragraph ordinal 1), skipping the table at body.children[1].

    func testInlineModeParagraphIndexUsesTopLevelParagraphOrdinal() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e126a")]
        )

        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e126a"),
                "latex": .string("x"),
                "display_mode": .bool(false),
                "paragraph_index": .int(1)
            ]
        )
        XCTAssertTrue(textOf(r).contains("Inserted equation"), "expected success; got: \(textOf(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("e126a"), "path": .string(savePath)]
        )

        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertEqual(saved.body.children.count, 5, "inline mode must not add a body child")
        XCTAssertTrue(isTable(saved.body.children[1]), "table at body.children[1] must be untouched by inline mode")

        guard case .paragraph(let p1) = saved.body.children[2] else {
            XCTFail("body.children[2] should still be the 'P1' paragraph")
            return
        }
        XCTAssertTrue(p1.runs.contains(where: { $0.text == "P1" }), "P1's original text run must survive")
        let hasOMML = p1.runs.contains { run in
            (run.rawXML?.contains("<m:oMath") ?? false) || (run.properties.rawXML?.contains("<m:oMath") ?? false)
        } || p1.unrecognizedChildren.contains { $0.name == "oMath" || $0.name == "oMathPara" || $0.rawXML.contains("<m:oMath") }
        XCTAssertTrue(hasOMML, "top-level paragraph ordinal 1 (P1) must receive the appended OMML run, not the table")

        // The table's own cell paragraph must not have picked up the equation.
        guard case .table(let table) = saved.body.children[1] else {
            XCTFail("body.children[1] should still be the table")
            return
        }
        let cellPara = table.rows[0].cells[0].paragraphs[0]
        let cellHasOMML = cellPara.runs.contains { $0.rawXML?.contains("<m:oMath") ?? false }
        XCTAssertFalse(cellHasOMML, "table cell paragraph must NOT receive the equation — inline mode counts top-level paragraphs only")
    }

    // MARK: - Display mode: paragraph_index=1 must insert a NEW paragraph
    // before the table at body.children[1] — NOT touch P1.

    func testDisplayModeParagraphIndexUsesBodyChildrenIndex() async throws {
        let url = try mixedShapeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e126b")]
        )

        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e126b"),
                "latex": .string("x"),
                "display_mode": .bool(true),
                "paragraph_index": .int(1)
            ]
        )
        XCTAssertTrue(textOf(r).contains("Inserted equation"), "expected success; got: \(textOf(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("e126b"), "path": .string(savePath)]
        )

        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertEqual(saved.body.children.count, 6, "display mode inserts a NEW body child (5 → 6)")

        // The new equation paragraph lands at body.children[1] — pushing the
        // table (and everything after it) one slot later.
        guard case .paragraph(let newPara) = saved.body.children[1] else {
            XCTFail("body.children[1] should be the newly-inserted equation paragraph")
            return
        }
        let newParaHasOMML = newPara.runs.contains { $0.rawXML?.contains("<m:oMath") ?? false }
            || newPara.unrecognizedChildren.contains { $0.name == "oMath" || $0.name == "oMathPara" }
        XCTAssertTrue(newParaHasOMML, "body.children[1] must carry the new equation")

        XCTAssertTrue(isTable(saved.body.children[2]), "table must have shifted from body.children[1] to body.children[2]")

        guard case .paragraph(let p1) = saved.body.children[3] else {
            XCTFail("body.children[3] should be the original 'P1' paragraph, shifted by one")
            return
        }
        XCTAssertEqual(p1.getText(), "P1", "P1 must be unmodified plain text — display mode must not touch it")
        let p1HasOMML = p1.runs.contains { $0.rawXML?.contains("<m:oMath") ?? false }
        XCTAssertFalse(p1HasOMML, "P1 must NOT receive the equation in display mode — a new sibling paragraph does")
    }
}
