import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Integration tests for v3.3.0 Phase 2A header/footer/watermark tools (closes #26 #27).
final class HeadersFootersToolsTests: XCTestCase {

    private static let watermarkHeaderXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
           xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
      <w:p>
        <w:r>
          <w:pict>
            <v:shape id="PowerPlusWaterMarkObject1" o:spt="136" type="#_x0000_t136" style="position:absolute">
              <v:textpath string="機密"/>
            </v:shape>
          </w:pict>
        </w:r>
      </w:p>
    </w:hdr>
    """

    private static let pageNumberFooterXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:p>
        <w:r><w:fldSimple w:instr=" PAGE \\* MERGEFORMAT "><w:t>1</w:t></w:fldSimple></w:r>
      </w:p>
    </w:ftr>
    """

    private func makeFixtureWithHeaderAndFooter() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        doc.headers = [Header.withText("Header content", id: "rId10", type: .default)]
        doc.footers = [Footer.withText("Footer content", id: "rId11", type: .default)]
        let baseFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: baseFixture)
        defer { try? FileManager.default.removeItem(at: baseFixture) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: baseFixture, to: staging)

        // Replace header1.xml with watermark variant
        try Self.watermarkHeaderXML.write(
            to: staging.appendingPathComponent("word/header1.xml"),
            atomically: true,
            encoding: .utf8
        )
        // Replace footer1.xml with page-number variant
        try Self.pageNumberFooterXML.write(
            to: staging.appendingPathComponent("word/footer1.xml"),
            atomically: true,
            encoding: .utf8
        )

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    // MARK: - Headers

    func testListHeadersDetectsWatermark() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_headers",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"header_id\":\"rId10\""), "expected header rId10; got: \(text)")
        XCTAssertTrue(text.contains("\"has_watermark\":true"), "expected has_watermark=true; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testGetHeaderReturnsXMLAndWatermark() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_header",
            arguments: ["doc_id": .string("doc"), "header_id": .string("rId10")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("<w:hdr"), "result should embed <w:hdr> XML")
        XCTAssertTrue(text.contains("\"type\":\"text\""), "watermark type=text expected")
        XCTAssertTrue(text.contains("機密"), "watermark text 機密 expected")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testDeleteHeaderRemovesFromTypedModel() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "delete_header",
            arguments: ["doc_id": .string("doc"), "header_id": .string("rId10")]
        )
        let listResult = await server.invokeToolForTesting(
            name: "list_headers",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(listResult)
        XCTAssertFalse(text.contains("\"header_id\":\"rId10\""), "deleted header must not be listed; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testListWatermarksReturnsTextWatermark() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_watermarks",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"type\":\"text\""))
        XCTAssertTrue(text.contains("機密"))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - Footers

    func testListFootersDetectsPageNumber() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_footers",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"footer_id\":\"rId11\""))
        XCTAssertTrue(text.contains("\"has_page_number\":true"), "expected page number detected; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testGetFooterIdentifiesPageField() async throws {
        let fixture = try makeFixtureWithHeaderAndFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_footer",
            arguments: ["doc_id": .string("doc"), "footer_id": .string("rId11")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"type\":\"PAGE\""), "expected PAGE field type; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - v3.5.0 multi-instance + three-segment PAGE field scenarios

    /// Build a fixture with 3 default headers (header1.xml..header3.xml), one
    /// of which has a watermark, plus 1 footer using the verbose three-segment
    /// `<w:fldChar>` + `<w:instrText>PAGE</w:instrText>` + `<w:fldChar>` pattern
    /// (per #33 — pre-v3.5.0 `footerHasPageNumber` only matched `<w:fldSimple>`).
    private func makeMultiHeaderFixtureWithThreeSegmentFooter() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-multi-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }

        // Three headers — header2 has watermark, headers 1+3 are plain
        let header1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:p><w:r><w:t>Header 1 plain</w:t></w:r></w:p>
        </w:hdr>
        """
        let header2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
               xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
          <w:p><w:r><w:pict>
            <v:shape id="PowerPlusWaterMarkObject2" o:spt="136" type="#_x0000_t136">
              <v:textpath string="多重浮水印"/>
            </v:shape>
          </w:pict></w:r></w:p>
        </w:hdr>
        """
        let header3 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:p><w:r><w:t>Header 3 plain</w:t></w:r></w:p>
        </w:hdr>
        """
        // Footer with verbose three-segment fldChar PAGE field
        let footer3 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:p>
            <w:r><w:t xml:space="preserve">Page </w:t></w:r>
            <w:r><w:fldChar w:fldCharType="begin"/></w:r>
            <w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r>
            <w:r><w:fldChar w:fldCharType="separate"/></w:r>
            <w:r><w:t>1</w:t></w:r>
            <w:r><w:fldChar w:fldCharType="end"/></w:r>
          </w:p>
        </w:ftr>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:body>
            <w:p><w:r><w:t>Body section 1</w:t></w:r></w:p>
            <w:p><w:pPr><w:sectPr>
              <w:headerReference w:type="default" r:id="rId10"/>
              <w:footerReference w:type="default" r:id="rId20"/>
              <w:pgSz w:w="12240" w:h="15840"/>
            </w:sectPr></w:pPr></w:p>
          </w:body>
        </w:document>
        """
        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          <Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
          <Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header2.xml"/>
          <Relationship Id="rId12" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header3.xml"/>
          <Relationship Id="rId20" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer3.xml"/>
        </Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
          <Override PartName="/word/header2.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
          <Override PartName="/word/header3.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
          <Override PartName="/word/footer3.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        </Types>
        """
        let pkgRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
        </w:styles>
        """

        let writes: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", pkgRels),
            ("word/_rels/document.xml.rels", documentRels),
            ("word/document.xml", documentXML),
            ("word/styles.xml", stylesXML),
            ("word/header1.xml", header1),
            ("word/header2.xml", header2),
            ("word/header3.xml", header3),
            ("word/footer3.xml", footer3),
        ]
        for (relPath, content) in writes {
            let fileURL = staging.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-multi-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    func testListHeadersReturnsThreeDistinctEntriesAfterV0_13_0FileNamePreservation() async throws {
        let fixture = try makeMultiHeaderFixtureWithThreeSegmentFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_headers", arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        // v0.13.0 originalFileName preservation means all 3 default headers
        // appear as distinct entries — pre-v0.13.0 they'd collapse to a single
        // "header1.xml" lookup so list_headers would return 3 entries that
        // all referenced the same content.
        XCTAssertTrue(text.contains("\"header_id\":\"rId10\""))
        XCTAssertTrue(text.contains("\"header_id\":\"rId11\""))
        XCTAssertTrue(text.contains("\"header_id\":\"rId12\""))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testListWatermarksDetectsOnlyOneOfThreeHeaders() async throws {
        let fixture = try makeMultiHeaderFixtureWithThreeSegmentFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_watermarks", arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        // v0.13.0 + v3.5.0: list_watermarks reads each header's distinct
        // fileName, so only header2 (the one with PowerPlusWaterMarkObject2)
        // matches. Pre-v0.13.0 all 3 looked up header1.xml so 0 watermarks
        // would be reported (or all 3 falsely).
        XCTAssertTrue(text.contains("rId11"), "watermark on header2 (rId11) must be detected")
        XCTAssertTrue(text.contains("多重浮水印"), "watermark text must round-trip")
        XCTAssertFalse(text.contains("rId10"), "header1 has no watermark, must not appear")
        XCTAssertFalse(text.contains("rId12"), "header3 has no watermark, must not appear")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testListFootersDetectsThreeSegmentPageField() async throws {
        let fixture = try makeMultiHeaderFixtureWithThreeSegmentFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_footers", arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        // v3.5.0 (#33): three-segment fldChar form must trigger has_page_number=true.
        // Pre-v3.5.0 only <w:fldSimple w:instr="PAGE"> matched, leaving real-world
        // footers (which use the verbose form when caching results) marked false.
        XCTAssertTrue(text.contains("\"has_page_number\":true"),
                      "verbose three-segment <w:fldChar>+<w:instrText>PAGE</w:instrText>+<w:fldChar> must be detected; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testEditingHeader2PreservesHeader1And3ByteEqual() async throws {
        let srcFixture = try makeMultiHeaderFixtureWithThreeSegmentFooter()
        defer { try? FileManager.default.removeItem(at: srcFixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(srcFixture.path), "doc_id": .string("doc")]
        )
        // Edit header2 (rId11)
        _ = await server.invokeToolForTesting(
            name: "update_header",
            arguments: ["doc_id": .string("doc"), "header_id": .string("rId11"), "text": .string("Header 2 EDITED")]
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-multi-edited-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )

        // Verify headers 1 + 3 byte-equal between src and dest
        let srcDir = FileManager.default.temporaryDirectory.appendingPathComponent("hf-cmp-src-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory.appendingPathComponent("hf-cmp-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.unzipItem(at: srcFixture, to: srcDir)
        try FileManager.default.unzipItem(at: dest, to: destDir)

        let h1Src = try Data(contentsOf: srcDir.appendingPathComponent("word/header1.xml"))
        let h1Dst = try Data(contentsOf: destDir.appendingPathComponent("word/header1.xml"))
        XCTAssertEqual(h1Src, h1Dst, "header1.xml must be byte-equal — only header2 was edited")
        let h3Src = try Data(contentsOf: srcDir.appendingPathComponent("word/header3.xml"))
        let h3Dst = try Data(contentsOf: destDir.appendingPathComponent("word/header3.xml"))
        XCTAssertEqual(h3Src, h3Dst, "header3.xml must be byte-equal — only header2 was edited")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }
}
