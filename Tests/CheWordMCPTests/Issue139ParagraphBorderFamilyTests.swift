import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#139 — `set_paragraph_border` / `set_paragraph_shading`
/// / `set_character_spacing` / `set_text_effect` all bounds-check
/// `paragraph_index` inside ooxml-swift against `getParagraphs().count` (the
/// readback family, which recurses into block-level SDTs), but the mutation
/// loop right below it walks `body.children` counting only TOP-LEVEL
/// `.paragraph` children — silently skipping `.contentControl` (SDT) wrappers
/// without incrementing its own counter. Since che-word-mcp cannot modify
/// ooxml-swift (read-only dependency), the fix has to add an equivalent,
/// STRICTER top-level bounds check on this side before ever calling into the
/// library, so a caller never reaches the mismatched pair below:
///
/// Fixture: `body.children` = [paragraph("P0"), table, paragraph("P1"),
/// contentControl(SDT wrapping paragraph("sdt-inner")), paragraph("P2")].
/// `getParagraphs()` (readback) = [P0, P1, sdt-inner, P2] (count 4).
/// Top-level `.paragraph` ordinals = [P0, P1, P2] (count 3).
///
/// `paragraph_index: 2` is in-bounds for BOTH families but names a DIFFERENT
/// paragraph in each (readback→sdt-inner, top-level→P2). Because the
/// mutation loop only ever resolves top-level indices, index 2 always ends
/// up mutating P2 — while the caller, going by the documented/readback
/// numbering, may have meant sdt-inner. `paragraph_index: 3` is readback's
/// P2 but does not exist as a top-level ordinal at all — pre-fix, ooxml-swift's
/// own bounds check (against readback count 4) accepts it and the mutation
/// loop then walks off the end and silently does nothing (no error, no
/// change, `storeDocument` still runs and reports success).
final class Issue139ParagraphBorderFamilyTests: XCTestCase {

    private func mixedShapeFixture(suffix: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P1")])))
        let sdt = StructuredDocumentTag(
            id: 13901,
            tag: "issue139_wrapper_\(suffix)",
            alias: "Issue 139 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "P2")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue139_\(suffix)_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    // MARK: - set_paragraph_border

    /// `paragraph_index: 3` (readback's P2, but past the top-level count of
    /// 3) must be rejected — not silently accepted-then-no-op.
    func testSetParagraphBorderRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture(suffix: "border")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i139border")]
        )

        let r = await server.invokeToolForTesting(
            name: "set_paragraph_border",
            arguments: [
                "doc_id": .string("i139border"),
                "paragraph_index": .int(3),
                "type": .string("single")
            ]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist (only 0-2); must be a structured error, not a silent no-op success")
    }

    /// `paragraph_index: 2` must land on the top-level paragraph it will
    /// actually mutate (P2), and must be documented/validated against the
    /// SAME top-level family the mutation itself uses — not accepted merely
    /// because it happens to be < readback count (4).
    func testSetParagraphBorderAppliesToTopLevelOrdinalNotSDTInner() async throws {
        let url = try mixedShapeFixture(suffix: "border2")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i139border2")]
        )
        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "set_paragraph_border",
            arguments: [
                "doc_id": .string("i139border2"),
                "paragraph_index": .int(2),
                "type": .string("single")
            ]
        )
        XCTAssertTrue(textOf(r).contains("Set border"), "expected success; got: \(textOf(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("i139border2"), "path": .string(savePath)]
        )
        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))

        guard case .paragraph(let p2) = saved.body.children[4] else {
            XCTFail("body.children[4] should still be P2"); return
        }
        XCTAssertNotNil(p2.properties.border, "top-level ordinal 2 (P2) must receive the border")

        guard case .contentControl(_, let children) = saved.body.children[3],
              case .paragraph(let sdtInner) = children.first else {
            XCTFail("body.children[3] should still be the SDT wrapping sdt-inner"); return
        }
        XCTAssertNil(sdtInner.properties.border, "the SDT-inner paragraph must not receive the border")
    }

    // MARK: - set_paragraph_shading / set_character_spacing / set_text_effect
    // (same library-level bug shape; one rejection test each is enough to
    // pin the fix without re-deriving the full mutation-target assertion.)

    func testSetParagraphShadingRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture(suffix: "shading")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i139shading")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_paragraph_shading",
            arguments: ["doc_id": .string("i139shading"), "paragraph_index": .int(3), "fill": .string("FF0000")]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist; must reject, not silently no-op")
    }

    func testSetCharacterSpacingRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture(suffix: "spacing")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i139spacing")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_character_spacing",
            arguments: ["doc_id": .string("i139spacing"), "paragraph_index": .int(3), "spacing": .int(20)]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist; must reject, not silently no-op")
    }

    func testSetTextEffectRejectsIndexPastTopLevelCount() async throws {
        let url = try mixedShapeFixture(suffix: "effect")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("i139effect")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_text_effect",
            arguments: ["doc_id": .string("i139effect"), "paragraph_index": .int(3), "effect": .string("sparkle")]
        )
        XCTAssertEqual(r.isError, true, "top-level ordinal 3 does not exist; must reject, not silently no-op")
    }
}
