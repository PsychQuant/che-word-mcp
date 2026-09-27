import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#245 — `set_columns`, `set_page_borders`,
/// `set_row_height`, `set_cell_width`, `insert_tab_stop`, `clear_tab_stops`,
/// `set_outline_level` all reported success but wrote nothing to the saved
/// document (real-binary verified in the issue, comparing `word/document.xml`
/// before and after the call).
///
/// Six of the seven are fixed for real, locked down here with the
/// "`open_document` an existing `.docx` → call → `save_document` → read back"
/// shape:
///
/// - `set_columns`: `doc.sectionProperties.columns`/`columnSpacing` were
///   already the right typed fields, but nothing ever called
///   `doc.markPartDirty("word/document.xml")` — the one PUBLIC wrapper
///   ooxml-swift exposes around its internal `markTypedDirty` specifically
///   for external consumers like this one (see `Document.swift`'s own doc
///   comment on `markPartDirty`). Overlay mode (an already-open document)
///   only regenerates a part present in `modifiedParts`; without the mark,
///   the edit was silently discarded on save.
/// - `set_row_height`/`set_cell_width`: `TableRowProperties.height`/
///   `heightRule` and `TableCellProperties.width`/`widthType` are plain
///   stored properties (not tree-backed-mode computed indirection —
///   DocxReader parses tables into legacy/detached mode exclusively). The
///   handlers never mutated `doc` at all before this fix; they now walk
///   `body.children` to the target table (replicating `getTableIndices()`,
///   which is `private` to ooxml-swift) and call `markPartDirty` the same
///   way `setTableBorders`/`setCellShading` do internally.
/// - `insert_tab_stop`/`clear_tab_stops`/`set_outline_level`: ooxml-swift's
///   typed `ParagraphProperties` has no field for `<w:tabs>` or
///   `<w:outlineLvl>` at all, but both element names ARE in
///   `ParagraphProperties.canonicalPPrPosition` (so `toXML()` places them at
///   the correct `<w:pPr>` schema position) while deliberately NOT in
///   `DocxReader.recognizedPPrChildNames` (no typed field claims them) — so
///   they round-trip through the public `rawChildren`/`RawElement(name:
///   xml:)` mechanism ooxml-swift already uses to preserve pPr children
///   outside its typed vocabulary. That mechanism is this fix's public path.
///
/// `set_page_borders` could NOT be fixed the same way: `SectionProperties`
/// has no field for `<w:pgBorders>` at all (verified against
/// `.build/checkouts/ooxml-swift/Sources/OOXMLSwift/Models/Section.swift`).
/// Per #245's own two-option framework and the `protect_document`/
/// `insert_watermark` (#172/#201) precedent, it now fails loudly
/// (`ToolNotImplemented` → `isError: true`) instead of returning a success
/// string describing an OOXML change nothing wrote.
final class Issue245FormatToolPersistenceTests: XCTestCase {

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    /// One paragraph, one 2x2 table — covers both the paragraph-scoped
    /// tools (tabs/outline level/columns/page borders) and the table-scoped
    /// tools (row height/cell width) from a single fixture.
    private func makeMixedFixture(suffix: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello")])))
        let row0 = TableRow(cells: [
            TableCell(paragraphs: [Paragraph(text: "r0c0")]),
            TableCell(paragraphs: [Paragraph(text: "r0c1")]),
        ])
        let row1 = TableRow(cells: [
            TableCell(paragraphs: [Paragraph(text: "r1c0")]),
            TableCell(paragraphs: [Paragraph(text: "r1c1")]),
        ])
        doc.body.children.append(.table(Table(rows: [row0, row1])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue245_\(suffix)_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func openAndSave(
        _ server: WordMCPServer, fixture: URL, docId: String, savePath: String,
        toolName: String, arguments: [String: Value]
    ) async throws -> CallTool.Result {
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string(docId)]
        )
        let r = await server.invokeToolForTesting(name: toolName, arguments: arguments)
        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string(docId), "path": .string(savePath)]
        )
        return r
    }

    // MARK: - set_columns

    func testSetColumnsWritesColumnsAndSpaceOnAnExistingDocument() async throws {
        let fixture = try makeMixedFixture(suffix: "columns")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "c1", savePath: savePath,
            toolName: "set_columns",
            arguments: ["doc_id": .string("c1"), "columns": .int(2), "space": .int(1000)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        XCTAssertEqual(saved.sectionProperties.columns, 2, "columns must round-trip on an already-open (overlay-mode) document")
        XCTAssertEqual(saved.sectionProperties.columnSpacing, 1000, "space must round-trip, not just columns")
    }

    // MARK: - set_page_borders

    func testSetPageBordersFailsInsteadOfClaimingSuccess() async throws {
        let fixture = try makeMixedFixture(suffix: "borders")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b1")]
        )

        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b1"), "style": .string("single")]
        )
        XCTAssertEqual(r.isError, true, "set_page_borders has no public ooxml-swift API to write <w:pgBorders> — it must fail, not claim success. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("pgBorders"), "the error should name the missing OOXML element. Got: \(textOf(r))")
    }

    // MARK: - set_row_height

    func testSetRowHeightWritesHeightAndRule() async throws {
        let fixture = try makeMixedFixture(suffix: "rowheight")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "rh1", savePath: savePath,
            toolName: "set_row_height",
            arguments: [
                "doc_id": .string("rh1"), "table_index": .int(0), "row_index": .int(1),
                "height": .int(500), "height_rule": .string("exact"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let tables = saved.getTables()
        XCTAssertEqual(tables.count, 1)
        XCTAssertEqual(tables.first?.rows[1].properties.height, 500)
        XCTAssertEqual(tables.first?.rows[1].properties.heightRule, .exact)
        // Row 0 must be untouched — only the targeted row changes.
        XCTAssertNil(tables.first?.rows[0].properties.height)
    }

    func testSetRowHeightRejectsInvalidHeightRule() async throws {
        let fixture = try makeMixedFixture(suffix: "rowheight-invalid")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("rh2")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_row_height",
            arguments: [
                "doc_id": .string("rh2"), "table_index": .int(0), "row_index": .int(0),
                "height": .int(500), "height_rule": .string("bogus"),
            ]
        )
        XCTAssertEqual(r.isError, true)
    }

    // MARK: - set_cell_width

    func testSetCellWidthWritesWidthAndType() async throws {
        let fixture = try makeMixedFixture(suffix: "cellwidth")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "cw1", savePath: savePath,
            toolName: "set_cell_width",
            arguments: [
                "doc_id": .string("cw1"), "table_index": .int(0), "row": .int(0), "col": .int(1),
                "width": .int(2400), "width_type": .string("dxa"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let tables = saved.getTables()
        XCTAssertEqual(tables.first?.rows[0].cells[1].properties.width, 2400)
        XCTAssertEqual(tables.first?.rows[0].cells[1].properties.widthType, .dxa)
        // The other cell in the same row must be untouched.
        XCTAssertNil(tables.first?.rows[0].cells[0].properties.width)
    }

    func testSetCellWidthRejectsInvalidWidthType() async throws {
        let fixture = try makeMixedFixture(suffix: "cellwidth-invalid")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("cw2")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_cell_width",
            arguments: [
                "doc_id": .string("cw2"), "table_index": .int(0), "row": .int(0), "col": .int(0),
                "width": .int(100), "width_type": .string("bogus"),
            ]
        )
        XCTAssertEqual(r.isError, true)
    }

    // MARK: - insert_tab_stop / clear_tab_stops

    func testInsertTabStopWritesTabsElement() async throws {
        let fixture = try makeMixedFixture(suffix: "tabstop")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "t1", savePath: savePath,
            toolName: "insert_tab_stop",
            arguments: [
                "doc_id": .string("t1"), "paragraph_index": .int(0), "position": .int(1440),
                "alignment": .string("right"), "leader": .string("dot"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let paragraphs = saved.getParagraphs()
        let tabsRaw = try XCTUnwrap(paragraphs.first?.properties.rawChildren.first { $0.name == "tabs" })
        XCTAssertTrue(tabsRaw.xml.contains("w:pos=\"1440\""), "got: \(tabsRaw.xml)")
        XCTAssertTrue(tabsRaw.xml.contains("w:val=\"right\""), "got: \(tabsRaw.xml)")
        XCTAssertTrue(tabsRaw.xml.contains("w:leader=\"dot\""), "got: \(tabsRaw.xml)")
    }

    /// A second call at the SAME position replaces the first, rather than
    /// stacking two `<w:tab>` elements at the same `w:pos` (which Word
    /// itself never produces).
    func testInsertTabStopAtSamePositionReplacesNotStacks() async throws {
        let fixture = try makeMixedFixture(suffix: "tabstop-replace")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("t2")]
        )
        let first = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: [
                "doc_id": .string("t2"), "paragraph_index": .int(0), "position": .int(1440),
                "alignment": .string("left"),
            ]
        )
        XCTAssertFalse(first.isError == true, textOf(first))
        let second = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: [
                "doc_id": .string("t2"), "paragraph_index": .int(0), "position": .int(1440),
                "alignment": .string("right"), "leader": .string("dot"),
            ]
        )
        XCTAssertFalse(second.isError == true, textOf(second))
        // A second, DIFFERENT position must coexist with the first.
        let third = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("t2"), "paragraph_index": .int(0), "position": .int(2880)]
        )
        XCTAssertFalse(third.isError == true, textOf(third))
        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("t2"), "path": .string(savePath)]
        )

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let tabsRaw = try XCTUnwrap(saved.getParagraphs().first?.properties.rawChildren.first { $0.name == "tabs" })
        let tabCount = tabsRaw.xml.components(separatedBy: "<w:tab ").count - 1
        XCTAssertEqual(tabCount, 2, "position 1440 must be replaced (not duplicated), position 2880 must be added. got: \(tabsRaw.xml)")
        XCTAssertTrue(tabsRaw.xml.contains("w:val=\"right\""), "the replacement (not the original left) must win at pos 1440. got: \(tabsRaw.xml)")
        XCTAssertTrue(tabsRaw.xml.contains("w:pos=\"2880\""), "got: \(tabsRaw.xml)")
    }

    func testClearTabStopsRemovesTabsElement() async throws {
        let fixture = try makeMixedFixture(suffix: "cleartabs")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("ct1")]
        )
        let inserted = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("ct1"), "paragraph_index": .int(0), "position": .int(720)]
        )
        XCTAssertFalse(inserted.isError == true, textOf(inserted))

        let cleared = await server.invokeToolForTesting(
            name: "clear_tab_stops", arguments: ["doc_id": .string("ct1"), "paragraph_index": .int(0)]
        )
        XCTAssertFalse(cleared.isError == true, textOf(cleared))
        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("ct1"), "path": .string(savePath)]
        )

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let hasTabs = saved.getParagraphs().first?.properties.rawChildren.contains { $0.name == "tabs" } ?? false
        XCTAssertFalse(hasTabs, "clear_tab_stops must remove the <w:tabs> element entirely, not just leave an empty one")
    }

    /// `paragraph_index` past the top-level count must be rejected, not
    /// silently accepted-then-no-op — same #139-style bounds discipline the
    /// other advanced paragraph-formatting tools already have.
    func testInsertTabStopRejectsOutOfRangeParagraphIndex() async throws {
        let fixture = try makeMixedFixture(suffix: "tabstop-oob")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("t3")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("t3"), "paragraph_index": .int(99), "position": .int(720)]
        )
        XCTAssertEqual(r.isError, true)
    }

    // MARK: - set_outline_level

    func testSetOutlineLevelWritesOutlineLvl() async throws {
        let fixture = try makeMixedFixture(suffix: "outline")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "o1", savePath: savePath,
            toolName: "set_outline_level",
            arguments: ["doc_id": .string("o1"), "paragraph_index": .int(0), "level": .int(2)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let outlineRaw = try XCTUnwrap(saved.getParagraphs().first?.properties.rawChildren.first { $0.name == "outlineLvl" })
        // Schema's documented contract: level 2 (Word's "Level 2") maps to
        // the 0-based ECMA `w:val="1"`.
        XCTAssertTrue(outlineRaw.xml.contains("w:val=\"1\""), "got: \(outlineRaw.xml)")
    }

    /// `level: 0` ("body text") must OMIT the element, matching Word's own
    /// representation of "no outline level assigned" — not emit a
    /// `w:val="0"` (which would mean ECMA Heading-1-equivalent, level 1,
    /// not body text).
    func testSetOutlineLevelZeroOmitsElement() async throws {
        let fixture = try makeMixedFixture(suffix: "outline-zero")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("o2")]
        )
        // First set a non-zero level, then reset to 0 — proves the reset
        // path actually removes a previously-written element, not just
        // "never wrote one in the first place".
        let first = await server.invokeToolForTesting(
            name: "set_outline_level",
            arguments: ["doc_id": .string("o2"), "paragraph_index": .int(0), "level": .int(3)]
        )
        XCTAssertFalse(first.isError == true, textOf(first))
        let reset = await server.invokeToolForTesting(
            name: "set_outline_level",
            arguments: ["doc_id": .string("o2"), "paragraph_index": .int(0), "level": .int(0)]
        )
        XCTAssertFalse(reset.isError == true, textOf(reset))
        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("o2"), "path": .string(savePath)]
        )

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let hasOutline = saved.getParagraphs().first?.properties.rawChildren.contains { $0.name == "outlineLvl" } ?? false
        XCTAssertFalse(hasOutline, "level 0 (body text) must remove any previously-set <w:outlineLvl>, not write w:val=\"0\"")
    }

    func testSetOutlineLevelRejectsOutOfRangeParagraphIndex() async throws {
        let fixture = try makeMixedFixture(suffix: "outline-oob")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("o3")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_outline_level",
            arguments: ["doc_id": .string("o3"), "paragraph_index": .int(99), "level": .int(1)]
        )
        XCTAssertEqual(r.isError, true)
    }
}
