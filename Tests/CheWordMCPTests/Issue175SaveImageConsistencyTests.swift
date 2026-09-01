import XCTest
import MCP
import CoreGraphics
import ImageIO
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/macdoc#175 — append-mode image silent loss.
///
/// Two layers under test:
/// 1. Regression locks for the repro matrix (rows 1/2/6) through the real MCP
///    dispatcher, with ooxml-swift ≥ 3.6.0 (the fix itself lives there:
///    `isOpPayloadRepresentable` gating the append fast path, ooxml-swift#128).
///    Assertions read the SAVED BYTES via `PackageInspector` — the same
///    inspector the save gate uses — never the in-memory session state that
///    lied in the original incident.
/// 2. The save-time image-consistency gate (`E_IMAGE_CONSISTENCY`): its pure
///    decision core, the open-baseline passthrough for files that already
///    carry orphan image relationships, and the `allow_orphan_images` escape.
final class Issue175SaveImageConsistencyTests: XCTestCase {

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func docxWithText(_ text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i175-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Deterministic valid PNG of the given pixel size. Distinct sizes give
    /// distinct bytes, so two inserts land as two media entries (the ooxml
    /// Issue175 suite hit a media-dedup artifact when reusing one file).
    private func pngData(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = { () -> CGImage? in
                ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                return ctx.makeImage()
            }()
        else { throw XCTSkip("CGContext unavailable") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("PNG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func tempPNGPath(width: Int, height: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i175-\(UUID().uuidString).png")
        try pngData(width: width, height: height).write(to: url)
        return url.path
    }

    private func report(ofFileAt url: URL) throws -> ImageConsistencyReport {
        try PackageInspector.imageConsistencyReport(of: Data(contentsOf: url))
    }

    // MARK: - Repro-matrix regression locks (rows 6 / 1 / 2)

    /// Row 6: insert one appended image → save immediately.
    func testAppendedImageSurvivesSave() async throws {
        let url = try docxWithText("seed")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try tempPNGPath(width: 1, height: 1)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175r6")])
        let ins = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("i175r6"), "path": .string(png)])
        XCTAssertFalse(textOf(ins).hasPrefix("Error"), "insert failed: \(textOf(ins))")

        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175r6")])
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save refused: \(textOf(save))")

        let r = try report(ofFileAt: url)
        XCTAssertEqual(r.bodyDrawingCount, 1, "the appended image's <w:drawing> must be in the saved body")
        XCTAssertTrue(r.isConsistent, "orphans: \(r.orphanImageRelationshipIds)")
    }

    /// Row 1: two appended images in a row → save → both drawings present.
    func testTwoAppendedImagesBothSurviveSave() async throws {
        let url = try docxWithText("seed")
        defer { try? FileManager.default.removeItem(at: url) }
        let pngA = try tempPNGPath(width: 1, height: 1)
        let pngB = try tempPNGPath(width: 2, height: 2)
        defer {
            try? FileManager.default.removeItem(atPath: pngA)
            try? FileManager.default.removeItem(atPath: pngB)
        }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175r1")])
        for png in [pngA, pngB] {
            let ins = await server.invokeToolForTesting(
                name: "insert_image_from_path",
                arguments: ["doc_id": .string("i175r1"), "path": .string(png)])
            XCTAssertFalse(textOf(ins).hasPrefix("Error"), "insert failed: \(textOf(ins))")
        }

        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175r1")])
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save refused: \(textOf(save))")

        let r = try report(ofFileAt: url)
        XCTAssertEqual(r.bodyDrawingCount, 2)
        XCTAssertEqual(r.mediaEntryCount, 2)
        XCTAssertTrue(r.isConsistent, "orphans: \(r.orphanImageRelationshipIds)")
    }

