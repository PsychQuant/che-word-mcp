import XCTest
import MCP
import CoreGraphics
import ImageIO
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#199 / #217 / #219 — `list_images` only listed the
/// relationship-layer view (`document.images`), so an orphan image
/// (relationship + media present, no `<w:drawing>` reference in the body —
/// the PsychQuant/macdoc#175 silent-image-loss signature) was reported as if
/// it existed, and a header/footer-only image never appeared at all
/// (`No images in document`, even with a real header logo). `get_document_info`
/// had no image count at all to be wrong about — it now gets an accurate one.
///
/// Fixed by making `list_images` / `get_document_info` consume the same
/// `PackageInspector.imageConsistencyReport` the `save_document` gate already
/// reads (#175/#199), and by listing header/footer image relationships
/// alongside document-part ones (#219).
final class Issue199ListImagesBodyReferenceTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func docxWithText(_ text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i199-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func pngPath() throws -> String {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw XCTSkip("CGContext unavailable") }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = ctx.makeImage() else { throw XCTSkip("no image") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { throw XCTSkip("no encoder") }
        CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i199-\(UUID().uuidString).png")
        try (out as Data).write(to: url)
        return url.path
    }

    /// Open → insert image (appended) → delete its paragraph → session-new
    /// orphan (same recipe as Issue175R2SaveGateTests.orphanSession).
    private func makeOrphanSession(_ server: WordMCPServer, url: URL, docId: String) async throws {
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string(docId)])
        let png = try pngPath(); defer { try? FileManager.default.removeItem(atPath: png) }
        let ins = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: ["doc_id": .string(docId), "path": .string(png)])
        XCTAssertNotEqual(ins.isError, true, textOf(ins))
        let del = await server.invokeToolForTesting(name: "delete_paragraph", arguments: ["doc_id": .string(docId), "index": .int(1)])
        XCTAssertNotEqual(del.isError, true, textOf(del))
    }

    /// #219 fixture: a document with a header carrying a REFERENCED image
    /// (relationship + media + a real `r:embed` reference in the header's
    /// own body) and ZERO body images. Pre-#219, `list_images` on this
    /// document returned the byte-exact "No images in document" — the same
    /// string it uses for a genuinely image-free document.
    private func makeHeaderImageFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Body text, no body images"))
        _ = doc.addHeader(text: "", type: .default)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("i219-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("i219-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: base, to: staging)

        let mediaDir = staging.appendingPathComponent("word/media")
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: mediaDir.appendingPathComponent("logo1.png"))

        let headerRelsDir = staging.appendingPathComponent("word/_rels")
        try FileManager.default.createDirectory(at: headerRelsDir, withIntermediateDirectories: true)
        let headerRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo1.png"/>
        </Relationships>
        """
        try headerRelsXML.write(to: headerRelsDir.appendingPathComponent("header1.xml.rels"), atomically: true, encoding: .utf8)

        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <w:p><w:r><w:drawing><a:blip xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" r:embed="rId1"/></w:drawing></w:r></w:p>
        </w:hdr>
        """
        try headerXML.write(to: staging.appendingPathComponent("word/header1.xml"), atomically: true, encoding: .utf8)

        let ctURL = staging.appendingPathComponent("[Content_Types].xml")
        var ct = try String(contentsOf: ctURL, encoding: .utf8)
        if !ct.contains("Extension=\"png\"") {
            ct = ct.replacingOccurrences(of: "</Types>", with: "<Default Extension=\"png\" ContentType=\"image/png\"/></Types>")
            try ct.write(to: ctURL, atomically: true, encoding: .utf8)
        }

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("i219-fixture-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    // MARK: - (a) Session-mode orphan: reported, not silently "exists"

    func testOrphanBodyImageIsReportedNotSilentlyPresent() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        try await makeOrphanSession(server, url: url, docId: "l199a")

        let list = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("l199a")])
        let text = textOf(list)
        XCTAssertNotEqual(list.isError, true, "an orphan is content, not a protocol error: \(text)")
        XCTAssertTrue(text.contains("NO (orphan)"), "Got: \(text)")
        XCTAssertTrue(text.contains("word/document.xml"), "Got: \(text)")
        XCTAssertTrue(text.contains("1 referenced, 1 orphan") || text.contains("0 referenced, 1 orphan"), "Got: \(text)")
        XCTAssertTrue(text.contains("allow_orphan_images"), "must predict the save_document refusal: \(text)")

        let info = await server.invokeToolForTesting(name: "get_document_info", arguments: ["doc_id": .string("l199a")])
        XCTAssertTrue(textOf(info).contains("orphan"), "get_document_info must not report a naive relationship count: \(textOf(info))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("l199a"), "discard_changes": .bool(true)])
    }

    // MARK: - (b) Direct Mode reads the same signal from disk bytes

    func testDirectModeOrphanDetectionReadsDiskBytes() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        try await makeOrphanSession(server, url: url, docId: "l199b")
        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("l199b"), "allow_orphan_images": .bool(true)])
        XCTAssertNotEqual(save.isError, true, textOf(save))
        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("l199b"), "discard_changes": .bool(true)])

        let list = await server.invokeToolForTesting(name: "list_images", arguments: ["source_path": .string(url.path)])
        XCTAssertTrue(textOf(list).contains("NO (orphan)"), "Direct Mode must see the same orphan the session saved: \(textOf(list))")
    }

    // MARK: - (c) Consistent document → all referenced, no warning block

    func testConsistentBodyImageIsAllReferenced() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("l199c")])
        let png = try pngPath(); defer { try? FileManager.default.removeItem(atPath: png) }
        _ = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: ["doc_id": .string("l199c"), "path": .string(png)])

        let list = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("l199c")])
        let text = textOf(list)
        XCTAssertTrue(text.contains("referenced: yes"), "Got: \(text)")
        XCTAssertTrue(text.contains("0 orphan"), "Got: \(text)")
        XCTAssertFalse(text.contains("⚠"), "a consistent document must carry no orphan warning block: \(text)")

        let info = await server.invokeToolForTesting(name: "get_document_info", arguments: ["doc_id": .string("l199c")])
        XCTAssertTrue(textOf(info).contains("1 referenced"), "Got: \(textOf(info))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("l199c"), "discard_changes": .bool(true)])
    }

    // MARK: - (d) No images anywhere → byte-exact legacy string preserved

    func testNoImagesAnywhereKeepsTheExactLegacyMessage() async throws {
        let url = try docxWithText("no images here"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("l199d")])

        let list = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("l199d")])
        XCTAssertEqual(textOf(list), "No images in document")

        let info = await server.invokeToolForTesting(name: "get_document_info", arguments: ["doc_id": .string("l199d")])
        XCTAssertTrue(textOf(info).contains("- Images: 0"), "Got: \(textOf(info))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("l199d"), "discard_changes": .bool(true)])
    }

    // MARK: - (e) #219 — header-only image is listed, not "No images"

    /// Direct Mode deliberately — the fixture's header carries a
    /// hand-authored, simplified `<w:drawing>` (not the full
    /// `<wp:inline>`/`<pic:pic>` DrawingML the typed model's header parser
    /// round-trips); Direct Mode's `PackageInspector` scan reads the FIXTURE
    /// BYTES DIRECTLY off disk (see `imageConsistencyInspection`), so this
    /// test is independent of whether ooxml-swift's typed model would
    /// preserve that exact shape through a read→write round trip (Session
    /// Mode's `list_images` re-serializes via `DocxWriter.writeData`, a
    /// separate, already-tested concern — see `testOrphanBodyImageIsReportedNotSilentlyPresent`
    /// for the Session Mode path with a typed-model-native image).
    func testHeaderOnlyImageIsListedWithPartQualifier() async throws {
        let fixture = try makeHeaderImageFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let list = await WordMCPServer().invokeToolForTesting(name: "list_images", arguments: ["source_path": .string(fixture.path)])
        let text = textOf(list)
        XCTAssertNotEqual(text, "No images in document", "a header-only image must not report as 'no images' (#219)")
        XCTAssertTrue(text.contains("word/header1.xml"), "Got: \(text)")
        XCTAssertTrue(text.contains("id: rId1"), "Got: \(text)")
        XCTAssertTrue(text.contains("referenced: yes"), "the header's own <w:drawing> reference must be seen: \(text)")

        let info = await WordMCPServer().invokeToolForTesting(name: "get_document_info", arguments: ["source_path": .string(fixture.path)])
        XCTAssertTrue(textOf(info).contains("1 referenced"), "Got: \(textOf(info))")
    }

    // MARK: - Pure formatting function (no PackageInspector needed)

    func testImageListingReportsUnknownWhenInspectionFailed() {
        let rows: [(part: String, id: String, fileName: String, widthPx: Int?, heightPx: Int?)] =
            [(part: "word/document.xml", id: "rId4", fileName: "image1.png", widthPx: 100, heightPx: 50)]
        let text = WordMCPServer.imageListing(rows: rows, report: nil, inspectionFailureReason: "boom")
        XCTAssertTrue(text.contains("referenced: unknown"), "Got: \(text)")
        XCTAssertTrue(text.contains("⚠ body-reference check unavailable: boom"), "Got: \(text)")
    }

    func testDocumentInfoImagesLineNeverClaimsANaiveCount() {
        let rows: [(part: String, id: String, fileName: String, widthPx: Int?, heightPx: Int?)] =
            [(part: "word/document.xml", id: "rId4", fileName: "image1.png", widthPx: 0, heightPx: 0)]
        let report = ImageConsistencyReport(
            bodyDrawingCount: 0, imageRelationshipCount: 1, mediaEntryCount: 1,
            orphanImageRelationshipIds: ["rId4"],
            orphanImageRelationshipRefs: [ImageRelationshipRef(part: "word/document.xml", id: "rId4")])
        let line = WordMCPServer.documentInfoImagesLine(rows: rows, report: report, inspectionFailureReason: nil)
        XCTAssertTrue(line.contains("0 referenced, 1 orphan"), "Got: \(line)")
        XCTAssertTrue(line.contains("allow_orphan_images"), "Got: \(line)")
    }
}
