import Foundation
import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #194（PsychQuant/macdoc#156）：表格 cell 內段落的定址與單段改寫。
///
/// 情境取自官方表單：同一格有四個獨立段落（□(1)／□(2)／□(3)／□無報酬），
/// 而 `□(1)` 另外出現在第 0 列與第 2 列。`replace_text` 會三列一起改，
/// `update_cell` 會把四段塌成一段；這裡驗證兩個新 tool 只動被定址的那一段。
final class Issue194CellParagraphToolsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell-paragraph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func formDocument(at url: URL) throws {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Before the table"))
        var first = Paragraph(text: "□(1)")
        first.properties.indentation = Indentation(left: 240)
        var second = Paragraph(text: "□(2)")
        second.properties.alignment = .center
        doc.appendTable(Table(rows: [
            TableRow(cells: [TableCell(text: "Label A"), TableCell(paragraphs: [Paragraph(text: "□(1)")])]),
            TableRow(cells: [TableCell(text: "Label B"), TableCell(paragraphs: [first, second, Paragraph(text: "□(3)"), Paragraph(text: "□無報酬")])]),
            TableRow(cells: [TableCell(text: "Label C"), TableCell(paragraphs: [Paragraph(text: "□(1)")])])
        ]))
        try DocxWriter.write(doc, to: url)
    }

    private func call(_ server: WordMCPServer, _ name: String, _ args: [String: Value]) async -> CallTool.Result {
        await server.invokeToolForTesting(name: name, arguments: args)
    }

    private func text(_ result: CallTool.Result) -> String {
        guard let first = result.content.first, case .text(let t, _, _) = first else { return "" }
        return t
    }

    private func cellTexts(_ url: URL, row: Int, col: Int) throws -> [String] {
        var doc = try DocxReader.read(from: url)
        defer { doc.close() }
        return doc.getTables()[0].rows[row].cells[col].paragraphs.map { $0.getText() }
    }

    func testGetCellParagraphsListsZeroBasedParagraphsInDirectAndSessionMode() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("form.docx")
        try formDocument(at: source)
        let server = await WordMCPServer()

        let direct = await call(server, "get_cell_paragraphs", [
            "source_path": .string(source.path), "table_index": .int(0), "row": .int(1), "col": .int(1),
        ])
        XCTAssertNotEqual(direct.isError, true, text(direct))
        for (index, label) in ["□(1)", "□(2)", "□(3)", "□無報酬"].enumerated() {
            XCTAssertTrue(text(direct).contains("[\(index)] \(label)"), text(direct))
        }

        let docId = "cell-read-\(UUID().uuidString)"
        _ = await call(server, "open_document", ["path": .string(source.path), "doc_id": .string(docId)])
        let session = await call(server, "get_cell_paragraphs", [
            "doc_id": .string(docId), "table_index": .int(0), "row": .int(1), "col": .int(1),
        ])
        XCTAssertEqual(text(session), text(direct))
    }

    func testUpdateCellParagraphChangesOnlyTheAddressedParagraphAndPersists() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("form.docx")
        let output = dir.appendingPathComponent("filled.docx")
        try formDocument(at: source)
        let server = await WordMCPServer()
        let docId = "cell-write-\(UUID().uuidString)"
        _ = await call(server, "open_document", ["path": .string(source.path), "doc_id": .string(docId)])

        let updated = await call(server, "update_cell_paragraph", [
            "doc_id": .string(docId), "table_index": .int(0), "row": .int(1), "col": .int(1),
            "paragraph_index": .int(0), "text": .string("V(1)"),
        ])
        XCTAssertNotEqual(updated.isError, true, text(updated))
        let saved = await call(server, "save_document", ["doc_id": .string(docId), "path": .string(output.path)])
        XCTAssertNotEqual(saved.isError, true, text(saved))

        XCTAssertEqual(try cellTexts(output, row: 1, col: 1), ["V(1)", "□(2)", "□(3)", "□無報酬"])
        XCTAssertEqual(try cellTexts(output, row: 0, col: 1), ["□(1)"], "其他列的同字串不得被改到")
        XCTAssertEqual(try cellTexts(output, row: 2, col: 1), ["□(1)"], "其他列的同字串不得被改到")

        var reopened = try DocxReader.read(from: output)
        defer { reopened.close() }
        let paragraphs = reopened.getTables()[0].rows[1].cells[1].paragraphs
        XCTAssertEqual(paragraphs[0].properties.indentation?.left, 240, "被改寫段落的 pPr 必須保留")
        XCTAssertEqual(paragraphs[1].properties.alignment, .center, "同格其他段落的 pPr 必須保留")
    }

    func testInvalidAddressesFailWithoutMutation() async throws {
        let dir = try directory(), source = dir.appendingPathComponent("form.docx")
        let output = dir.appendingPathComponent("untouched.docx")
        try formDocument(at: source)
        let server = await WordMCPServer()
        let docId = "cell-invalid-\(UUID().uuidString)"
        _ = await call(server, "open_document", ["path": .string(source.path), "doc_id": .string(docId)])

        let base: [String: Value] = ["doc_id": .string(docId), "table_index": .int(0), "row": .int(1), "col": .int(1), "text": .string("X")]
        let cases: [(String, [String: Value])] = [
            ("paragraph out of range", base.merging(["paragraph_index": .int(4)]) { $1 }),
            ("negative paragraph", base.merging(["paragraph_index": .int(-1)]) { $1 }),
            ("missing paragraph_index", base),
            ("column out of range", base.merging(["paragraph_index": .int(0), "col": .int(5)]) { $1 }),
            ("table out of range", base.merging(["paragraph_index": .int(0), "table_index": .int(3)]) { $1 }),
        ]
        for (label, args) in cases {
            let result = await call(server, "update_cell_paragraph", args)
            XCTAssertEqual(result.isError, true, "\(label): \(text(result))")
        }
        let readback = await call(server, "get_cell_paragraphs", [
            "doc_id": .string(docId), "table_index": .int(0), "row": .int(1), "col": .int(9),
        ])
        XCTAssertEqual(readback.isError, true, text(readback))

        _ = await call(server, "save_document", ["doc_id": .string(docId), "path": .string(output.path)])
        XCTAssertEqual(try cellTexts(output, row: 1, col: 1), ["□(1)", "□(2)", "□(3)", "□無報酬"])
    }
}
