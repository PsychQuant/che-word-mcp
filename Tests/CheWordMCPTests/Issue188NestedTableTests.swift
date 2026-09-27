import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #188 — a table cell that itself contains a nested `<w:tbl>` (the common
/// shape for a form's sub-checklist, e.g. "which of these vulnerable groups
/// does your study involve") was entirely unreachable through the editing
/// tools: `get_tables` never listed it (`WordDocument.getTables()`,
/// ooxml-swift, only enumerates top-level `.table` cases of `body.children`
/// — unmodified here), `update_cell` had no way to address a cell inside it,
/// and `search_text` never visited its paragraphs at all (walked only
/// `cell.paragraphs`, never `cell.nestedTables`).
///
/// che-word-mcp adds nested-table support entirely on its own side, reusing
/// the already-public `TableCell.nestedTables: [Table]` (ooxml-swift):
/// - `get_tables` recursively lists nested tables under the row that hosts
///   them, with a `path` label (`Table N, row R, col C > nested table K`).
/// - `search_text` recurses into `cell.nestedTables` and reports that same
///   path — content that was invisible before is now found with the correct
///   coordinates, at any nesting depth.
/// - `update_cell` accepts optional `nested_table_index` / `nested_row` /
///   `nested_col` to reach one level of nesting (the depth every real-world
///   reproducer seen so far uses); `table_index`/`row`/`col` still address
///   the *hosting* cell.
final class Issue188NestedTableTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue188-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - get_tables

    func testGetTablesListsNestedTableContentUnderItsHostRow() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: nestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "get_tables", arguments: [
            "source_path": .string(source.path),
        ])
        XCTAssertNotEqual(result.isError, true, text(of: result))
        let output = text(of: result)

        XCTAssertTrue(output.contains("Nested table at Table 0, row 0, col 0 > nested table 0"), output)
        XCTAssertTrue(output.contains("受刑人"), "nested table content is missing: \(output)")
        XCTAssertTrue(output.contains("孕婦"), "nested table content is missing: \(output)")
    }

    // MARK: - search_text

    /// Pre-#188, this would either find nothing (content invisible) or (per
    /// the original report, with a different document shape) report the
    /// WRONG host row. Either way, the correct answer is the host cell's own
    /// coordinates plus an explicit nested-table path.
    func testSearchTextFindsNestedTableContentWithCorrectPath() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: nestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "search_text", arguments: [
            "source_path": .string(source.path), "query": .string("受刑人"),
        ])
        XCTAssertNotEqual(result.isError, true, text(of: result))
        let output = text(of: result)
        XCTAssertTrue(output.contains("Found 1 match"), output)
        XCTAssertTrue(output.contains("Table 0, row 0, col 0 > nested table 0, row 0, col 0"), output)
    }

    /// The host cell's own (non-nested) paragraph text is still found at its
    /// own plain coordinates — nested-table support must not disturb the
    /// existing top-level search path.
    func testSearchTextStillFindsHostCellsOwnText() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: nestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(name: "search_text", arguments: [
            "source_path": .string(source.path), "query": .string("研究參與者的選取"),
        ])
        XCTAssertNotEqual(result.isError, true, text(of: result))
        let output = text(of: result)
        XCTAssertTrue(output.contains("Found 1 match"), output)
        XCTAssertTrue(output.contains("Table 0, row 0, col 0"), output)
        XCTAssertFalse(output.contains("nested table"), "host cell's own text should not carry a nested-table path: \(output)")
    }

    // MARK: - update_cell (nested_table_index)

    func testUpdateCellWritesIntoNestedTableCell() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: nestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "nested_table_index": .int(0), "nested_row": .int(0), "nested_col": .int(1),
            "text": .string("是"),
        ])
        XCTAssertNotEqual(updated.isError, true, text(of: updated))

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, text(of: savedResult))

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let saved = String(decoding: data, as: UTF8.self)
        // Row 0 ("受刑人") is the target; row 1 ("孕婦") is untouched and
        // legitimately still says "□否" — so the assertion is scoped to the
        // paragraph that used to hold "受刑人"'s neighbour cell, not a blanket
        // "no '□否' anywhere" check.
        guard let receivedIdx = saved.range(of: "受刑人") else {
            XCTFail("受刑人 label is missing:\n\(saved)"); return
        }
        let afterLabel = saved[receivedIdx.upperBound...]
        guard let cellClose = afterLabel.range(of: "</w:tc>"),
              let nextCellClose = saved[cellClose.upperBound...].range(of: "</w:tc>") else {
            XCTFail("could not locate 受刑人's neighbour cell:\n\(saved)"); return
        }
        let neighbourCellXML = String(saved[cellClose.upperBound..<nextCellClose.upperBound])
        XCTAssertTrue(neighbourCellXML.contains("是"), "the nested cell write did not land: \(neighbourCellXML)")
        XCTAssertFalse(neighbourCellXML.contains("□否"), "the nested cell's old text is still there: \(neighbourCellXML)")
    }

    /// Writing into a nested cell that starts with no run at all still gets
    /// the #191 fallback-format treatment (same-row-of-the-NESTED-table
    /// priority), not silently unformatted text.
    func testUpdateCellAppliesFormatFallbackInsideNestedTable() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: nestedTableEmptyCellDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-empty-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "nested_table_index": .int(0), "nested_row": .int(0), "nested_col": .int(1),
            "text": .string("填入"),
        ])
        XCTAssertNotEqual(updated.isError, true, text(of: updated))

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, text(of: savedResult))

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let saved = String(decoding: data, as: UTF8.self)
        let run = try XCTUnwrap(runXML(containing: "填入", in: saved))
        XCTAssertTrue(run.contains(#"w:eastAsia="標楷體""#),
                      "nested-table write should inherit the nested row's font: \(run)")
    }

    /// Invalid `nested_table_index` fails clearly rather than writing to the
    /// wrong place or silently doing nothing.
    func testUpdateCellRejectsOutOfRangeNestedTableIndex() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: nestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-oob-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "nested_table_index": .int(5), "nested_row": .int(0), "nested_col": .int(0),
            "text": .string("x"),
        ])
        XCTAssertEqual(updated.isError, true, "an out-of-range nested_table_index must fail: \(text(of: updated))")
    }

    // MARK: - R2 review Finding 2: nested path also only inherits the font

    /// Same failure mode as the top-level path (`Issue191...
    /// testUpdateCellInheritsOnlyFontNotBoldColorOrUnderline`), confirmed
    /// separately here because `fallbackCellRunProperties`/
    /// `applyCellTextWrite` are shared by both the #191 top-level path and
    /// this #188 nested path — R2 review found the leak reproduced
    /// identically through both call sites.
    func testUpdateCellInsideNestedTableInheritsOnlyFontNotBoldOrColor() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: nestedTableBoldDonorDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-boldcolor-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "nested_table_index": .int(0), "nested_row": .int(0), "nested_col": .int(1),
            "text": .string("使用者填入的內容"),
        ])
        XCTAssertNotEqual(updated.isError, true, text(of: updated))

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, text(of: savedResult))

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let saved = String(decoding: data, as: UTF8.self)

        let run = try XCTUnwrap(runXML(containing: "使用者填入的內容", in: saved))
        XCTAssertTrue(run.contains(#"w:eastAsia="標楷體""#), "font was not inherited: \(run)")
        XCTAssertFalse(run.contains("<w:b/>") || run.contains("<w:b "), "bold leaked from the donor label: \(run)")
        XCTAssertFalse(run.contains("FF0000"), "color leaked from the donor label: \(run)")
    }

    // MARK: - R2 review Finding 4: writing into a cell that itself has a deeper nested table

    /// `nested_table_index`/`nested_row`/`nested_col` only supports one
    /// level. A target cell that itself contains another nested table must
    /// fail explicitly, not silently write text into its paragraph while
    /// leaving its own nested content unaddressed.
    func testUpdateCellRejectsNestedCellThatItselfHasADeeperNestedTable() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        try Self.writePackage(documentXML: doublyNestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-depth2-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "nested_table_index": .int(0), "nested_row": .int(0), "nested_col": .int(0),
            "text": .string("x"),
        ])
        XCTAssertEqual(updated.isError, true,
                       "writing into a nested cell that itself contains another nested table must fail: \(text(of: updated))")
        XCTAssertTrue(text(of: updated).contains("nested"),
                     "the error should explain the depth limitation: \(text(of: updated))")
    }

    /// Editing the outermost cell of a doubly nested table forces the whole
    /// table through typed re-serialization on save. Before ooxml-swift 3.16.2
    /// that path used oversized stack frames, and a save running on a
    /// concurrency worker thread (~512 KB of stack) overflowed at this depth:
    /// the process died with SIGBUS and every other open document's unsaved
    /// edits went with it (PsychQuant/ooxml-swift#195). An async test runs on
    /// the same kind of thread, so this reproduces the real condition.
    func testSavingDoublyNestedTableAfterEditingOutermostCellKeepsEveryLevel() async throws {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: doublyNestedTableDocumentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t188-save-depth2-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, text(of: opened))

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId),
            "table_index": .int(0), "row": .int(0), "col": .int(0),
            "text": .string("edited host"),
        ])
        XCTAssertNotEqual(updated.isError, true, text(of: updated))

        let saved = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(saved.isError, true, text(of: saved))

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(xml.components(separatedBy: "<w:tbl>").count - 1, 3,
                       "all three tables must survive the save:\n\(xml)")
        for needle in ["edited host", "level1 cell", "level2 cell"] {
            XCTAssertTrue(xml.contains(needle), "'\(needle)' is missing after save:\n\(xml)")
        }
    }

    // MARK: - Helpers

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let value, _, _)? = result.content.first else { return "" }
        return value
    }

    private func runXML(containing needle: String, in xml: String) -> String? {
        guard let hit = xml.range(of: needle) else { return nil }
        let before = xml[xml.startIndex..<hit.lowerBound]
        let starts = [before.range(of: "<w:r>", options: .backwards),
                      before.range(of: "<w:r ", options: .backwards)].compactMap { $0 }
        guard let open = starts.max(by: { $0.lowerBound < $1.lowerBound }),
              let close = xml.range(of: "</w:r>", range: hit.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[open.lowerBound..<close.upperBound])
    }

    private static func writePackage(documentXML: String, to destination: URL) throws {
        let archive = try Archive(url: destination, accessMode: .create)
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypesXML),
            ("_rels/.rels", packageRelsXML),
            ("word/_rels/document.xml.rels", documentRelsXML),
            ("word/document.xml", documentXML),
        ]
        for (path, content) in parts {
            let data = Data(content.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                 compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }
}

