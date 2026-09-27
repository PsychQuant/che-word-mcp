import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #185 / #224 — editing one table cell through `update_cell` must not change
/// the formatting of anything else in the table.
///
/// Any typed edit marks `word/document.xml` dirty, and the save then
/// re-serializes the whole document from the typed model. Whatever the model
/// could not read disappeared from every table at once, not only from the
/// edited cell. The fixes live in ooxml-swift 3.14.0; these tests drive the
/// real tool path (`open_document` → `update_cell` → `save_document`) so they
/// fail again if a dependency downgrade or a save-path change reintroduces the
/// loss.
final class Issue185And224TableFidelityTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue185-224-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - #185

    /// A bare `<w:vMerge/>` is the form Word writes for a continuation cell.
    /// Editing a cell in a different row must keep it.
    func testUpdateCellKeepsBareVerticalMergeContinuationInOtherRows() async throws {
        let saved = try await editAndSave(row: 0, col: 1, text: "B2")

        XCTAssertEqual(occurrences(of: "<w:vMerge/>", in: saved), 1,
                       "the continuation cell lost its merge marker:\n\(saved)")
        XCTAssertEqual(occurrences(of: #"<w:vMerge w:val="restart"/>"#, in: saved), 1,
                       "the merge start changed:\n\(saved)")
    }

    // MARK: - #224

    /// A form field is often an empty paragraph that still carries its own
    /// alignment and exact line spacing. Filling it in must keep both.
    func testUpdateCellKeepsParagraphPropertiesOfAnEmptyTargetParagraph() async throws {
        let saved = try await editAndSave(row: 2, col: 1, text: "filled")

        let paragraph = try XCTUnwrap(paragraphXML(containing: "filled", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertTrue(paragraph.contains(#"<w:jc w:val="right"/>"#),
                      "the paragraph lost its alignment: \(paragraph)")
        XCTAssertTrue(paragraph.contains(#"w:lineRule="exact""#),
                      "the paragraph lost its exact line spacing: \(paragraph)")
    }

    /// Row alignment and a row height without `w:hRule` must come back exactly
    /// as they were, on a row the edit never touched.
    func testUpdateCellKeepsRowJustificationAndDoesNotInventHeightRule() async throws {
        let saved = try await editAndSave(row: 2, col: 1, text: "filled")

        XCTAssertTrue(saved.contains(#"<w:jc w:val="center"/>"#),
                      "row 0 lost its justification:\n\(saved)")
        XCTAssertTrue(saved.contains("<w:trHeight"), "row 0 lost its height:\n\(saved)")
        XCTAssertFalse(saved.contains("w:hRule"),
                       "a height rule the source never had was added:\n\(saved)")
    }

    // MARK: - PsychQuant/ooxml-swift#182

    /// A cell with more than one paragraph: `update_cell` replaces the text of
    /// the first paragraph and keeps the others, instead of silently dropping
    /// them. Callers that want to address a later paragraph use
    /// `update_cell_paragraph`.
    func testUpdateCellReplacesFirstParagraphAndKeepsTheOthers() async throws {
        let saved = try await editAndSave(row: 0, col: 0, text: "new first",
                                          documentXML: multiParagraphCellDocumentXML)

        XCTAssertTrue(saved.contains("new first"), saved)
        XCTAssertFalse(saved.contains("old first"), "the first paragraph's old text is still there:\n\(saved)")
        XCTAssertTrue(saved.contains("second line"), "the second paragraph was dropped:\n\(saved)")
        XCTAssertTrue(saved.contains("third line"), "the third paragraph was dropped:\n\(saved)")
    }

    /// The tool description states the multi-paragraph behaviour, so a caller
    /// expecting "replace the whole cell" is told before it happens.
    func testUpdateCellDescriptionStatesMultiParagraphBehaviour() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()
        let tool = try XCTUnwrap(tools.first { $0.name == "update_cell" })
        let description = tool.description ?? ""
        XCTAssertTrue(description.contains("第一段"), description)
        XCTAssertTrue(description.contains("update_cell_paragraph"), description)
    }

    // MARK: - Helpers

    private func editAndSave(row: Int, col: Int, text: String,
                             documentXML: String = tableDocumentXML) async throws -> String {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: documentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t185-224-\(UUID().uuidString)"
        let opened = await server.invokeToolForTesting(name: "open_document", arguments: [
            "doc_id": .string(docId), "path": .string(source.path),
        ])
        XCTAssertNotEqual(opened.isError, true, "open_document failed: \(self.text(of: opened))")

        let updated = await server.invokeToolForTesting(name: "update_cell", arguments: [
            "doc_id": .string(docId), "table_index": .int(0),
            "row": .int(row), "col": .int(col), "text": .string(text),
        ])
        XCTAssertNotEqual(updated.isError, true, "update_cell failed: \(self.text(of: updated))")

        let savedResult = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(output.path),
        ])
        XCTAssertNotEqual(savedResult.isError, true, "save_document failed: \(self.text(of: savedResult))")
        _ = await server.invokeToolForTesting(name: "close_document", arguments: [
            "doc_id": .string(docId),
        ])

        let archive = try Archive(url: output, accessMode: .read)
        let entry = try XCTUnwrap(archive["word/document.xml"])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    private func text(of result: CallTool.Result) -> String {
        guard case .text(let value, _, _)? = result.content.first else { return "" }
        return value
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The `<w:p>…</w:p>` element whose text contains `needle`: the nearest
    /// paragraph start before the needle, through the next paragraph end.
    private func paragraphXML(containing needle: String, in xml: String) -> String? {
        guard let hit = xml.range(of: needle) else { return nil }
        let before = xml[xml.startIndex..<hit.lowerBound]
        let starts = [before.range(of: "<w:p>", options: .backwards),
                      before.range(of: "<w:p ", options: .backwards)].compactMap { $0 }
        guard let open = starts.max(by: { $0.lowerBound < $1.lowerBound }),
              let close = xml.range(of: "</w:p>", range: hit.upperBound..<xml.endIndex)
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

/// Row 0: row-level `jc` and a height without `w:hRule`.
/// Rows 1–2, column 0: a vertical merge whose continuation is the bare form.
/// Row 2, column 1: an empty paragraph with its own alignment and spacing.
private let tableDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr><w:trPr><w:trHeight w:val="400"/><w:jc w:val="center"/></w:trPr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc>
</w:tr>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>M</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc>
</w:tr>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/><w:vMerge/></w:tcPr><w:p/></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:pPr><w:spacing w:line="240" w:lineRule="exact"/><w:jc w:val="right"/></w:pPr></w:p></w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Row 0, column 0: a cell with three paragraphs.
private let multiParagraphCellDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="4000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="4000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>old first</w:t></w:r></w:p><w:p><w:r><w:t>second line</w:t></w:r></w:p><w:p><w:r><w:t>third line</w:t></w:r></w:p></w:tc>
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
