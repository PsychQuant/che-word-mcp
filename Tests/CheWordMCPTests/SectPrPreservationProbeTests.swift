import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Probe: does a plain body edit (insert_paragraph) on a source-loaded doc
/// preserve sectPr (footerReference, margins)? Establishes whether sectPr
/// loss is specific to the watermark path or a general property of typed
/// document.xml re-emission.
final class SectPrPreservationProbeTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    func testInsertParagraphPreservesFooterReference() async throws {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        _ = doc.addFooter(text: "Footer content", type: .default)
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("doc"), "text": .string("Inserted para")]
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-out-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.unzipItem(at: dest, to: dir)
        let documentXML = try String(
            contentsOf: dir.appendingPathComponent("word/document.xml"), encoding: .utf8)
        XCTAssertTrue(documentXML.contains("<w:footerReference"),
                      "footerReference must survive a body edit")
    }
}
