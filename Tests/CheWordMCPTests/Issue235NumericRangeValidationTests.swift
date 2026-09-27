import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#235 — several numeric parameters are accepted and
/// written into the saved `.docx` without being validated against the
/// OOXML-typed attribute they end up in, so an extreme value (or a value
/// this issue's own repro used, `Int.max`) is silently accepted and
/// reported as success while producing a non-conformant file.
///
/// #235's own inventory names 11 sites; this file covers the ones that are
/// genuinely wired (the handler actually persists the value into the
/// document) with a real OOXML-typed range citation:
///
/// - `set_image_style.border_width` → `<a:ln w>`, `ST_LineWidth`
///   (0...20_116_800 EMU)
/// - `set_character_spacing.spacing`/`.position` → `ST_SignedTwipsMeasure`/
///   `ST_SignedHpsMeasure` (Int32 range)
/// - `set_character_spacing.kern` → `ST_HpsMeasure` (unsigned; 0...UInt32.max)
/// - `insert_floating_image.width`/`.height` → `<wp:extent cx/cy>`,
///   `ST_PositiveCoordinate` (1...27_273_042_316_900 EMU)
/// - `insert_cross_reference.paragraph_index`,
///   `set_text_direction.paragraph_index` — index-shaped parameters that
///   currently accept `Int.max` and report success with no bounds check at
///   all (both handlers are otherwise stubs that never persist anything
///   else; see `docs/paragraph-index-conventions.md`'s "Known stub tools"
///   section for the diagnosis correction on the OTHER 6 sites #235 lists,
///   which never persist the flagged value regardless of range — a
///   different root cause, tracked separately, not fixed here).
final class Issue235NumericRangeValidationTests: XCTestCase {

    private func singleParagraphFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p0")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue235_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    // MARK: - set_image_style.border_width (ST_LineWidth, 0...20_116_800 EMU)

    func testSetImageStyleRejectsBorderWidthAboveSTLineWidthMax() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235img")])

        // insert_image takes raw base64 + explicit pixel dimensions — it
        // never decodes the bytes as an actual image, so any byte string is
        // a valid fixture here.
        let base64 = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let insertResult = await server.invokeToolForTesting(
            name: "insert_image",
            arguments: [
                "doc_id": .string("i235img"), "base64": .string(base64), "file_name": .string("t.png"),
                "width": .int(100), "height": .int(100)
            ]
        )
        // Parse "Inserted image 't.png' with id 'rIdN' (...)" — avoids
        // hard-coding the library's own id-generation scheme.
        let insertedText = text(insertResult)
        guard let idRange = insertedText.range(of: "with id '") else {
            XCTFail("expected insert_image to succeed and report an id; got: \(insertedText)"); return
        }
        let afterId = insertedText[idRange.upperBound...]
        guard let closingQuote = afterId.firstIndex(of: "'") else {
            XCTFail("could not parse image id out of: \(insertedText)"); return
        }
        let imageId = String(afterId[..<closingQuote])

        let r = await server.invokeToolForTesting(
            name: "set_image_style",
            arguments: ["doc_id": .string("i235img"), "image_id": .string(imageId), "border_width": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(r.isError, true, "border_width above ST_LineWidth's max (20,116,800 EMU) must be rejected, not written into <a:ln w>")
    }

    // MARK: - set_character_spacing (spacing/position: Int32; kern: UInt32)

    func testSetCharacterSpacingRejectsSpacingAboveInt32Range() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235spacing")])

        let r = await server.invokeToolForTesting(
            name: "set_character_spacing",
            arguments: ["doc_id": .string("i235spacing"), "paragraph_index": .int(0), "spacing": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(r.isError, true, "spacing above what ST_SignedTwipsMeasure's 32-bit read can hold must be rejected")
    }

    func testSetCharacterSpacingRejectsNegativeKern() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235kern")])

        let r = await server.invokeToolForTesting(
            name: "set_character_spacing",
            arguments: ["doc_id": .string("i235kern"), "paragraph_index": .int(0), "kern": .int(-1)]
        )
        XCTAssertEqual(r.isError, true, "kern is ST_HpsMeasure (unsigned); a negative value must be rejected")
    }

    // MARK: - insert_floating_image.width/.height (ST_PositiveCoordinate EMU)

    func testInsertFloatingImageRejectsWidthAboveSTPositiveCoordinateMax() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235float")])

        let pngPath = url.path + ".png"
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: pngPath))
        defer { try? FileManager.default.removeItem(atPath: pngPath) }

        let r = await server.invokeToolForTesting(
            name: "insert_floating_image",
            arguments: ["doc_id": .string("i235float"), "path": .string(pngPath), "width": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(r.isError, true, "width above ST_PositiveCoordinate's max (27,273,042,316,900 EMU) must be rejected, not written into <wp:extent cx>")
    }

    // MARK: - Index-shaped parameters with no bounds check at all

    func testInsertCrossReferenceRejectsOutOfRangeParagraphIndex() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235xref")])

        let r = await server.invokeToolForTesting(
            name: "insert_cross_reference",
            arguments: [
                "doc_id": .string("i235xref"), "paragraph_index": .int(9_223_372_036_854_775_807),
                "reference_type": .string("bookmark"), "reference_target": .string("nonexistent")
            ]
        )
        XCTAssertEqual(r.isError, true, "paragraph_index far beyond the document's 1 paragraph must be rejected, not reported as success")
    }

    func testSetTextDirectionRejectsOutOfRangeParagraphIndex() async throws {
        let url = try singleParagraphFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i235textdir")])

        let r = await server.invokeToolForTesting(
            name: "set_text_direction",
            arguments: ["doc_id": .string("i235textdir"), "direction": .string("lrTb"), "paragraph_index": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(r.isError, true, "paragraph_index far beyond the document's 1 paragraph must be rejected, not reported as success")
    }
}
