import XCTest
import MCP
import CoreGraphics
import ImageIO
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#199 — `list_images` reports whether each image is
/// referenced by the document body, not merely that a relationship exists.
///
/// Before #199 the tool iterated the relationship-driven `getImages()` and used
/// the body only to look up dimensions; an orphan (relationship declared, no
/// `<w:drawing>` in `word/document.xml`) showed up as `size: 0x0px` inside
/// "Found N image(s)" — the macdoc#175 delivery read 4 missing images as "all 7
/// present". The listing now runs the same `PackageInspector` the save gate
/// uses, on the same bytes, so "list then save" agree.
final class Issue199ListImagesBodyReferenceTests: XCTestCase {

    // MARK: - helpers

    private func text(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
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

    private func rIds(in listing: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"id: (rId[0-9]+)"#)
        let ns = listing as NSString
        return re.matches(in: listing, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// open → insert one image (appended paragraph). Returns the image's rId as listed.
    private func openWithImage(_ server: WordMCPServer, url: URL, id: String) async throws -> String {
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string(id)])
        let png = try pngPath(); defer { try? FileManager.default.removeItem(atPath: png) }
        let ins = await server.invokeToolForTesting(name: "insert_image_from_path", arguments: ["doc_id": .string(id), "path": .string(png)])
        XCTAssertFalse(text(ins).hasPrefix("Error"), text(ins))
        let listed = text(await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string(id)]))
        let ids = rIds(in: listed)
        XCTAssertEqual(ids.count, 1, "exactly one image expected after one insert: \(listed)")
        return ids.first ?? "rId?"
    }

    /// open → insert → delete the paragraph that carried the image → orphan relationship.
    private func orphanSession(_ server: WordMCPServer, url: URL, id: String) async throws -> String {
        let rId = try await openWithImage(server, url: url, id: id)
        let del = await server.invokeToolForTesting(name: "delete_paragraph", arguments: ["doc_id": .string(id), "index": .int(1)])
        XCTAssertFalse(text(del).hasPrefix("Error"), text(del))
        return rId
    }

    // MARK: - (a) session orphan

    func testSessionOrphanIsMarkedNotReferencedAndWarned() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        let rId = try await orphanSession(server, url: url, id: "s199a")
        let dirtyBefore = await server.isDocumentDirtyForTesting("s199a")

        let listing = text(await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("s199a")]))

        XCTAssertTrue(listing.contains("Found 1 image(s) — 0 referenced in body, 1 orphan"), listing)
        XCTAssertTrue(listing.contains("id: \(rId), "), listing)
        XCTAssertTrue(listing.contains("referenced: NO (orphan)"), "the orphan row must say so explicitly, not hide behind 0x0: \(listing)")
        XCTAssertFalse(listing.contains("referenced: yes"), listing)
        XCTAssertTrue(listing.contains("⚠ 1 orphan image relationship(s) in word/document.xml: \(rId)"), listing)
        XCTAssertTrue(listing.contains("macdoc#175"), "the warning must name the silent-loss signature: \(listing)")
        XCTAssertTrue(listing.contains("E_IMAGE_CONSISTENCY"), "the warning must predict what save_document will do: \(listing)")
        XCTAssertTrue(listing.contains("Package: bodyDrawings=0, imageRelationships=1, mediaEntries=1"), listing)

        let dirtyAfter = await server.isDocumentDirtyForTesting("s199a")
        XCTAssertEqual(dirtyBefore, dirtyAfter, "listing serializes a copy for inspection; it must not touch session state")
    }

    // MARK: - (b) direct mode reads the bytes on disk

    func testDirectModeReadsDiskBytesAndFlagsOrphan() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("i199-out-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: out) }
        let server = await WordMCPServer()
        let rId = try await orphanSession(server, url: url, id: "s199b")
        let saved = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string("s199b"), "path": .string(out.path), "allow_orphan_images": .bool(true)])
        XCTAssertFalse(text(saved).hasPrefix("Error"), text(saved))
        // sanity: the file on disk really carries the orphan
        let report = try PackageInspector.imageConsistencyReport(of: Data(contentsOf: out))
        XCTAssertEqual(report.orphanImageRelationshipIds, [rId])

        let listing = text(await server.invokeToolForTesting(name: "list_images", arguments: ["source_path": .string(out.path)]))
        XCTAssertTrue(listing.contains("Found 1 image(s) — 0 referenced in body, 1 orphan"), listing)
        XCTAssertTrue(listing.contains("id: \(rId), ") && listing.contains("referenced: NO (orphan)"), listing)
        XCTAssertTrue(listing.contains("⚠ 1 orphan image relationship(s) in word/document.xml: \(rId)"), listing)
    }

    // MARK: - (c) consistent document

    func testConsistentDocumentListsAllReferencedWithoutWarning() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        let rId = try await openWithImage(server, url: url, id: "s199c")

        let listing = text(await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("s199c")]))
        XCTAssertTrue(listing.contains("Found 1 image(s) — 1 referenced in body, 0 orphan"), listing)
        XCTAssertTrue(listing.contains("id: \(rId), file: "), listing)
        XCTAssertTrue(listing.contains("referenced: yes"), listing)
        XCTAssertFalse(listing.contains("⚠"), "no warning for a consistent package: \(listing)")
        XCTAssertFalse(listing.contains("orphan)"), listing)
        XCTAssertTrue(listing.contains("Package: bodyDrawings=1, imageRelationships=1, mediaEntries=1"), listing)
    }

    // MARK: - (d) no images: byte-identical reply

    func testNoImagesReplyIsUnchanged() async throws {
        let url = try docxWithText("no pictures here"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("s199d")])
        let session = text(await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("s199d")]))
        let direct = text(await server.invokeToolForTesting(name: "list_images", arguments: ["source_path": .string(url.path)]))
        XCTAssertEqual(session, "No images in document")
        XCTAssertEqual(direct, "No images in document")
    }

    // MARK: - (e) orphans are content, not an error

    func testOrphanListingIsNotAnErrorOnTheWire() async throws {
        let url = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = try await orphanSession(server, url: url, id: "s199e")
        let r = try await server.handleToolCall(CallTool.Parameters(name: "list_images", arguments: ["doc_id": .string("s199e")]))
        XCTAssertNotEqual(r.isError, true, "a listing that contains orphans succeeded as a listing; the warning is content (#202 convention: only refusals are errors)")
        XCTAssertTrue(text(r).contains("referenced: NO (orphan)"), text(r))
        XCTAssertFalse(text(r).hasPrefix("Error"), text(r))
    }

    // MARK: - (f) the check itself failing must not revert to "everything is present"

    func testInspectionFailureMarksRowsUnknownAndSaysSo() {
        let rows: [(id: String, fileName: String, widthPx: Int, heightPx: Int)] = [
            (id: "rId5", fileName: "image1.png", widthPx: 2, heightPx: 2),
            (id: "rId6", fileName: "image2.png", widthPx: 0, heightPx: 0),
        ]
        let listing = WordMCPServer.imageListing(rows: rows, inspection: nil, inspectionFailure: "serialization failed: boom")
        XCTAssertTrue(listing.hasPrefix("Found 2 image(s) — body-reference check unavailable"), listing)
        XCTAssertEqual(listing.components(separatedBy: "referenced: unknown").count - 1, 2, listing)
        XCTAssertFalse(listing.contains("referenced: yes"), "an uninspectable package must not be reported as consistent: \(listing)")
        XCTAssertTrue(listing.contains("⚠ body-reference check unavailable: serialization failed: boom"), listing)
        XCTAssertFalse(listing.hasPrefix("Error"), "not a refusal — the sweep in RefusalIsErrorSweepTests must not see an Error: literal here")
    }

    /// The pure formatter: one referenced, one orphan in the
    /// document part, one orphan in a header part (which list_images does not
    /// list, but must not stay silent about).
    func testFormatterNamesOtherPartOrphansSeparately() {
        let rows: [(id: String, fileName: String, widthPx: Int, heightPx: Int)] = [
            (id: "rId5", fileName: "image1.png", widthPx: 2, heightPx: 2),
            (id: "rId6", fileName: "image2.png", widthPx: 0, heightPx: 0),
        ]
        let inspection = WordMCPServer.ImageListingInspection(
            bodyDrawingCount: 1, imageRelationshipCount: 3, mediaEntryCount: 3,
            orphanDocumentIds: ["rId6"], otherPartOrphans: ["word/header1.xml:rId2"])
        let listing = WordMCPServer.imageListing(rows: rows, inspection: inspection, inspectionFailure: nil)
        XCTAssertTrue(listing.contains("Found 2 image(s) — 1 referenced in body, 1 orphan"), listing)
        XCTAssertTrue(listing.contains("id: rId5, file: image1.png, size: 2x2px, referenced: yes"), listing)
        XCTAssertTrue(listing.contains("id: rId6, file: image2.png, size: 0x0px, referenced: NO (orphan)"), listing)
        XCTAssertTrue(listing.contains("⚠ 1 orphan image relationship(s) in word/document.xml: rId6"), listing)
        XCTAssertTrue(listing.contains("⚠ 1 orphan image relationship(s) in other parts (not listed above): word/header1.xml:rId2"), listing)
        XCTAssertTrue(listing.contains("Package: bodyDrawings=1, imageRelationships=3, mediaEntries=3"), listing)
    }
}
