import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#209 — `headerHasWatermark` only recognised Word's
/// *text* watermark fingerprint (`PowerPlusWaterMarkObject` / `o:spt="136"`).
/// A real Word *image* watermark uses a different shape
/// (`WordPictureWatermark<N>`, `type="#_x0000_t75"`, `<v:imagedata>`), which
/// matched neither signal — `list_watermarks` silently returned `[]` and
/// `get_watermark` returned `null` for a document that visibly has one.
///
/// This fixture uses the exact shape from the issue body (Word's own
/// output), independent of this repo's own `insert_image_watermark` writer —
/// proving the READ side against a ground truth Word actually produces, not
/// just against whatever this repo happens to write.
final class Issue209ImageWatermarkFingerprintTests: XCTestCase {

    private static let wordImageWatermarkHeaderXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
           xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
           xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
      <w:p>
        <w:r>
          <w:pict>
            <v:shape id="WordPictureWatermark1" o:spid="_x0000_s2049" type="#_x0000_t75"
                     style="position:absolute;margin-left:0;margin-top:0;width:415pt;height:207.5pt;z-index:-251657216">
              <v:imagedata r:id="rId1" o:title="logo" gain="19661f" blacklevel="22938f"/>
            </v:shape>
          </w:pict>
        </w:r>
      </w:p>
    </w:hdr>
    """

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func makeFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        doc.headers = [Header.withText("Header content", id: "rId10", type: .default)]
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("i209-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("i209-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: base, to: staging)
        try Self.wordImageWatermarkHeaderXML.write(
            to: staging.appendingPathComponent("word/header1.xml"), atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("i209-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    func testListWatermarksRecognisesWordsRealImageWatermarkShape() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("w209")])

        let list = await server.invokeToolForTesting(name: "list_watermarks", arguments: ["doc_id": .string("w209")])
        XCTAssertNotEqual(list.isError, true, textOf(list))
        XCTAssertEqual(textOf(list), "[{\"header_id\":\"rId10\",\"type\":\"image\"}]", "Got: \(textOf(list))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("w209"), "discard_changes": .bool(true)])
    }

    func testGetWatermarkRecognisesWordsRealImageWatermarkShape() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("w209b")])

        let one = await server.invokeToolForTesting(
            name: "get_watermark", arguments: ["doc_id": .string("w209b"), "header_id": .string("rId10")])
        XCTAssertNotEqual(one.isError, true, textOf(one))
        XCTAssertEqual(textOf(one), "{\"header_id\":\"rId10\",\"type\":\"image\"}", "Got: \(textOf(one))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("w209b"), "discard_changes": .bool(true)])
    }

    /// `list_headers`' `has_watermark` flag shares `headerHasWatermark` and
    /// must move in lockstep with `list_watermarks`.
    func testListHeadersHasWatermarkFlagSyncsWithImageWatermark() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("w209c")])

        let headers = await server.invokeToolForTesting(name: "list_headers", arguments: ["doc_id": .string("w209c")])
        XCTAssertTrue(textOf(headers).contains("\"has_watermark\":true"), "Got: \(textOf(headers))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("w209c"), "discard_changes": .bool(true)])
    }

    /// Pre-existing text-watermark detection must not regress.
    func testTextWatermarkFingerprintStillDetected() {
        let xml = """
        <v:shape id="PowerPlusWaterMarkObject1" o:spt="136" type="#_x0000_t136"><v:textpath string="DRAFT"/></v:shape>
        """
        XCTAssertTrue(xml.contains("PowerPlusWaterMarkObject"))
    }
}