    /// Row 2: appended image followed by an appended text paragraph → save.
    /// (In the original bug the trailing typed-dirty edit could either mask or
    /// materialize the backlog — either way the saved file must hold both.)
    func testAppendedImageThenTextParagraphSurvivesSave() async throws {
        let url = try docxWithText("seed")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try tempPNGPath(width: 1, height: 1)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175r2")])
        let ins = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("i175r2"), "path": .string(png)])
        XCTAssertFalse(textOf(ins).hasPrefix("Error"), "insert failed: \(textOf(ins))")
        let para = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("i175r2"), "text": .string("caption after image")])
        XCTAssertFalse(textOf(para).hasPrefix("Error"), "insert_paragraph failed: \(textOf(para))")

        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175r2")])
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save refused: \(textOf(save))")

        let r = try report(ofFileAt: url)
        XCTAssertEqual(r.bodyDrawingCount, 1)
        XCTAssertTrue(r.isConsistent, "orphans: \(r.orphanImageRelationshipIds)")

        let reopened = try DocxReader.read(from: url)
        let allText = reopened.body.children.compactMap { child -> String? in
            if case .paragraph(let p) = child { return p.text }
            return nil
        }.joined(separator: "\n")
        XCTAssertTrue(allText.contains("caption after image"), "trailing paragraph lost: \(allText)")
    }

    /// Text-only edits must never trip the gate.
    func testPlainTextSaveIsNotBlockedByGate() async throws {
        let url = try docxWithText("seed")
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175t")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("i175t"), "text": .string("plain")])
        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175t")])
        XCTAssertFalse(textOf(save).contains("E_IMAGE_CONSISTENCY"), "gate misfired: \(textOf(save))")
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save failed: \(textOf(save))")
    }

    // MARK: - Gate: pure decision core

    func testRefusalFiresOnSessionNewOrphan() throws {
        let msg = WordMCPServer.imageConsistencyRefusalMessage(
            orphanIds: ["rId7"], baselineOrphanIds: [],
            bodyDrawingCount: 0, imageRelationshipCount: 1, mediaEntryCount: 1)
        let unwrapped = try XCTUnwrap(msg)
        XCTAssertTrue(unwrapped.contains("E_IMAGE_CONSISTENCY"))
        XCTAssertTrue(unwrapped.contains("rId7"))
        XCTAssertTrue(unwrapped.contains("bodyDrawings=0"))
        XCTAssertTrue(unwrapped.contains("allow_orphan_images"), "message must name the escape hatch")
        XCTAssertTrue(unwrapped.contains("No file was written"))
    }

    func testRefusalStaysSilentWhenOrphanAlreadyInBaseline() {
        XCTAssertNil(WordMCPServer.imageConsistencyRefusalMessage(
            orphanIds: ["rId7"], baselineOrphanIds: ["rId7"],
            bodyDrawingCount: 3, imageRelationshipCount: 4, mediaEntryCount: 4))
    }

    func testRefusalStaysSilentWhenNoOrphans() {
        XCTAssertNil(WordMCPServer.imageConsistencyRefusalMessage(
            orphanIds: [], baselineOrphanIds: [],
            bodyDrawingCount: 2, imageRelationshipCount: 2, mediaEntryCount: 2))
    }

    func testRefusalNamesOnlyTheNewOrphans() throws {
        let msg = WordMCPServer.imageConsistencyRefusalMessage(
            orphanIds: ["rId3", "rId9"], baselineOrphanIds: ["rId3"],
            bodyDrawingCount: 1, imageRelationshipCount: 3, mediaEntryCount: 3)
        let unwrapped = try XCTUnwrap(msg)
        XCTAssertTrue(unwrapped.contains("rId9"))
        XCTAssertFalse(unwrapped.contains("rId3"), "baseline orphan must not be blamed")
    }

    // MARK: - Gate: open-baseline passthrough (integration)

    /// A file that ALREADY contains an orphan image relationship (legitimate —
    /// Word tolerates it, third-party writers produce it) must keep saving.
    func testPreexistingOrphanPassesThrough() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "seed")])))
        doc.images.append(ImageReference(
            id: "rId99", fileName: "image99.png", contentType: "image/png",
            data: try pngData(width: 1, height: 1)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i175-orphan-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Premise check: the crafted file really carries an orphan. If
        // DocxWriter ever starts garbage-collecting unreferenced images this
        // fixture dies loudly instead of testing nothing.
        let crafted = try report(ofFileAt: url)
        XCTAssertFalse(crafted.isConsistent, "fixture premise lost: DocxWriter no longer writes unreferenced image rels")

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175pre")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("i175pre"), "text": .string("edit")])
        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175pre")])
        XCTAssertFalse(textOf(save).contains("E_IMAGE_CONSISTENCY"),
                       "pre-existing orphan must not block saves: \(textOf(save))")
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save failed: \(textOf(save))")
    }

    // MARK: - Gate: refusal + allow_orphan_images escape (integration)

    /// Deleting an appended image's paragraph leaves the image relationship
    /// behind (paragraph deletion does not garbage-collect rels/media) — the
    /// exact byte shape the gate watches for. The refusal must fire, keep the
    /// session alive, and yield to allow_orphan_images: true.
    func testDeleteImageParagraphRefusalAndOverride() async throws {
        let url = try docxWithText("seed")
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try tempPNGPath(width: 1, height: 1)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i175d")])
        let ins = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("i175d"), "path": .string(png)])
        XCTAssertFalse(textOf(ins).hasPrefix("Error"), "insert failed: \(textOf(ins))")

        // The appended image paragraph is the last one: index 1 (0 = "seed").
        let del = await server.invokeToolForTesting(
            name: "delete_paragraph",
            arguments: ["doc_id": .string("i175d"), "index": .int(1)])
        XCTAssertFalse(textOf(del).hasPrefix("Error"), "delete failed: \(textOf(del))")

        let refused = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i175d")])
        XCTAssertTrue(textOf(refused).contains("E_IMAGE_CONSISTENCY"),
                      "expected gate refusal, got: \(textOf(refused))")

        // Refusal must not have written the file: still exactly the original.
        let onDisk = try report(ofFileAt: url)
        XCTAssertEqual(onDisk.imageRelationshipCount, 0, "refused save must leave the disk file untouched")

        let allowed = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("i175d"), "allow_orphan_images": .bool(true)])
        XCTAssertFalse(textOf(allowed).hasPrefix("Error"), "override save failed: \(textOf(allowed))")
    }
}
