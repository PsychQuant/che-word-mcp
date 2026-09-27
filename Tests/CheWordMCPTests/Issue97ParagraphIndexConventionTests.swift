import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#97 — pin the current paragraph-index convention
/// split without changing public API behavior.
///
/// #140 (verify of #113 follow-up): the original fixture here was
/// `[paragraph, table, blockSDT, paragraph]` (4 elements) — one paragraph
/// short of what actually differentiates `body.children` insertion index
/// from top-level paragraph ordinal at "index 1" (inline-mode `insert_equation`
/// vs `insert_paragraph`). Extended to 5 elements — `[paragraph0, table,
/// paragraph2, blockSDT(paragraph_inSDT), paragraph4]` — and the former
/// mega-test (three families + three doc/schema substring assertions in one
/// method) is split into one named test per family, plus dedicated coverage
/// for inline-mode `insert_equation` and `set_paragraph_border`'s SDT-past
/// rejection (the two P1/P2 cases the mega-test's fixture couldn't reach).
final class Issue97ParagraphIndexConventionTests: XCTestCase {

    // MARK: - Fixture (5 elements; #140)

    /// `body.children` = [paragraph0("p0"), table, paragraph2("p2"),
    /// contentControl(SDT wrapping paragraph("sdt-inner")), paragraph4("p4")].
    /// `body.children.count` = 5.
    /// Top-level `.paragraph` ordinals: p0=0, p2=1, p4=2 (count 3) — the
    /// table and the SDT are skipped.
    /// `getParagraphs()` readback index: p0=0, p2=1, sdt-inner=2, p4=3
    /// (count 4) — descends into the block-level SDT, skips the table.
    private func conventionFixture() -> WordDocument {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "table-cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p2")])))
        let sdt = StructuredDocumentTag(
            id: 9701,
            tag: "issue97_wrapper",
            alias: "Issue 97 Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: sdt, content: "")
        doc.body.children.append(.contentControl(control, children: [
            .paragraph(Paragraph(runs: [Run(text: "sdt-inner")]))
        ]))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p4")])))
        return doc
    }

    private func fixtureURL() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue97_\(UUID().uuidString).docx")
        try DocxWriter.write(conventionFixture(), to: url)
        return url
    }

    // MARK: - Named per-family tests (#140)

    func testGetParagraphsRecursesIntoSDTButSkipsTables() throws {
        let doc = conventionFixture()
        XCTAssertEqual(doc.body.children.count, 5)
        XCTAssertEqual(
            doc.getParagraphs().map { $0.getText() },
            ["p0", "p2", "sdt-inner", "p4"],
            "getParagraphs readback index descends into block-level SDTs but skips table-cell paragraphs"
        )
    }

    func testInsertParagraphAtIndex1UsesBodyChildrenIndex() {
        var doc = conventionFixture()
        doc.insertParagraph(Paragraph(runs: [Run(text: "inserted-before-table")]), at: 1)
        guard case .paragraph(let inserted) = doc.body.children[1] else {
            XCTFail("body.children[1] should be the newly-inserted paragraph"); return
        }
        XCTAssertEqual(inserted.getText(), "inserted-before-table")
        guard case .table = doc.body.children[2] else {
            XCTFail("body.children insertion index 1 must insert before the table body child"); return
        }
    }

    func testInsertEquationDisplayModeUsesBodyChildrenIndex() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i97disp")]
        )
        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("i97disp"), "latex": .string("x"),
                "display_mode": .bool(true), "paragraph_index": .int(1)
            ]
        )
        XCTAssertTrue(text(r).contains("Inserted equation"), "expected success; got: \(text(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i97disp"), "path": .string(savePath)]
        )
        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertEqual(saved.body.children.count, 6, "display mode inserts a NEW body child (5 → 6)")
        guard case .paragraph(let newPara) = saved.body.children[1] else {
            XCTFail("body.children[1] must be the newly-inserted equation paragraph"); return
        }
        let hasOMML = newPara.runs.contains { $0.rawXML?.contains("<m:oMath") ?? false }
            || newPara.unrecognizedChildren.contains { $0.name == "oMath" || $0.name == "oMathPara" }
        XCTAssertTrue(hasOMML, "body.children[1] must carry the new equation")
        guard case .table = saved.body.children[2] else {
            XCTFail("table must have shifted from body.children[1] to body.children[2]"); return
        }
    }

    /// The mega-test's original 4-element fixture had only ONE top-level
    /// paragraph before the SDT, so it could never show inline mode
    /// (top-level ordinal) diverging from `body.children` insertion index
    /// at "index 1" — inline mode's index 1 landed on the same paragraph
    /// object either counting scheme would pick. The 5-element fixture puts
    /// a table at `body.children[1]`, so inline mode's ordinal 1 (`p2`) and
    /// `body.children` index 1 (the table) are now provably different
    /// targets.
    func testInsertEquationInlineModeUsesTopLevelParagraphOrdinal() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i97inline")]
        )
        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("i97inline"), "latex": .string("x"),
                "display_mode": .bool(false), "paragraph_index": .int(1)
            ]
        )
        XCTAssertTrue(text(r).contains("Inserted equation"), "expected success; got: \(text(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i97inline"), "path": .string(savePath)]
        )
        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertEqual(saved.body.children.count, 5, "inline mode must not add a body child")
        guard case .table = saved.body.children[1] else {
            XCTFail("table at body.children[1] must be untouched by inline mode"); return
        }
        guard case .paragraph(let p2) = saved.body.children[2] else {
            XCTFail("body.children[2] should still be paragraph 'p2'"); return
        }
        let p2HasOMML = p2.runs.contains { $0.rawXML?.contains("<m:oMath") ?? false }
            || p2.unrecognizedChildren.contains { $0.name == "oMath" || $0.name == "oMathPara" }
        XCTAssertTrue(p2HasOMML, "top-level paragraph ordinal 1 (p2) must receive the appended OMML run, not the table")
    }

    /// #139's fix: `set_paragraph_border` now bounds-checks against the SAME
    /// top-level counting model its mutation uses, rejecting any index at or
    /// past the top-level count instead of silently no-op'ing (readback
    /// count is 4; top-level count is 3, so index 3 — readback's `p4` — no
    /// longer exists as a top-level ordinal and must be rejected).
    func testSetParagraphBorderRejectsIndexPastTopLevelCount() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i97border")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_paragraph_border",
            arguments: ["doc_id": .string("i97border"), "paragraph_index": .int(3), "type": .string("single")]
        )
        XCTAssertEqual(r.isError, true, "readback index 3 (p4) is past the top-level count (3); must reject, not silently no-op")
    }

    /// Index 2 is in-bounds for BOTH families in this fixture, but names a
    /// DIFFERENT paragraph in each (readback→sdt-inner, top-level→p4).
    /// `set_paragraph_border`'s mutation always resolves top-level indices,
    /// so it must land on `p4`, never on the SDT-inner paragraph.
    func testSetParagraphBorderAppliesToTopLevelOrdinalNotSDTInner() async throws {
        let url = try fixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i97border2")]
        )
        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "set_paragraph_border",
            arguments: ["doc_id": .string("i97border2"), "paragraph_index": .int(2), "type": .string("single")]
        )
        XCTAssertTrue(text(r).contains("Set border"), "expected success; got: \(text(r))")

        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("i97border2"), "path": .string(savePath)]
        )
        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        guard case .paragraph(let p4) = saved.body.children[4] else {
            XCTFail("body.children[4] should still be 'p4'"); return
        }
        XCTAssertNotNil(p4.properties.border, "top-level ordinal 2 (p4) must receive the border")
        guard case .contentControl(_, let children) = saved.body.children[3],
              case .paragraph(let sdtInner) = children.first else {
            XCTFail("body.children[3] should still be the SDT wrapping sdt-inner"); return
        }
        XCTAssertNil(sdtInner.properties.border, "top-level paragraph ordinal must not target the block-level SDT child paragraph")
    }

    // MARK: - Frozen snapshot (renamed; #140)

    /// Frozen until PsychQuant/ooxml-swift#10 picks the canonical
    /// cross-family convention. When the lib picks one and refactors, THIS
    /// test SHOULD start failing — rewrite it then to assert the chosen
    /// convention's behavior, rather than treating a failure here as a
    /// regression to revert.
    func testPinCurrentBehaviorPendingConventionPick() throws {
        let doc = conventionFixture()

        var insertDoc = doc
        insertDoc.insertParagraph(Paragraph(runs: [Run(text: "inserted-before-table")]), at: 1)
        guard case .paragraph(let inserted) = insertDoc.body.children[1] else {
            XCTFail(); return
        }
        XCTAssertEqual(inserted.getText(), "inserted-before-table")
        guard case .table = insertDoc.body.children[2] else {
            XCTFail("body.children insertion index 1 must insert before the table body child"); return
        }

        var mutateDoc = doc
        var bold = RunProperties()
        bold.bold = true
        try mutateDoc.formatParagraph(at: 1, with: bold)

        guard case .paragraph(let topOne) = mutateDoc.body.children[2] else {
            XCTFail("fixture body child 2 ('p2') should remain the second top-level paragraph"); return
        }
        XCTAssertTrue(topOne.runs.first?.properties.bold ?? false, "top-level paragraph ordinal 1 targets the second direct body paragraph ('p2')")

        guard case .contentControl(_, let children) = mutateDoc.body.children[3],
              case .paragraph(let sdtPara) = children.first else {
            XCTFail("fixture body child 3 should be a block-level SDT containing one paragraph"); return
        }
        XCTAssertFalse(
            sdtPara.runs.first?.properties.bold ?? false,
            "top-level paragraph ordinal must not target the block-level SDT child paragraph"
        )
    }

    // MARK: - Doc / schema coverage (unchanged from #113/#138)

    func testParagraphIndexConventionDocsInventoryExists() throws {
        let docs = try String(contentsOf: repoRoot().appendingPathComponent("docs/paragraph-index-conventions.md"), encoding: .utf8)

        XCTAssertTrue(docs.contains("`body.children` insertion index"))
        XCTAssertTrue(docs.contains("Top-level paragraph ordinal"))
        XCTAssertTrue(docs.contains("`get_paragraphs` readback index"))
        XCTAssertTrue(docs.contains("`insert_paragraph.index`"))
        XCTAssertTrue(docs.contains("`insert_caption.paragraph_index`"))
        XCTAssertTrue(docs.contains("`format_text.paragraph_index`, `set_paragraph_format.paragraph_index`, `apply_style.paragraph_index`"))
        XCTAssertTrue(docs.contains("`set_paragraph_border.paragraph_index`, `set_paragraph_shading.paragraph_index`, `set_character_spacing.paragraph_index`, `set_text_effect.paragraph_index`"))
        XCTAssertTrue(docs.contains("`get_paragraph_runs.paragraph_index`, `get_text_with_formatting.paragraph_index`"))
        XCTAssertTrue(docs.contains("Public API renaming or typed wrapper indices would be a breaking change"))
    }

    func testRepresentativeSchemaDescriptionsNameIndexFamilies() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/CheWordMCP/Server.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("get_paragraphs readback index：top-level paragraphs + block-level SDT 內段落"))
        XCTAssertTrue(source.contains("index 是 body.children 插入索引"))
        XCTAssertTrue(source.contains("不是 get_paragraphs 的 paragraph readback index"))
        XCTAssertTrue(source.contains("top-level paragraph ordinal（從 0 開始；只計直接位於 body.children 的 `.paragraph`"))
        XCTAssertTrue(source.contains("body.children 插入索引（從 0 開始；計入 tables / block-level SDTs / bookmark markers / raw blocks）。五 anchor 擇一"))
    }

    func testReadmeLinksConventionGuide() throws {
        let readme = try String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("### Paragraph Index Conventions"))
        XCTAssertTrue(readme.contains("[docs/paragraph-index-conventions.md](docs/paragraph-index-conventions.md)"))
    }

    // MARK: - Helpers

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}