// MARK: - Fixture

/// Top-level 1x1 table. Its single cell holds a paragraph ("...研究參與者的
/// 選取...") AND a nested 2x2 table (a "受刑人 / 孕婦" checklist, mirroring
/// the real-world REC-P-011 shape).
private let nestedTableDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="9000" w:type="dxa"/></w:tcPr>
<w:p><w:r><w:t>8. 有關研究參與者的選取</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>受刑人</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>□否</w:t></w:r></w:p></w:tc>
</w:tr>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>孕婦</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>□否</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
</w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Same shape, but the nested table's row 0 col 1 (the cell
/// `testUpdateCellAppliesFormatFallbackInsideNestedTable` writes into) is
/// `<w:p/>` — no run — while row 0 col 0 ("受刑人") declares
/// `eastAsia="標楷體"`, so the #191 fallback has a same-row source to find.
private let nestedTableEmptyCellDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="9000" w:type="dxa"/></w:tcPr>
<w:p><w:r><w:t>8. 有關研究參與者的選取</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>受刑人</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
</w:tr>
</w:tbl>
</w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Same shape as `nestedTableDocumentXML`, but the nested table's row 0 col 0
/// ("受刑人") is bold, red, AND declares 標楷體 — the #191/#188-shared
/// fallback-format donor for `testUpdateCellInsideNestedTableInheritsOnlyFontNotBoldOrColor`.
private let nestedTableBoldDonorDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="9000" w:type="dxa"/></w:tcPr>
<w:p><w:r><w:t>8. 有關研究參與者的選取</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/><w:b/><w:color w:val="FF0000"/></w:rPr><w:t>受刑人</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
</w:tr>
</w:tbl>
</w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Outer table (table_index 0) → host cell (row 0, col 0) → nested table
/// (nested_table_index 0) → that nested table's row 0 col 0 cell ITSELF
/// contains yet another nested table (depth 2 from the outer table's
/// perspective). `update_cell` addressing `nested_table_index:0,
/// nested_row:0, nested_col:0` must refuse — that cell has unaddressed
/// content one level deeper than this tool supports.
private let doublyNestedTableDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="9000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="9000" w:type="dxa"/></w:tcPr>
<w:p><w:r><w:t>host cell</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr>
<w:p><w:r><w:t>level1 cell</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>level2 cell</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
</w:tc>
</w:tr>
</w:tbl>
</w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

private let contentTypesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"""

private let packageRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""

private let documentRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>
"""
