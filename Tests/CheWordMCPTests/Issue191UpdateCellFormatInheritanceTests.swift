import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #191 — `update_cell` writing into a cell that has **no existing run**
/// (the common shape of an unfilled form field: `<w:p/>` with nothing inside)
/// used to create a run with no `<w:rPr>` at all. That run then rendered in
/// Word's `docDefaults` font rather than the form's declared font, producing
/// a visibly inconsistent document that no cell-by-cell text comparison
/// catches (the text is correct; only the font is wrong).
///
/// Fix lives entirely in che-word-mcp (ooxml-swift's `updateCell` already
/// preserves an *existing* run's `rPr` correctly — that path is untouched).
/// When the target cell has zero runs, che-word-mcp now looks for a
/// "fallback" `RunProperties` to assign to the new run, in priority order:
///   1. another cell in the *same row* that has a non-empty run with a
///      declared font (`rFonts` axis or legacy `fontName`);
///   2. failing that, the most common declared-font `RunProperties` among
///      all non-empty runs anywhere in the document (the form's dominant
///      font).
/// If neither search finds anything, the new run stays unformatted — old
/// behaviour, not a fabricated guess.
final class Issue191UpdateCellFormatInheritanceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue191-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Tier 1: same-row fallback

    /// Row 0 col 0 already carries `rFonts eastAsia="標楷體"`. Row 0 col 1 is
    /// `<w:p/>` — no run at all. Filling col 1 must pick up col 0's font
    /// rather than leaving the new run bare.
    func testUpdateCellInheritsFormatFromSameRowWhenCellHasNoRuns() async throws {
        let saved = try await editAndSave(row: 0, col: 1, text: "填入的內容",
                                          documentXML: sameRowFallbackDocumentXML)

        let paragraph = try XCTUnwrap(paragraphXML(containing: "填入的內容", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertTrue(paragraph.contains(#"w:eastAsia="標楷體""#),
                      "new run did not inherit the same row's declared font: \(paragraph)")
    }

    /// Same fixture, but scanning col 0 (leftmost) as the fallback source
    /// when the *target* itself is col 0 and col 1 carries the font — the
    /// search must not assume the fallback sits to the left.
    func testUpdateCellInheritsFormatFromLaterColumnInSameRow() async throws {
        let saved = try await editAndSave(row: 0, col: 0, text: "另一格內容",
                                          documentXML: fallbackInLaterColumnDocumentXML)

        let paragraph = try XCTUnwrap(paragraphXML(containing: "另一格內容", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertTrue(paragraph.contains(#"w:eastAsia="標楷體""#),
                      "new run did not inherit the row's declared font from a later column: \(paragraph)")
    }

    // MARK: - Tier 2: document-dominant fallback

    /// The target row has no other formatted cell, but the rest of the
    /// document overwhelmingly declares `標楷體` (890-style dominant font in
    /// the real-world reproducer). The new run should pick that up.
    func testUpdateCellInheritsDocumentDominantFormatWhenRowHasNoFormattedCells() async throws {
        let saved = try await editAndSave(row: 1, col: 0, text: "本研究旨在探討",
                                          documentXML: documentDominantFontDocumentXML)

        let paragraph = try XCTUnwrap(paragraphXML(containing: "本研究旨在探討", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertTrue(paragraph.contains(#"w:eastAsia="標楷體""#),
                      "new run did not inherit the document's dominant declared font: \(paragraph)")
    }

    // MARK: - No fallback available: unchanged old behaviour

    /// Nothing in the document declares a font at all. The new run stays
    /// unformatted — che-word-mcp must not fabricate a font out of nothing.
    func testUpdateCellLeavesRunUnformattedWhenNoDeclaredFontExistsAnywhere() async throws {
        let saved = try await editAndSave(row: 0, col: 1, text: "純文字",
                                          documentXML: noFontAnywhereDocumentXML)

        let paragraph = try XCTUnwrap(paragraphXML(containing: "純文字", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertFalse(paragraph.contains("w:rFonts"),
                       "a font was fabricated even though none exists anywhere in the document: \(paragraph)")
    }

    // MARK: - Regression: existing-run path untouched (#191 must not affect it)

    /// A cell that already has a run with its own font keeps that font
    /// exactly — this path is ooxml-swift's `updateCell` "if" branch, and
    /// #191 only changes the "cell has zero runs" branch.
    func testUpdateCellPreservesExistingRunFormatUnchanged() async throws {
        let saved = try await editAndSave(row: 0, col: 0, text: "改過的文字",
                                          documentXML: sameRowFallbackDocumentXML)

        let paragraph = try XCTUnwrap(paragraphXML(containing: "改過的文字", in: saved),
                                      "the new text is missing:\n\(saved)")
        XCTAssertTrue(paragraph.contains(#"w:eastAsia="標楷體""#),
                      "existing run's own font was lost: \(paragraph)")
    }

    // MARK: - Helpers

    private func editAndSave(row: Int, col: Int, text: String,
                             documentXML: String) async throws -> String {
        let source = scratch.appendingPathComponent("source.docx")
        let output = scratch.appendingPathComponent("saved.docx")
        try Self.writePackage(documentXML: documentXML, to: source)

        let server = await WordMCPServer()
        let docId = "t191-\(UUID().uuidString)"
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

    /// The `<w:p>…</w:p>` element whose text contains `needle`.
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

// MARK: - Fixtures

/// Row 0 col 0: run with `eastAsia="標楷體"`. Row 0 col 1: `<w:p/>`, no run.
private let sameRowFallbackDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>標籤</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Row 0 col 0: `<w:p/>`, no run. Row 0 col 1: run with `eastAsia="標楷體"`.
/// The fallback source is to the *right* of the empty target cell.
private let fallbackInLaterColumnDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>標籤</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Row 0: a header row with no runs at all (both cells `<w:p/>`). Row 1 col 0
/// is the empty target. Everywhere else in the document — a top-level body
/// paragraph plus 3 unrelated table cells — declares `eastAsia="標楷體"`, so
/// that font dominates the document even though the target row has nothing.
private let documentDominantFontDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>本表單其餘內容皆為標楷體</w:t></w:r></w:p>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>甲</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>乙</w:t></w:r></w:p></w:tc>
</w:tr>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:eastAsia="標楷體"/></w:rPr><w:t>丙</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
<w:p/>
<w:sectPr></w:sectPr>
</w:body>
</w:document>
"""

/// Nothing anywhere declares a font — every run is bare `<w:r><w:t>…</w:t></w:r>`.
private let noFontAnywhereDocumentXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<w:body>
<w:tbl>
<w:tblPr><w:tblW w:w="0" w:type="auto"/></w:tblPr>
<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="2000"/></w:tblGrid>
<w:tr>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>plain</w:t></w:r></w:p></w:tc>
<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p/></w:tc>
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
