import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#61 v3.15.1 follow-up — close the verify findings
/// from v3.15.0 ensemble (5 Claude reviewers + Codex):
///
/// - F1 (P1): `after_image_id` anchor missing on insert_paragraph + insert_equation +
///   insert_image_from_path. Lib `InsertLocation.afterImageId` exists since #44 and
///   is wired into `insert_caption` already; v3.15.0 only wired the 4 cases that
///   `insert_image_from_path` exposed. v3.15.1 adds the 5th anchor symmetrically.
///
/// - F2 (P1): `into_table_cell` missing on insert_equation. Display-mode equation
///   is structurally a new paragraph, so cell placement is well-defined.
///
/// - F3 (P2): equation success message lacked anchor info — same v3.14.4 LOOKUP
///   over-claim pattern. Now mirrors paragraph message.
///
/// - F5 (P2): malformed `into_table_cell` partial dict (e.g. `{table_index:0}` with
///   missing row/col) silently fell through to the next anchor branch instead of
///   reporting the user error. Now returns structured error in both
///   insert_paragraph and insert_image_from_path.
final class Issue61V315PointReleaseTests: XCTestCase {

    // MARK: - F1: after_image_id on insert_paragraph

    func testInsertParagraphAfterImageIdResolvesAnchor() async throws {
        let url = try docxWithImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61aii")]
        )

        // First insert an image to get its rId.
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let imgR = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("p61aii"),
                "path": .string(png.path),
                "width": .int(50), "height": .int(50)
            ]
        )
        let imgMsg = textOf(imgR)
        // Match "with id 'rIdN'"
        let rId: String = {
            let re = try! NSRegularExpression(pattern: "with id '(rId\\d+)'")
            let m = re.firstMatch(in: imgMsg, range: NSRange(imgMsg.startIndex..., in: imgMsg))
            guard let m, let r = Range(m.range(at: 1), in: imgMsg) else { return "" }
            return String(imgMsg[r])
        }()
        XCTAssertFalse(rId.isEmpty, "could not extract rId from: \(imgMsg)")

        // Now insert a paragraph anchored after that image.
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61aii"),
                "text": .string("CAPTION_AFTER_IMG"),
                "after_image_id": .string(rId)
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_paragraph after_image_id should succeed; got: \(r.content)")
        let msg = textOf(r)
        XCTAssertTrue(msg.contains("after image"), "message should mention image anchor; got: \(msg)")
    }

    func testInsertParagraphAfterImageIdNotFoundReturnsError() async throws {
        let url = try docxWithImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61aii_n")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61aii_n"),
                "text": .string("WONT_LAND"),
                "after_image_id": .string("rId99999")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("not found") || txt.contains("rId99999"),
            "missing image rId should report error; got: \(txt)"
        )
    }

    // MARK: - F1 + F2: insert_equation after_image_id + into_table_cell (display mode)

    func testInsertEquationAfterImageIdDisplayModeResolvesAnchor() async throws {
        let url = try docxWithImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61aii")]
        )
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let imgR = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("e61aii"),
                "path": .string(png.path),
                "width": .int(50), "height": .int(50)
            ]
        )
        let imgMsg = textOf(imgR)
        let rId: String = {
            let re = try! NSRegularExpression(pattern: "with id '(rId\\d+)'")
            let m = re.firstMatch(in: imgMsg, range: NSRange(imgMsg.startIndex..., in: imgMsg))
            guard let m, let r = Range(m.range(at: 1), in: imgMsg) else { return "" }
            return String(imgMsg[r])
        }()
        XCTAssertFalse(rId.isEmpty)

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61aii"),
                "latex": .string("E = mc^2"),
                "display_mode": .bool(true),
                "after_image_id": .string(rId)
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_equation after_image_id should succeed; got: \(r.content)")
    }

    func testInsertEquationIntoTableCellDisplayMode() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before")])))
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])
        doc.body.children.append(.table(table))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_eq_cell_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61cell")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61cell"),
                "latex": .string("\\frac{a}{b}"),
                "display_mode": .bool(true),
                "into_table_cell": .object([
                    "table_index": .int(0),
                    "row": .int(0),
                    "col": .int(0)
                ])
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_equation into_table_cell (display mode) should succeed; got: \(r.content)")
    }

    func testInsertEquationIntoTableCellRejectedInInlineMode() async throws {
        var doc = WordDocument()
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])
        doc.body.children.append(.table(table))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_eq_cell_inline_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61cell_i")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61cell_i"),
                "latex": .string("x^2"),
                "display_mode": .bool(false),
                "into_table_cell": .object([
                    "table_index": .int(0),
                    "row": .int(0),
                    "col": .int(0)
                ])
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("display mode") || txt.contains("display_mode"),
            "inline mode + into_table_cell must reject; got: \(txt)"
        )
    }

    // MARK: - F1: after_image_id on insert_image_from_path

    func testInsertImageFromPathAfterImageIdResolvesAnchor() async throws {
        let url = try docxWithImage()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i61aii")]
        )
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let imgR1 = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("i61aii"),
                "path": .string(png.path),
                "width": .int(50), "height": .int(50)
            ]
        )
        let firstMsg = textOf(imgR1)
        let firstRId: String = {
            let re = try! NSRegularExpression(pattern: "with id '(rId\\d+)'")
            let m = re.firstMatch(in: firstMsg, range: NSRange(firstMsg.startIndex..., in: firstMsg))
            guard let m, let r = Range(m.range(at: 1), in: firstMsg) else { return "" }
            return String(firstMsg[r])
        }()
        XCTAssertFalse(firstRId.isEmpty)

        // Insert a second image anchored after the first.
        let r = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("i61aii"),
                "path": .string(png.path),
                "width": .int(50), "height": .int(50),
                "after_image_id": .string(firstRId)
            ]
        )
        XCTAssertFalse(r.isError == true, "insert_image_from_path after_image_id should succeed; got: \(r.content)")
    }

    // MARK: - F3: equation success message includes anchor info

    func testInsertEquationMessageIncludesAfterTextAnchor() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "EQ_HERE")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_eq_msg_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61msg")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61msg"),
                "latex": .string("a+b"),
                "display_mode": .bool(true),
                "after_text": .string("EQ_HERE")
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("EQ_HERE") || msg.contains("after text") || msg.contains("instance"),
            "equation message should confirm anchor info; got: \(msg)"
        )
    }

    // MARK: - F5: malformed into_table_cell partial dict reports error

    func testInsertParagraphMalformedIntoTableCellReportsError() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_malformed_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p61mal")]
        )

        // Pass into_table_cell with only table_index — missing row + col.
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p61mal"),
                "text": .string("WONT_LAND_IN_CELL"),
                "into_table_cell": .object([
                    "table_index": .int(0)
                ])
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("into_table_cell") || txt.contains("missing"),
            "malformed into_table_cell should return structured error; got: \(txt)"
        )
    }

    func testInsertImageFromPathMalformedIntoTableCellReportsError() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_img_malformed_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i61mal")]
        )
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }

        let r = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("i61mal"),
                "path": .string(png.path),
                "width": .int(50), "height": .int(50),
                "into_table_cell": .object([
                    "table_index": .int(0),
                    "row": .int(0)
                ])  // missing col
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("into_table_cell") || txt.contains("missing"),
            "malformed into_table_cell should return structured error; got: \(txt)"
        )
    }

    // MARK: - Helpers

    private func docxWithImage() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "doc")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_v315_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func writeOnePixelPNG() throws -> URL {
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_v315_pixel_\(UUID().uuidString).png")
        try pngData.write(to: pngURL)
        return pngURL
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
