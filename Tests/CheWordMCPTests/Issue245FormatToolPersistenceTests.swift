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
/// `set_page_borders` could NOT be fixed the same way at the time: `SectionProperties`
/// had no field for `<w:pgBorders>` at all (verified against
/// `.build/checkouts/ooxml-swift/Sources/OOXMLSwift/Models/Section.swift`), so
/// per #245's own two-option framework it failed loudly (`ToolNotImplemented` →
/// `isError: true`) instead of returning a success string describing an OOXML
/// change nothing wrote.
///
/// #256: ooxml-swift v3.18.0 (#191) added `SectionProperties.pageBorders`
/// (`PageBorders`/`PageBorderSide`), so `set_page_borders` now writes real
/// `<w:pgBorders>` — the `ToolNotImplemented` stub test below is replaced by
/// real persistence + round-trip tests, alongside the strict-validation
/// tests (#240 shape: wrong JSON type and well-typed-but-illegal value both
/// rejected, naming the parameter) for `style`/`color`/`size`/`space`/
/// `offset_from`.
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

    // MARK: - set_page_borders (#256)

    func testSetPageBordersWritesPgBordersAndRoundTrips() async throws {
        let fixture = try makeMixedFixture(suffix: "borders")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "b1", savePath: savePath,
            toolName: "set_page_borders",
            arguments: [
                "doc_id": .string("b1"), "style": .string("double"), "color": .string("C00000"),
                "size": .int(8), "space": .int(30), "offset_from": .string("page"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let pb = try XCTUnwrap(saved.sectionProperties.pageBorders, "pageBorders must round-trip on an already-open (overlay-mode) document")
        XCTAssertEqual(pb.offsetFrom, "page")
        for side in [pb.top, pb.bottom, pb.left, pb.right] {
            let s = try XCTUnwrap(side)
            XCTAssertEqual(s.style, "double")
            XCTAssertEqual(s.color, "C00000")
            XCTAssertEqual(s.size, 8)
            XCTAssertEqual(s.space, 30)
        }
    }

    func testSetPageBordersOmittedSideIsNilAfterRoundTrip() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-sides")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "b2", savePath: savePath,
            toolName: "set_page_borders",
            arguments: ["doc_id": .string("b2"), "style": .string("single"), "top": .bool(false)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let pb = try XCTUnwrap(saved.sectionProperties.pageBorders)
        XCTAssertNil(pb.top, "top: false must omit the <w:top> element, not merely hide it")
        XCTAssertNotNil(pb.bottom)
        XCTAssertNotNil(pb.left)
        XCTAssertNotNil(pb.right)
    }

    func testSetPageBordersRejectsUnknownStyle() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-badstyle")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b3")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b3"), "style": .string("triple")]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("style"), textOf(r))
    }

    func testSetPageBordersRejectsWrongTypeStyle() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-styletype")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b4")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b4"), "style": .int(5)]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("style"), textOf(r))
    }

    func testSetPageBordersRejectsMalformedColor() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-color")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b5")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b5"), "style": .string("single"), "color": .string("GGGGGG")]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("color"), textOf(r))
    }

    func testSetPageBordersAcceptsAutoColor() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-autocolor")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()
        let r = try await openAndSave(
            server, fixture: fixture, docId: "b6", savePath: savePath,
            toolName: "set_page_borders",
            arguments: ["doc_id": .string("b6"), "style": .string("single"), "color": .string("auto")]
        )
        XCTAssertFalse(r.isError == true, textOf(r))
        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        XCTAssertEqual(saved.sectionProperties.pageBorders?.top?.color, "auto")
    }

    func testSetPageBordersRejectsOutOfRangeSize() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-size")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b7")]
        )
        let tooSmall = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b7"), "style": .string("single"), "size": .int(1)]
        )
        XCTAssertEqual(tooSmall.isError, true, textOf(tooSmall))
        XCTAssertTrue(textOf(tooSmall).contains("size"), textOf(tooSmall))

        let tooBig = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b7"), "style": .string("single"), "size": .int(97)]
        )
        XCTAssertEqual(tooBig.isError, true, textOf(tooBig))
        XCTAssertTrue(textOf(tooBig).contains("size"), textOf(tooBig))
    }

    func testSetPageBordersRejectsNegativeSpace() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-space")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b8")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b8"), "style": .string("single"), "space": .int(-1)]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("space"), textOf(r))
    }

    func testSetPageBordersRejectsUnknownOffsetFrom() async throws {
        let fixture = try makeMixedFixture(suffix: "borders-offset")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("b9")]
        )
        let r = await server.invokeToolForTesting(
            name: "set_page_borders",
            arguments: ["doc_id": .string("b9"), "style": .string("single"), "offset_from": .string("margin")]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("offset_from"), textOf(r))
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

    // MARK: - insert_tab_stop R2 (#245-1, MEDIUM) — external (Word-style) <w:tabs> forms

    /// A fixture whose paragraph 0 already carries a `<w:tabs>` element in
    /// the non-self-closing form (`<w:tab ...></w:tab>`, valid XML/OOXML,
    /// ECMA-376 does not mandate self-closing for an empty element) with
    /// attributes in a different order than this tool's own writer uses —
    /// simulating what `DocxReader` would have captured verbatim into
    /// `rawChildren` from a document some OTHER tool (real Word, or
    /// anything not ooxml-swift) produced.
    private func makeFixtureWithExternalStyleTabs(suffix: String) throws -> URL {
        var doc = WordDocument()
        var para = Paragraph(runs: [Run(text: "hello")])
        para.properties.rawChildren.append(
            RawElement(
                name: "tabs",
                xml: "<w:tabs><w:tab w:pos=\"720\" w:val=\"left\"></w:tab></w:tabs>"
            ))
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue245_extern-tabs_\(suffix)_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// #245-1: an independent review flagged the pre-fix regex
    /// (`<w:tab\b([^>]*)/>`, self-closing only) as unable to match this
    /// non-self-closing form. **Honesty note**: this fixture's non-self-
    /// closing `<w:tab>` does NOT actually reach the regex in its
    /// non-self-closing form via a real `open_document` round trip —
    /// `DocxReader`'s own raw-capture normalizes every genuinely-empty
    /// element to self-closing (`.nodeCompactEmptyElement`) before
    /// `rawChildren` ever sees it, confirmed while building this test (see
    /// `parseExistingTabStops`'s own doc comment for the full trace). So
    /// this test does NOT reproduce a live silent-drop bug — the OLD regex
    /// passes it too, for the same upstream-normalization reason. It is
    /// kept as a direct correctness/robustness check of the new
    /// `XMLDocument`-based parser against the form #245-1 named (defense-
    /// in-depth: the new parser handles it correctly regardless of whether
    /// today's upstream normalization keeps doing the same), and to
    /// satisfy #245-1's explicit request for "an external (Word-style)
    /// `<w:tabs>` fixture". The genuinely reachable part of #245-1 — a
    /// `<w:tab>` missing `w:pos`, previously silently dropped — IS a real
    /// RED→GREEN regression guard; see
    /// `testInsertTabStopRejectsWhenExistingTabIsUnparseable` below.
    func testInsertTabStopPreservesExternalNonSelfClosingTabForm() async throws {
        let fixture = try makeFixtureWithExternalStyleTabs(suffix: "preserve")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()

        let r = try await openAndSave(
            server, fixture: fixture, docId: "ext1", savePath: savePath,
            toolName: "insert_tab_stop",
            arguments: [
                "doc_id": .string("ext1"), "paragraph_index": .int(0), "position": .int(1440),
                "alignment": .string("right"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        let tabsRaw = try XCTUnwrap(saved.getParagraphs().first?.properties.rawChildren.first { $0.name == "tabs" })
        XCTAssertTrue(
            tabsRaw.xml.contains("w:pos=\"720\""),
            "the pre-existing, non-self-closing tab stop must survive the rebuild, not silently vanish. got: \(tabsRaw.xml)"
        )
        XCTAssertTrue(tabsRaw.xml.contains("w:pos=\"1440\""), "the newly inserted tab stop must also be present. got: \(tabsRaw.xml)")
        let tabCount = tabsRaw.xml.components(separatedBy: "<w:tab ").count - 1
        XCTAssertEqual(tabCount, 2, "exactly two tab stops, none dropped, none duplicated. got: \(tabsRaw.xml)")
    }

    /// A fixture whose existing `<w:tab>` is missing `w:pos` entirely —
    /// genuinely unparseable in the sense that matters (no position to
    /// preserve). Per #245-1's explicit requirement, this must refuse
    /// (isError) rather than silently rebuild `<w:tabs>` without it.
    func testInsertTabStopRejectsWhenExistingTabIsUnparseable() async throws {
        var doc = WordDocument()
        var para = Paragraph(runs: [Run(text: "hello")])
        para.properties.rawChildren.append(
            RawElement(name: "tabs", xml: "<w:tabs><w:tab w:val=\"left\"/></w:tabs>"))
        doc.body.children.append(.paragraph(para))
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue245_unparseable-tabs_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("ext2")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("ext2"), "paragraph_index": .int(0), "position": .int(1440)]
        )
        XCTAssertEqual(r.isError, true, "must refuse rather than silently drop the unparseable existing tab. got: \(textOf(r))")
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
