import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Integration tests for v3.3.0 Phase 2A theme tools (closes #28).
///
/// Each test:
/// 1. Builds a fixture .docx programmatically (scratch mode)
/// 2. Re-zips it with an injected theme1.xml + Content_Types Override
/// 3. Opens the fixture via the MCP `open_document` tool
/// 4. Exercises the theme tools and asserts spec scenarios
/// 5. Closes the document
final class ThemeToolsTests: XCTestCase {

    private static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="ThesisTest">
      <a:themeElements>
        <a:clrScheme name="Office">
          <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
          <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
          <a:dk2><a:srgbClr val="44546A"/></a:dk2>
          <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
          <a:accent1><a:srgbClr val="5B9BD5"/></a:accent1>
          <a:accent2><a:srgbClr val="ED7D31"/></a:accent2>
          <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>
          <a:accent4><a:srgbClr val="FFC000"/></a:accent4>
          <a:accent5><a:srgbClr val="4472C4"/></a:accent5>
          <a:accent6><a:srgbClr val="70AD47"/></a:accent6>
          <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
          <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Office">
          <a:majorFont>
            <a:latin typeface="Calibri Light"/>
            <a:ea typeface=""/>
            <a:cs typeface=""/>
          </a:majorFont>
          <a:minorFont>
            <a:latin typeface="Calibri"/>
            <a:ea typeface="DFKai-SB"/>
            <a:cs typeface=""/>
          </a:minorFont>
        </a:fontScheme>
      </a:themeElements>
    </a:theme>
    """

    private func makeFixtureWithTheme() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Theme test body"))
        let baseFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: baseFixture)
        defer { try? FileManager.default.removeItem(at: baseFixture) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: baseFixture, to: staging)

        // Inject theme1.xml
        let themeDir = staging.appendingPathComponent("word/theme")
        try FileManager.default.createDirectory(at: themeDir, withIntermediateDirectories: true)
        try Self.themeXML.write(
            to: themeDir.appendingPathComponent("theme1.xml"),
            atomically: true,
            encoding: .utf8
        )
        // Add Content_Types Override
        let ctURL = staging.appendingPathComponent("[Content_Types].xml")
        var ctContent = try String(contentsOf: ctURL, encoding: .utf8)
        ctContent = ctContent.replacingOccurrences(
            of: "</Types>",
            with: #"<Override PartName="/word/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/></Types>"#
        )
        try ctContent.write(to: ctURL, atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("theme-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    // MARK: - get_theme

    func testGetThemeReturnsDfkaiSbMinorEastAsianFont() async throws {
        let fixture = try makeFixtureWithTheme()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_theme",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"ea\":\"DFKai-SB\""), "expected minor.ea = DFKai-SB; got: \(text)")
        XCTAssertTrue(text.contains("\"latin\":\"Calibri\""))
        XCTAssertTrue(text.contains("\"accent1\":\"5B9BD5\""))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testGetThemeOnDocWithoutThemeReturnsError() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("nodoc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_theme",
            arguments: ["doc_id": .string("nodoc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("no theme part") || text.contains("Error"),
                      "expected error message; got: \(text)")
    }

    // MARK: - update_theme_fonts

    func testUpdateThemeFontsPartialUpdateOnlyMinorEa() async throws {
        let fixture = try makeFixtureWithTheme()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "update_theme_fonts",
            arguments: [
                "doc_id": .string("doc"),
                "minor": .object(["ea": .string("華康中楷體")])
            ]
        )
        let result = await server.invokeToolForTesting(
            name: "get_theme",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"ea\":\"華康中楷體\""), "expected minor.ea changed; got: \(text)")
        XCTAssertTrue(text.contains("\"latin\":\"Calibri\""), "minor.latin must NOT change")
        XCTAssertTrue(text.contains("\"accent1\":\"5B9BD5\""), "colors must NOT change")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - update_theme_color

    func testUpdateThemeColorAccent1() async throws {
        let fixture = try makeFixtureWithTheme()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "update_theme_color",
            arguments: [
                "doc_id": .string("doc"),
                "slot": .string("accent1"),
                "hex": .string("FF0000")
            ]
        )
        let result = await server.invokeToolForTesting(
            name: "get_theme",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"accent1\":\"FF0000\""), "expected accent1 = FF0000; got: \(text)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testUpdateThemeColorRejectsInvalidSlot() async throws {
        let fixture = try makeFixtureWithTheme()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "update_theme_color",
            arguments: [
                "doc_id": .string("doc"),
                "slot": .string("badname"),
                "hex": .string("FF0000")
            ]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("Error"))
        XCTAssertTrue(text.contains("accent1") || text.contains("Allowed"))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - set_theme

    func testSetThemeRejectsMalformedXML() async throws {
        let fixture = try makeFixtureWithTheme()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "set_theme",
            arguments: [
                "doc_id": .string("doc"),
                "full_xml": .string("<a:theme><unclosed>")
            ]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("Error"))
        XCTAssertTrue(text.contains("XML"))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }
}
