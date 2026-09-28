import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #219 (reopened) — `list_images` gained header/footer coverage in 4.7.0
/// (PR #254), but the reopening comment identified two residuals that were
/// NOT shipped:
///
/// 1. `export_all_images` / `export_image` only ever read `doc.images`
///    (the document part) — a document with ONLY a header image produced
///    "No images to export" even though `list_images` correctly showed it.
/// 2. Chart-part images (`word/charts/chartN.xml`) had no test coverage at
///    all — behavior was unverified in either direction.
///
/// Both residuals need bytes that live ONLY in the package archive, not in
/// the typed model at all (`UntypedPartImages.swift`), which is why these
/// tests build a real `.docx` (via `DocxWriter` + direct ZIP surgery via
/// `ZipHelper`) rather than only unit-testing pure functions.
final class Issue219HeaderFooterChartImageExportTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue219-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first, case .text(let t, _, _) = first else { return "" }
        return t
    }

    /// Builds a `.docx` with:
    /// - one document-part image (`bodyimg.png`, via the typed `doc.images`
    ///   path — DocxWriter writes this media file itself)
    /// - one header image relationship (typed: `doc.headers[0]
    ///   .relationships`) whose media file is injected directly into the
    ///   package after the first write, because `DocxWriter` only ever
    ///   writes media for `doc.images` (confirmed by reading
    ///   `DocxWriter.swift` — every `word/media/*` write loop iterates
    ///   `document.images`)
    /// - one chart part (`word/charts/chart1.xml` + its own
    ///   `_rels/chart1.xml.rels`) with an image relationship, injected the
    ///   same way — ooxml-swift's typed model has no chart representation
    ///   at all
    ///
    /// `duplicateHeaderMediaFileName`, when non-nil, gives the chart image
    /// the SAME final basename as the header image, via a DIFFERENT
    /// physical file — real OOXML packages share one flat `word/media/`
    /// namespace, so two DISTINCT byte payloads cannot both legitimately
    /// sit at `word/media/<name>`. The collision this reproduces is instead
    /// the one an unusual/malformed chart part causes: a chart rels target
    /// with no `../` (resolved relative to `word/charts/` instead of
    /// `word/`) lands its media in `word/charts/media/`, a directory
    /// distinct from the shared `word/media/` — so a same-named FILE really
    /// can exist there with different content. That is exactly the case
    /// `writeUnique` in `exportAllImages` must not silently let collide.
    private func buildFixture(duplicateHeaderMediaFileName: String? = nil) throws -> String {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body"))
        doc.images.append(ImageReference(id: "rIdBodyImg", fileName: "bodyimg.png", contentType: "image/png", data: Data([0xAA, 0xBB, 0xCC])))

        _ = doc.addHeader(text: "Header")
        let headerMediaName = duplicateHeaderMediaFileName ?? "headerimg.png"
        doc.headers[0].relationships.relationships.append(
            Relationship(id: "rIdHeaderImg", type: .image, target: "media/\(headerMediaName)"))

        let firstPassURL = tempDir.appendingPathComponent("firstpass.docx")
        try DocxWriter.write(doc, to: firstPassURL)

        let unpacked = try ZipHelper.unzip(firstPassURL)
        defer { ZipHelper.cleanup(unpacked) }

        let wordDir = unpacked.appendingPathComponent("word")
        try Data([0x11, 0x22, 0x33, 0x44]).write(to: wordDir.appendingPathComponent("media/\(headerMediaName)"))

        let chartMediaName = duplicateHeaderMediaFileName ?? "chartimg.png"
        let chartsDir = wordDir.appendingPathComponent("charts")
        let chartRelsDir = chartsDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: chartRelsDir, withIntermediateDirectories: true)

        let chartTarget: String
        if duplicateHeaderMediaFileName != nil {
            let chartOwnMediaDir = chartsDir.appendingPathComponent("media")
            try FileManager.default.createDirectory(at: chartOwnMediaDir, withIntermediateDirectories: true)
            try Data([0x55, 0x66]).write(to: chartOwnMediaDir.appendingPathComponent(chartMediaName))
            chartTarget = "media/\(chartMediaName)" // relative to word/charts/, NOT word/
        } else {
            try Data([0x55, 0x66]).write(to: wordDir.appendingPathComponent("media/\(chartMediaName)"))
            chartTarget = "../media/\(chartMediaName)" // conventional: relative to word/
        }

        try "<c:chartSpace/>".write(to: chartsDir.appendingPathComponent("chart1.xml"), atomically: true, encoding: .utf8)
        let chartRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdChartImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(chartTarget)"/>
        </Relationships>
        """
        try chartRelsXML.write(to: chartRelsDir.appendingPathComponent("chart1.xml.rels"), atomically: true, encoding: .utf8)

        let finalData = try ZipHelper.zipToData(unpacked)
        let finalURL = tempDir.appendingPathComponent("final.docx")
        try finalData.write(to: finalURL)
        return finalURL.path
    }

    // MARK: - list_images

    func testListImagesShowsDocumentHeaderAndChartRows() async throws {
        let path = try buildFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("i219a"),
        ])
        let r = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("i219a")])
        let output = text(r)

        XCTAssertTrue(output.contains("part: word/document.xml, id: rIdBodyImg, file: bodyimg.png"), output)
        XCTAssertTrue(output.contains("part: word/header1.xml, id: rIdHeaderImg, file: headerimg.png"), output)
        XCTAssertTrue(output.contains("part: word/charts/chart1.xml, id: rIdChartImg, file: chartimg.png"), output)
        // Since the chart row is now listed properly, it must NOT also be
        // named in the "declared elsewhere" fallback line.
        XCTAssertFalse(output.contains("Declared elsewhere in the package") && output.contains("charts/chart1.xml:rIdChartImg"),
                       "chart ref must not double-report via the elsewhere-fallback once it has its own row: \(output)")
    }

    // MARK: - export_all_images

    func testExportAllImagesCoversDocumentHeaderAndChart() async throws {
        let path = try buildFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("i219b"),
        ])
        let outDir = tempDir.appendingPathComponent("out").path
        let r = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string("i219b"), "output_dir": .string(outDir),
        ])
        let output = text(r)
        XCTAssertNotEqual(r.isError, true, output)
        XCTAssertTrue(output.contains("bodyimg.png"), output)
        XCTAssertTrue(output.contains("headerimg.png"), output)
        XCTAssertTrue(output.contains("chartimg.png"), output)

        let bodyData = FileManager.default.contents(atPath: outDir + "/bodyimg.png")
        let headerData = FileManager.default.contents(atPath: outDir + "/headerimg.png")
        let chartData = FileManager.default.contents(atPath: outDir + "/chartimg.png")
        XCTAssertEqual(bodyData, Data([0xAA, 0xBB, 0xCC]))
        XCTAssertEqual(headerData, Data([0x11, 0x22, 0x33, 0x44]))
        XCTAssertEqual(chartData, Data([0x55, 0x66]))
    }

    /// #219 explicit requirement: "匯出檔名衝突（不同 part 同名圖片）要有明確處理".
    /// Header and chart both reference a media file with the SAME name —
    /// export must not silently let one overwrite the other, and must say
    /// so in the result text.
    func testExportAllImagesHandlesFilenameCollisionAcrossParts() async throws {
        let path = try buildFixture(duplicateHeaderMediaFileName: "dup.png")
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("i219c"),
        ])
        let outDir = tempDir.appendingPathComponent("outdup").path
        let r = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string("i219c"), "output_dir": .string(outDir),
        ])
        let output = text(r)
        XCTAssertNotEqual(r.isError, true, output)
        XCTAssertTrue(output.lowercased().contains("renam") || output.lowercased().contains("collision"),
                      "must explicitly call out the filename collision: \(output)")

        let listing = (try? FileManager.default.contentsOfDirectory(atPath: outDir))?.sorted() ?? []
        // bodyimg.png (document part, unrelated to the collision) + the two
        // "dup"-named files (header + chart), neither overwriting the other.
        XCTAssertEqual(listing.count, 3, "both colliding files must be written, neither silently overwritten: \(listing)")

        // Both distinct byte payloads must be present SOMEWHERE in the output
        // directory, under whatever names the collision resolution picked.
        let allData = Set(listing.compactMap { FileManager.default.contents(atPath: outDir + "/" + $0) })
        XCTAssertTrue(allData.contains(Data([0x11, 0x22, 0x33, 0x44])), "header image bytes must survive: \(listing)")
        XCTAssertTrue(allData.contains(Data([0x55, 0x66])), "chart image bytes must survive: \(listing)")
    }

    // MARK: - export_image

    func testExportImageCanExportAHeaderOnlyImage() async throws {
        let path = try buildFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("i219d"),
        ])
        let savePath = tempDir.appendingPathComponent("exported_header.png").path
        let r = await server.invokeToolForTesting(name: "export_image", arguments: [
            "doc_id": .string("i219d"), "image_id": .string("rIdHeaderImg"), "save_path": .string(savePath),
        ])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(FileManager.default.contents(atPath: savePath), Data([0x11, 0x22, 0x33, 0x44]))
    }

    func testExportImageCanExportAChartOnlyImage() async throws {
        let path = try buildFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("i219e"),
        ])
        let savePath = tempDir.appendingPathComponent("exported_chart.png").path
        let r = await server.invokeToolForTesting(name: "export_image", arguments: [
            "doc_id": .string("i219e"), "image_id": .string("rIdChartImg"), "save_path": .string(savePath),
        ])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertEqual(FileManager.default.contents(atPath: savePath), Data([0x55, 0x66]))
    }

    func testExportAllImagesOnDocumentWithOnlyAHeaderImageDoesNotReportNoImages() async throws {
        // The 4.7.0 bug this issue reopened over: a document with ONLY a
        // header image (no document-part images at all) reported
        // "No images to export".
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body, no document-part images"))
        _ = doc.addHeader(text: "Header")
        doc.headers[0].relationships.relationships.append(
            Relationship(id: "rIdOnly", type: .image, target: "media/onlyheader.png"))

        let firstPassURL = tempDir.appendingPathComponent("headeronly.docx")
        try DocxWriter.write(doc, to: firstPassURL)
        let unpacked = try ZipHelper.unzip(firstPassURL)
        defer { ZipHelper.cleanup(unpacked) }
        try FileManager.default.createDirectory(
            at: unpacked.appendingPathComponent("word/media"), withIntermediateDirectories: true)
        try Data([0x99]).write(to: unpacked.appendingPathComponent("word/media/onlyheader.png"))
        let finalData = try ZipHelper.zipToData(unpacked)
        let finalURL = tempDir.appendingPathComponent("headeronly_final.docx")
        try finalData.write(to: finalURL)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(finalURL.path), "doc_id": .string("i219f"),
        ])
        let outDir = tempDir.appendingPathComponent("outheaderonly").path
        let r = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string("i219f"), "output_dir": .string(outDir),
        ])
        let output = text(r)
        XCTAssertNotEqual(r.isError, true, output)
        XCTAssertFalse(output.contains("No images to export"), output)
        XCTAssertEqual(FileManager.default.contents(atPath: outDir + "/onlyheader.png"), Data([0x99]))
    }
}
