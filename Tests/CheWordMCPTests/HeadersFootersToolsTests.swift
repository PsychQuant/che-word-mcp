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
}
