import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Security fix flagged in post-commit review of #219's first version
/// (commit `f728be2`): `UntypedPartImages` resolved a relationship
/// `Target` — an attacker-controlled string read from inside a `.docx`
/// someone else authored — by simple path concatenation
/// (`baseDir.appendingPathComponent(target).standardizedFileURL`) with NO
/// check that the result stayed inside the unzipped package. A malicious
/// header/footer/chart rels entry with `Target="../../../../etc/hosts"`
/// (or an absolute filesystem path, or `TargetMode="External"`) would
/// resolve to, and then actually be READ from (`export_all_images` /
/// `export_image`) or DELETED (`remove_watermark`'s
/// `cleanupOrphanedWatermarkMedia`), a real path on the machine running
/// this server.
///
/// `UntypedPartImages.resolvePackageRelativeTarget` is the shared fix both
/// call sites now go through. This file tests it directly (deterministic,
/// no zip/docx machinery needed) and then exercises it end-to-end through
/// the actual MCP tools with a hand-crafted malicious `.docx`.
final class Issue219PathTraversalSecurityTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue219Security-\(UUID().uuidString)")
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

    // MARK: - resolvePackageRelativeTarget (the shared primitive)

    private func packageLayout() throws -> (root: URL, word: URL, charts: URL) {
        let root = tempDir.appendingPathComponent("pkg-\(UUID().uuidString)")
        let word = root.appendingPathComponent("word")
        let charts = word.appendingPathComponent("charts")
        try FileManager.default.createDirectory(at: charts, withIntermediateDirectories: true)
        return (root, word, charts)
    }

    func testRejectsDotDotEscapeFromChartsDirectory() throws {
        let (root, _, charts) = try packageLayout()
        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "../../../../../../../../etc/hosts", baseDir: charts, packageRoot: root)
        XCTAssertNil(resolved, "excessive .. must not escape the package root")
    }

    func testAcceptsTheConventionalChartRelativeTarget() throws {
        let (root, word, charts) = try packageLayout()
        try FileManager.default.createDirectory(at: word.appendingPathComponent("media"), withIntermediateDirectories: true)
        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "../media/image1.png", baseDir: charts, packageRoot: root)
        XCTAssertEqual(resolved?.path, word.appendingPathComponent("media/image1.png").path)
    }

    func testAbsoluteTargetIsPackageRootRelativeNotFilesystemRootRelative() throws {
        // ECMA-376 Part 2 §9.2: a Target beginning with "/" is relative to
        // the OPC package root, never the filesystem root.
        let (root, word, _) = try packageLayout()
        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "/word/media/logo.png", baseDir: word, packageRoot: root)
        XCTAssertEqual(resolved?.path, word.appendingPathComponent("media/logo.png").path)
    }

    func testAbsoluteTargetCannotCombineWithDotDotToEscape() throws {
        // A hostile Target could try BOTH tricks at once: claim to be
        // package-root-relative (leading "/") while also walking out via
        // "..". The containment check must still catch it.
        let (root, word, _) = try packageLayout()
        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "/../../../../../../etc/hosts", baseDir: word, packageRoot: root)
        XCTAssertNil(resolved)
    }

    func testEmptyTargetIsRejected() throws {
        let (root, word, _) = try packageLayout()
        XCTAssertNil(UntypedPartImages.resolvePackageRelativeTarget("", baseDir: word, packageRoot: root))
    }

    func testSymlinkInsideThePackagePointingOutsideIsRejected() throws {
        let (root, word, _) = try packageLayout()
        try FileManager.default.createDirectory(at: word.appendingPathComponent("media"), withIntermediateDirectories: true)
        let outsideTarget = tempDir.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outsideTarget)
        let symlinkPath = word.appendingPathComponent("media/escape.png")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideTarget)

        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "media/escape.png", baseDir: word, packageRoot: root)
        XCTAssertNil(resolved, "a Target landing on an in-archive symlink that points outside the package must be refused")
    }

    func testSymlinkInsideThePackagePointingInsideIsAccepted() throws {
        // Negative control for the previous test: a symlink is not
        // rejected merely for BEING a symlink — only for resolving outside.
        let (root, word, _) = try packageLayout()
        let mediaDir = word.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let realFile = mediaDir.appendingPathComponent("real.png")
        try Data([0x01]).write(to: realFile)
        let symlinkPath = mediaDir.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: realFile)

        let resolved = UntypedPartImages.resolvePackageRelativeTarget(
            "media/alias.png", baseDir: word, packageRoot: root)
        XCTAssertNotNil(resolved)
    }

    // MARK: - End-to-end: list_images / export_all_images / export_image refuse a malicious chart Target

    private func buildFixtureWithMaliciousChartTarget(canaryPath: String) throws -> String {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body"))
        let firstPassURL = tempDir.appendingPathComponent("firstpass.docx")
        try DocxWriter.write(doc, to: firstPassURL)

        let unpacked = try ZipHelper.unzip(firstPassURL)
        defer { ZipHelper.cleanup(unpacked) }

        let wordDir = unpacked.appendingPathComponent("word")
        let chartsDir = wordDir.appendingPathComponent("charts")
        let chartRelsDir = chartsDir.appendingPathComponent("_rels")
        try FileManager.default.createDirectory(at: chartRelsDir, withIntermediateDirectories: true)
        try "<c:chartSpace/>".write(to: chartsDir.appendingPathComponent("chart1.xml"), atomically: true, encoding: .utf8)
        let chartRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdEvil" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(canaryPath)"/>
        </Relationships>
        """
        try chartRelsXML.write(to: chartRelsDir.appendingPathComponent("chart1.xml.rels"), atomically: true, encoding: .utf8)

        let finalData = try ZipHelper.zipToData(unpacked)
        let finalURL = tempDir.appendingPathComponent("final.docx")
        try finalData.write(to: finalURL)
        return finalURL.path
    }

    func testListImagesRefusesAMaliciousChartTargetAndSaysSo() async throws {
        let path = try buildFixtureWithMaliciousChartTarget(canaryPath: "../../../../../../../../etc/hosts")
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("sec-a"),
        ])
        let r = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("sec-a")])
        let output = text(r)
        XCTAssertFalse(output.contains("part: word/charts/chart1.xml, id: rIdEvil"),
                       "a refused entry must never appear as an ordinary listed row: \(output)")
        XCTAssertTrue(output.contains("refused for security"), output)
        XCTAssertTrue(output.contains("rIdEvil"), output)
    }

    func testExportAllImagesDoesNotReadOutsideThePackageForAMaliciousChartTarget() async throws {
        let path = try buildFixtureWithMaliciousChartTarget(canaryPath: "../../../../../../../../etc/hosts")
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("sec-b"),
        ])
        let outDir = tempDir.appendingPathComponent("secout").path
        let r = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string("sec-b"), "output_dir": .string(outDir),
        ])
        let output = text(r)
        XCTAssertTrue(output.contains("refused for security"), output)
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? []
        XCTAssertTrue(listing.isEmpty, "no file should have been exported from a refused relationship: \(listing)")
    }

    func testExportImageRefusesAMaliciousChartTargetByIdWithAnExplicitReason() async throws {
        let path = try buildFixtureWithMaliciousChartTarget(canaryPath: "../../../../../../../../etc/hosts")
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("sec-c"),
        ])
        let savePath = tempDir.appendingPathComponent("should_not_exist.png").path
        let r = await server.invokeToolForTesting(name: "export_image", arguments: [
            "doc_id": .string("sec-c"), "image_id": .string("rIdEvil"), "save_path": .string(savePath),
        ])
        XCTAssertEqual(r.isError, true, text(r))
        XCTAssertTrue(text(r).contains("rIdEvil"), text(r))
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath))
    }

    /// A legitimate chart Target (conventional `../media/...` form) must
    /// still work after the fix — the security check is a containment
    /// check, not a `..`-ban.
    func testExportAllImagesStillExportsALegitimateChartImage() async throws {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body"))
        let firstPassURL = tempDir.appendingPathComponent("legit-firstpass.docx")
        try DocxWriter.write(doc, to: firstPassURL)
        let unpacked = try ZipHelper.unzip(firstPassURL)
        defer { ZipHelper.cleanup(unpacked) }
        let wordDir = unpacked.appendingPathComponent("word")
        let chartsDir = wordDir.appendingPathComponent("charts")
        try FileManager.default.createDirectory(at: chartsDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordDir.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data([0x77]).write(to: wordDir.appendingPathComponent("media/legitchart.png"))
        try "<c:chartSpace/>".write(to: chartsDir.appendingPathComponent("chart1.xml"), atomically: true, encoding: .utf8)
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdLegit" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/legitchart.png"/>
        </Relationships>
        """
        try relsXML.write(to: chartsDir.appendingPathComponent("_rels/chart1.xml.rels"), atomically: true, encoding: .utf8)
        let finalData = try ZipHelper.zipToData(unpacked)
        let finalURL = tempDir.appendingPathComponent("legit-final.docx")
        try finalData.write(to: finalURL)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(finalURL.path), "doc_id": .string("sec-d"),
        ])
        let outDir = tempDir.appendingPathComponent("legitout").path
        let r = await server.invokeToolForTesting(name: "export_all_images", arguments: [
            "doc_id": .string("sec-d"), "output_dir": .string(outDir),
        ])
        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertFalse(text(r).contains("refused for security"), text(r))
        XCTAssertEqual(FileManager.default.contents(atPath: outDir + "/legitchart.png"), Data([0x77]))
    }

    // MARK: - End-to-end: remove_watermark does not delete outside the package

    /// #208's `cleanupOrphanedWatermarkMedia` is the DELETE-side sibling of
    /// the same vulnerability class: it fed an attacker-controlled
    /// relationship `Target` straight to `FileManager.removeItem` with no
    /// containment check at all. Builds a document whose header carries a
    /// real watermark-shaped paragraph (so `stripWatermark` fires) but
    /// whose OWN relationship Target has been hand-edited to path-traverse
    /// out to a canary file this test owns — `remove_watermark` must not
    /// delete it.
    func testRemoveWatermarkDoesNotDeleteFilesOutsideThePackage() async throws {
        let canaryDir = tempDir.appendingPathComponent("canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: canaryDir, withIntermediateDirectories: true)
        let canaryFile = canaryDir.appendingPathComponent("do_not_delete.txt")
        try Data("keep me".utf8).write(to: canaryFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: canaryFile.path))

        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body"))
        _ = doc.addHeader(text: "Header", type: .default)
        let firstPassURL = tempDir.appendingPathComponent("wm-mal-firstpass.docx")
        try DocxWriter.write(doc, to: firstPassURL)

        let unpacked = try ZipHelper.unzip(firstPassURL)
        defer { ZipHelper.cleanup(unpacked) }

        // A large `..` run guarantees walking up to the real filesystem
        // root regardless of how deep this unzip tempDir happens to be,
        // then descends via the canary's own absolute path — so the
        // Target deterministically points at the canary no matter where
        // the test runner happens to place its temp directories.
        let ups = String(repeating: "../", count: 40)
        let canaryAbsoluteMinusLeadingSlash = String(canaryFile.path.dropFirst())
        let maliciousTarget = ups + canaryAbsoluteMinusLeadingSlash

        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
               xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office"
               xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <w:p>
            <w:r>
              <w:pict>
                <v:shape id="WordPictureWatermark1" o:spt="75" type="#_x0000_t75" style="position:absolute">
                  <v:imagedata r:id="rIdEvilImg" o:title=""/>
                </v:shape>
              </w:pict>
            </w:r>
          </w:p>
        </w:hdr>
        """
        try headerXML.write(to: unpacked.appendingPathComponent("word/header1.xml"), atomically: true, encoding: .utf8)

        let headerRelsDir = unpacked.appendingPathComponent("word/_rels")
        try FileManager.default.createDirectory(at: headerRelsDir, withIntermediateDirectories: true)
        let headerRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdEvilImg" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="\(maliciousTarget)"/>
        </Relationships>
        """
        try headerRelsXML.write(to: headerRelsDir.appendingPathComponent("header1.xml.rels"), atomically: true, encoding: .utf8)

        let finalData = try ZipHelper.zipToData(unpacked)
        let finalURL = tempDir.appendingPathComponent("wm-mal-final.docx")
        try finalData.write(to: finalURL)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(finalURL.path), "doc_id": .string("sec-wm"),
        ])
        let r = await server.invokeToolForTesting(name: "remove_watermark", arguments: ["doc_id": .string("sec-wm")])

        XCTAssertNotEqual(r.isError, true, text(r))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canaryFile.path),
                      "a malicious relationship Target must never cause a file outside the package to be deleted")
        XCTAssertEqual(try? Data(contentsOf: canaryFile), Data("keep me".utf8))
    }
}
