import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Regression tests for insert_watermark / remove_watermark actually writing
/// the watermark (pre-v3.5.1 both were stubs that returned success strings
/// without touching the document).
///
/// The headerless case is the reported repro: an engine-built docx with a
/// footer1.xml but no header*.xml part. insert_watermark must create the
/// header part AND wire sectPr <w:headerReference>, [Content_Types].xml,
/// and word/_rels/document.xml.rels — not report success while writing
/// nothing.
final class WatermarkInsertRegressionTests: XCTestCase {

    /// Build a docx with a default footer but NO header part — the shape of
    /// the reported repro document (python-docx engine output with only a
    /// footer wired in sectPr). A numbering relationship is spliced in at a
    /// non-typed-convention rId to detect lossy rels rebuilds: the typed
    /// writer's scratch convention hardcodes rId1-3 and drops source
    /// relationships it doesn't track.
    private func makeHeaderlessFixtureWithFooter() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        _ = doc.addFooter(text: "Footer content", type: .default)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headerless-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headerless-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: base, to: staging)

        // Splice a numbering part + relationship at a high rId (like real
        // engine-built documents whose rels don't follow the typed rId1-3
        // convention).
        let numberingXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>
        """
        try numberingXML.write(
            to: staging.appendingPathComponent("word/numbering.xml"),
            atomically: true, encoding: .utf8)
        let relsURL = staging.appendingPathComponent("word/_rels/document.xml.rels")
        var rels = try String(contentsOf: relsURL, encoding: .utf8)
        rels = rels.replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rId9\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/></Relationships>")
        try rels.write(to: relsURL, atomically: true, encoding: .utf8)
        let ctURL = staging.appendingPathComponent("[Content_Types].xml")
        var ct = try String(contentsOf: ctURL, encoding: .utf8)
        ct = ct.replacingOccurrences(
            of: "</Types>",
            with: "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>")
        try ct.write(to: ctURL, atomically: true, encoding: .utf8)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headerless-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    private func makeFixtureWithHeader() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text"))
        _ = doc.addHeader(text: "Existing header text", type: .default)
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headered-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: fixture)
        return fixture
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func unzip(_ docx: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-unzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: docx, to: dir)
        return dir
    }

    private func part(_ dir: URL, _ path: String) throws -> String {
        return try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    /// The reported bug: headerless doc → insert_watermark returned success
    /// but the saved archive had no header part and no "DRAFT" anywhere.
    func testInsertWatermarkCreatesHeaderPartWhenNoneExists() async throws {
        let fixture = try makeHeaderlessFixtureWithFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }

        // Fixture sanity: no header part in the source archive.
        let srcDir = try unzip(fixture)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcHeaders = try FileManager.default
            .contentsOfDirectory(atPath: srcDir.appendingPathComponent("word").path)
            .filter { $0.hasPrefix("header") }
        XCTAssertTrue(srcHeaders.isEmpty, "fixture must have no header part; found \(srcHeaders)")

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let insertResult = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("doc"), "text": .string("DRAFT")]
        )
        let insertText = resultText(insertResult)
        XCTAssertTrue(insertText.contains("Watermark inserted"),
                      "insert_watermark should succeed; got: \(insertText)")

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headerless-out-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )

        let outDir = try unzip(dest)
        defer { try? FileManager.default.removeItem(at: outDir) }

        // 1. Header part exists and carries the VML watermark with our text.
        let headerFiles = try FileManager.default
            .contentsOfDirectory(atPath: outDir.appendingPathComponent("word").path)
            .filter { $0.hasPrefix("header") && $0.hasSuffix(".xml") }
        XCTAssertEqual(headerFiles.count, 1, "expected exactly one new header part; found \(headerFiles)")
        let headerXML = try part(outDir, "word/\(headerFiles[0])")
        XCTAssertTrue(headerXML.contains("PowerPlusWaterMarkObject"),
                      "header must contain the VML watermark shape")
        XCTAssertTrue(headerXML.contains("string=\"DRAFT\""),
                      "watermark textpath must carry the requested text")

        // 2. sectPr wires the header (and still wires the pre-existing footer).
        let documentXML = try part(outDir, "word/document.xml")
        XCTAssertTrue(documentXML.contains("<w:headerReference"),
                      "sectPr must gain a headerReference")
        XCTAssertTrue(documentXML.contains("<w:footerReference"),
                      "pre-existing footerReference must survive")

        // 3. Content types + rels wired.
        let contentTypes = try part(outDir, "[Content_Types].xml")
        XCTAssertTrue(contentTypes.contains("header+xml"),
                      "[Content_Types].xml must declare the header part")
        let rels = try part(outDir, "word/_rels/document.xml.rels")
        XCTAssertTrue(rels.contains(headerFiles[0]),
                      "document rels must target the new header part")

        // 4. Source relationships the typed model doesn't track must survive
        // (a typed rels rebuild drops/remaps them — styles, numbering, …).
        let srcRels = try part(srcDir, "word/_rels/document.xml.rels")
        if let regex = try? NSRegularExpression(pattern: #"<Relationship [^>]*>"#) {
            let ns = srcRels as NSString
            for m in regex.matches(in: srcRels, range: NSRange(location: 0, length: ns.length)) {
                let entry = ns.substring(with: m.range)
                XCTAssertTrue(rels.contains(entry),
                              "source relationship must survive verbatim: \(entry)")
            }
        }
        XCTAssertTrue(rels.contains("Target=\"numbering.xml\""),
                      "numbering relationship must survive the watermark insert")
    }

    /// Existing default header: watermark appends without destroying content.
    func testInsertWatermarkAppendsToExistingHeader() async throws {
        let fixture = try makeFixtureWithHeader()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("doc"), "text": .string("CONFIDENTIAL")]
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-headered-out-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )

        let outDir = try unzip(dest)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let headerXML = try part(outDir, "word/header1.xml")
        XCTAssertTrue(headerXML.contains("Existing header text"),
                      "existing header content must survive")
        XCTAssertTrue(headerXML.contains("string=\"CONFIDENTIAL\""),
                      "watermark must be appended to the existing header")
    }

    /// A second insert must refuse, not stack duplicate shapes.
    func testSecondInsertWatermarkReturnsError() async throws {
        let fixture = try makeHeaderlessFixtureWithFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("doc"), "text": .string("DRAFT")]
        )
        let second = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("doc"), "text": .string("DRAFT")]
        )
        let text = resultText(second)
        XCTAssertTrue(text.contains("already has a watermark"),
                      "second insert must refuse; got: \(text)")
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    /// remove_watermark round-trip: insert → remove → save has no shape;
    /// remove on a clean doc errors instead of claiming success.
    func testRemoveWatermarkActuallyRemoves() async throws {
        let fixture = try makeHeaderlessFixtureWithFooter()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )

        // Pre-v3.5.1 this returned "Watermark removed" on a clean document.
        let removeClean = await server.invokeToolForTesting(
            name: "remove_watermark",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(removeClean).contains("no watermark found"),
                      "remove on clean doc must error; got: \(resultText(removeClean))")

        _ = await server.invokeToolForTesting(
            name: "insert_watermark",
            arguments: ["doc_id": .string("doc"), "text": .string("DRAFT")]
        )
        let remove = await server.invokeToolForTesting(
            name: "remove_watermark",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(remove).contains("Watermark removed"),
                      "remove after insert must succeed; got: \(resultText(remove))")

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-removed-out-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )

        let outDir = try unzip(dest)
        defer { try? FileManager.default.removeItem(at: outDir) }
        let headerFiles = try FileManager.default
            .contentsOfDirectory(atPath: outDir.appendingPathComponent("word").path)
            .filter { $0.hasPrefix("header") && $0.hasSuffix(".xml") }
        for file in headerFiles {
            let xml = try part(outDir, "word/\(file)")
            XCTAssertFalse(xml.contains("PowerPlusWaterMarkObject"),
                           "saved \(file) must not contain a watermark shape")
        }
    }
}
