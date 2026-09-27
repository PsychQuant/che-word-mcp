import XCTest
import MCP
import PDFKit
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#16 — `insert_image_from_path` had no PDF support
/// at all (`ImageDimensions.detect` only parses PNG/JPEG headers; a `.pdf`
/// path threw `unsupportedFormat`). The design note on the issue rejected
/// *shelling out* to `pdftoppm` (hides the rasterization trade-off, adds a
/// PATH dependency) but a native, in-process rasterization via PDFKit /
/// CoreGraphics — no external process — is a materially different, accepted
/// trade-off (`.claude/rules/native-macos-compat.md`: PDFKit is this repo's
/// PDF base layer). This file pins `PDFImageRasterizer` and the
/// `insert_image_from_path` `page` parameter it's wired to.
final class Issue16PDFImageInsertionTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func docxWithText(_ text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i16-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// A real multi-page PDF (US Letter, 3 pages, each a different solid
    /// color) built via native PDFKit — no external tool.
    private func makeMultiPagePDF(pageCount: Int = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i16-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("CGContext(consumer:) unavailable in this environment")
        }
        let colors: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
        ]
        for i in 0..<pageCount {
            context.beginPage(mediaBox: &mediaBox)
            context.setFillColor(colors[i % colors.count])
            context.fill(mediaBox)
            context.endPage()
        }
        context.closePDF()
        return url
    }

    private func makeEmptyPDF() throws -> URL {
        // A PDF whose only page has a zero-area media box — exercises the
        // "empty media box" refusal without needing a 0-page PDF (PDFKit
        // makes those hard to author validly).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i16-empty-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 0, height: 0)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("CGContext(consumer:) unavailable in this environment")
        }
        context.beginPage(mediaBox: &mediaBox)
        context.endPage()
        context.closePDF()
        return url
    }

    /// #16 R2 F3: a password-protected PDF, built natively via
    /// `CGContext`'s own encryption auxiliary keys (no external tool, no
    /// third-party crypto library — `kCGPDFContextUserPassword` is
    /// CoreGraphics' own PDF-context option). `PDFDocument(url:)` does NOT
    /// return nil for this; it returns a locked, non-nil document whose
    /// `bounds(for: .mediaBox)` reports a fixed US Letter box (612x792pt)
    /// unrelated to the real 200x100pt page, and whose `draw(with:to:)`
    /// draws nothing — see `PDFImageRasterizer`'s guard this fixture pins.
    private func makeEncryptedPDF() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("i16-encrypted-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 100)
        let auxInfo: [CFString: Any] = [
            kCGPDFContextUserPassword: "secret",
            kCGPDFContextOwnerPassword: "secret-owner",
        ]
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            throw XCTSkip("CGContext(consumer:mediaBox:auxiliaryInfo:) unavailable in this environment")
        }
        context.beginPage(mediaBox: &mediaBox)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(mediaBox)
        context.endPage()
        context.closePDF()
        return url
    }

    // MARK: - PDFImageRasterizer (pure, no server)

    func testRasterizeDefaultsToPageOne() throws {
        let pdf = try makeMultiPagePDF()
        defer { try? FileManager.default.removeItem(at: pdf) }
        let result = try PDFImageRasterizer.rasterize(pdfPath: pdf.path, page: 1)
        defer { try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
        XCTAssertGreaterThan(result.widthPx, 0)
        XCTAssertGreaterThan(result.heightPx, 0)
        // 200x100pt @ 150dpi (scale 150/72) ≈ 417x208px.
        XCTAssertEqual(result.widthPx, Int((200.0 * 150.0 / 72.0).rounded()))
        XCTAssertEqual(result.heightPx, Int((100.0 * 150.0 / 72.0).rounded()))
    }

    func testRasterizeOutOfRangePageNamesTheParameterAndPageCount() throws {
        let pdf = try makeMultiPagePDF(pageCount: 3)
        defer { try? FileManager.default.removeItem(at: pdf) }
        XCTAssertThrowsError(try PDFImageRasterizer.rasterize(pdfPath: pdf.path, page: 99)) { error in
            guard case WordError.invalidParameter(let param, let reason) = error else {
                return XCTFail("expected invalidParameter, got \(error)")
            }
            XCTAssertEqual(param, "page")
            XCTAssertTrue(reason.contains("3"), "must name the actual page count: \(reason)")
        }
    }

    func testRasterizeRefusesAnEmptyMediaBox() throws {
        let pdf = try makeEmptyPDF()
        defer { try? FileManager.default.removeItem(at: pdf) }
        XCTAssertThrowsError(try PDFImageRasterizer.rasterize(pdfPath: pdf.path, page: 1))
    }

    func testRasterizeFailsForMissingFile() {
        XCTAssertThrowsError(try PDFImageRasterizer.rasterize(pdfPath: "/tmp/does-not-exist-\(UUID().uuidString).pdf", page: 1))
    }

    // MARK: - insert_image_from_path end to end

    func testInsertImageFromPathEmbedsAPDFPage() async throws {
        let docURL = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: docURL) }
        let pdf = try makeMultiPagePDF(); defer { try? FileManager.default.removeItem(at: pdf) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(docURL.path), "doc_id": .string("p16a")])

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path", arguments: ["doc_id": .string("p16a"), "path": .string(pdf.path)])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")
        XCTAssertTrue(textOf(result).contains("page 1"), "Got: \(textOf(result))")

        let list = await server.invokeToolForTesting(name: "list_images", arguments: ["doc_id": .string("p16a")])
        XCTAssertTrue(textOf(list).contains("referenced: yes"), "the rasterized page must be a real, body-referenced image. Got: \(textOf(list))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("p16a"), "discard_changes": .bool(true)])
    }

    func testInsertImageFromPathHonorsThePageParameter() async throws {
        let docURL = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: docURL) }
        let pdf = try makeMultiPagePDF(pageCount: 3); defer { try? FileManager.default.removeItem(at: pdf) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(docURL.path), "doc_id": .string("p16b")])

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("p16b"), "path": .string(pdf.path), "page": .int(2)])
        XCTAssertNotEqual(result.isError, true, "Got: \(textOf(result))")
        XCTAssertTrue(textOf(result).contains("page 2"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("p16b"), "discard_changes": .bool(true)])
    }

    func testInsertImageFromPathRejectsPageOutOfRange() async throws {
        let docURL = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: docURL) }
        let pdf = try makeMultiPagePDF(pageCount: 3); defer { try? FileManager.default.removeItem(at: pdf) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(docURL.path), "doc_id": .string("p16c")])

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("p16c"), "path": .string(pdf.path), "page": .int(50)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(textOf(result).contains("page"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("p16c"), "discard_changes": .bool(true)])
    }

    /// `page` only makes sense for a PDF source — providing it for a
    /// PNG/JPEG path is a caller mistake worth naming, not silently ignoring.
    func testPageParameterOnNonPDFSourceIsRejected() async throws {
        let docURL = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: docURL) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(docURL.path), "doc_id": .string("p16d")])

        let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("i16-\(UUID().uuidString).png")
        try Data(base64Encoded: pngBase64)!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("p16d"), "path": .string(png.path), "page": .int(1)])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(textOf(result).contains("page"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("p16d"), "discard_changes": .bool(true)])
    }

    // MARK: - #16 R2 F3: encrypted PDFs are refused, not silently blanked

    /// `PDFImageRasterizer.rasterize` directly (pure, no server) — the
    /// exact bug: pre-R2 this returned a "successful" 612x792px all-white
    /// PNG (the fixed US Letter fallback size `PDFPage.bounds(for:)` reports
    /// while locked, not the real 200x100pt page) instead of refusing.
    func testRasterizeRefusesAnEncryptedPDF() throws {
        let pdf = try makeEncryptedPDF()
        defer { try? FileManager.default.removeItem(at: pdf) }
        XCTAssertThrowsError(try PDFImageRasterizer.rasterize(pdfPath: pdf.path, page: 1)) { error in
            guard case WordError.invalidFormat(let reason) = error else {
                return XCTFail("expected invalidFormat, got \(error)")
            }
            XCTAssertTrue(reason.lowercased().contains("password") || reason.contains("密碼"), "must name why: \(reason)")
        }
    }

    /// End to end: `insert_image_from_path` on an encrypted PDF must fail
    /// loudly — never a "success" message with a plausible-looking pixel
    /// size that is actually a blank page at the wrong dimensions.
    func testInsertImageFromPathRejectsAnEncryptedPDF() async throws {
        let docURL = try docxWithText("seed"); defer { try? FileManager.default.removeItem(at: docURL) }
        let pdf = try makeEncryptedPDF(); defer { try? FileManager.default.removeItem(at: pdf) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(docURL.path), "doc_id": .string("p16e")])

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path", arguments: ["doc_id": .string("p16e"), "path": .string(pdf.path)])
        XCTAssertEqual(result.isError, true, "an encrypted PDF must never report success. Got: \(textOf(result))")
        XCTAssertTrue(textOf(result).lowercased().contains("password") || textOf(result).contains("密碼"), "Got: \(textOf(result))")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("p16e"), "discard_changes": .bool(true)])
    }
}
