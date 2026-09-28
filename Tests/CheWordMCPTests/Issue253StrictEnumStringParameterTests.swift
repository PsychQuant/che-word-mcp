import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#253 — the #240 fix batch (4.7.0) only closed the
/// schema-DECLARED `enum` string parameters. A much larger family compares
/// a string parameter against a fixed set of literal values entirely in
/// Swift (`switch`, `RawRepresentable(rawValue:)` + `?? .default`,
/// `Array.contains`) without ever declaring `enum` in the tool's JSON
/// Schema — for those, a wrong JSON type (`style: 5`) was silently read as
/// `nil` by `.stringValue` and fell through to the `?? "literal-default"`
/// fallback, so a TYPE error was applied as if the caller had asked for the
/// default value. Some of these additionally never validate the VALUE
/// either (e.g. `create_style.type`, `add_header.type`).
///
/// This file exercises the batch fixed this round (see the #253 delivery
/// report for the full census methodology and the residual, NOT
/// exhaustively enumerated ~470 remaining plain-string parameters).
final class Issue253StrictEnumStringParameterTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func simpleFixtureURL(paragraphText: String = "Hello") throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: paragraphText)])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue253_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - replace_text.scope (type check missing; value already rejected)

    func testReplaceTextRejectsWrongTypeScope() async throws {
        let url = try simpleFixtureURL(paragraphText: "hello world")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i253-rt")])
        let r = await server.invokeToolForTesting(
            name: "replace_text",
            arguments: ["doc_id": .string("i253-rt"), "find": .string("hello"), "replace": .string("hi"), "scope": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "scope: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("scope"), textOf(r))
    }

    // MARK: - create_style.type (no validation at all — type AND value both silently default)

    func testCreateStyleRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-cs-a")])
        let r = await server.invokeToolForTesting(
            name: "create_style",
            arguments: ["doc_id": .string("i253-cs-a"), "style_id": .string("MyStyle"), "name": .string("My Style"), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("type"), textOf(r))
    }

    func testCreateStyleRejectsUnrecognizedTypeValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-cs-b")])
        let r = await server.invokeToolForTesting(
            name: "create_style",
            arguments: ["doc_id": .string("i253-cs-b"), "style_id": .string("MyStyle2"), "name": .string("My Style 2"), "type": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "type: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_section_break.type

    func testInsertSectionBreakRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-sb")])
        let r = await server.invokeToolForTesting(
            name: "insert_section_break", arguments: ["doc_id": .string("i253-sb"), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - add_header.type / add_footer.type (no validation at all)

    func testAddHeaderRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ah-a")])
        let r = await server.invokeToolForTesting(
            name: "add_header", arguments: ["doc_id": .string("i253-ah-a"), "text": .string("H"), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    func testAddHeaderRejectsUnrecognizedTypeValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ah-b")])
        let r = await server.invokeToolForTesting(
            name: "add_header", arguments: ["doc_id": .string("i253-ah-b"), "text": .string("H"), "type": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "type: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    func testAddFooterRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-af-a")])
        let r = await server.invokeToolForTesting(
            name: "add_footer", arguments: ["doc_id": .string("i253-af-a"), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    func testAddFooterRejectsUnrecognizedTypeValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-af-b")])
        let r = await server.invokeToolForTesting(
            name: "add_footer", arguments: ["doc_id": .string("i253-af-b"), "type": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "type: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    // MARK: - splice_omath_from_source / splice_paragraph_omath_from_source .rpr_mode / .namespace_policy
    // (no validation at all; also moved earlier in the function ahead of
    // source resolution as part of this fix, so a minimal fixture with NO
    // source_path/source_doc_id still reaches the rpr_mode/namespace_policy
    // check first.)

    // `source_paragraph_index` is included in every call below (even though
    // no real source document backs it) so the failure this test isolates
    // is unambiguously the rpr_mode/namespace_policy check, not an
    // unrelated "missing source_paragraph_index" error that happens to also
    // set `isError: true`.

    func testSpliceOMathFromSourceRejectsWrongTypeRprMode() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-so-a")])
        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "doc_id": .string("i253-so-a"), "target_paragraph_index": .int(0), "position": .string("atStart"),
                "source_paragraph_index": .int(0), "rpr_mode": .int(5),
            ]
        )
        XCTAssertEqual(r.isError, true, "rpr_mode: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("rpr_mode"), textOf(r))
    }

    func testSpliceOMathFromSourceRejectsUnrecognizedRprModeValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-so-b")])
        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "doc_id": .string("i253-so-b"), "target_paragraph_index": .int(0), "position": .string("atStart"),
                "source_paragraph_index": .int(0), "rpr_mode": .string("bogus"),
            ]
        )
        XCTAssertEqual(r.isError, true, "rpr_mode: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("rpr_mode"), textOf(r))
    }

    func testSpliceOMathFromSourceRejectsWrongTypeNamespacePolicy() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-so-c")])
        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "doc_id": .string("i253-so-c"), "target_paragraph_index": .int(0), "position": .string("atStart"),
                "source_paragraph_index": .int(0), "namespace_policy": .int(5),
            ]
        )
        XCTAssertEqual(r.isError, true, "namespace_policy: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("namespace_policy"), textOf(r))
    }

    func testSpliceParagraphOMathFromSourceRejectsWrongTypeRprMode() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-spo-a")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-spo-a"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "doc_id": .string("i253-spo-a"), "target_paragraph_index": .int(0),
                "source_paragraph_index": .int(0), "rpr_mode": .int(5),
            ]
        )
        XCTAssertEqual(r.isError, true, "rpr_mode: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("rpr_mode"), textOf(r))
    }

    func testSpliceParagraphOMathFromSourceRejectsUnrecognizedNamespacePolicyValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-spo-b")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-spo-b"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "doc_id": .string("i253-spo-b"), "target_paragraph_index": .int(0),
                "source_paragraph_index": .int(0), "namespace_policy": .string("bogus"),
            ]
        )
        XCTAssertEqual(r.isError, true, "namespace_policy: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("namespace_policy"), textOf(r))
    }

    // MARK: - set_paragraph_border.type

    func testSetParagraphBorderRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-spb")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-spb"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "set_paragraph_border", arguments: ["doc_id": .string("i253-spb"), "paragraph_index": .int(0), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_date_field.type

    func testInsertDateFieldRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-df")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-df"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_date_field", arguments: ["doc_id": .string("i253-df"), "paragraph_index": .int(0), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_page_field.type

    func testInsertPageFieldRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-pf")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-pf"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_page_field", arguments: ["doc_id": .string("i253-pf"), "paragraph_index": .int(0), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - set_line_numbers.restart (no validation at all)

    func testSetLineNumbersRejectsWrongTypeRestart() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ln-a")])
        let r = await server.invokeToolForTesting(
            name: "set_line_numbers", arguments: ["doc_id": .string("i253-ln-a"), "enable": .bool(true), "restart": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "restart: 5 must be rejected. Got: \(textOf(r))")
    }

    func testSetLineNumbersRejectsUnrecognizedRestartValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ln-b")])
        let r = await server.invokeToolForTesting(
            name: "set_line_numbers", arguments: ["doc_id": .string("i253-ln-b"), "enable": .bool(true), "restart": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "restart: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    // MARK: - set_line_numbers_for_section.restart (no validation at all)

    func testSetLineNumbersForSectionRejectsWrongTypeRestart() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-lns-a")])
        let r = await server.invokeToolForTesting(
            name: "set_line_numbers_for_section",
            arguments: ["doc_id": .string("i253-lns-a"), "section_index": .int(0), "count_by": .int(1), "restart": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "restart: 5 must be rejected. Got: \(textOf(r))")
    }

    func testSetLineNumbersForSectionRejectsUnrecognizedRestartValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-lns-b")])
        let r = await server.invokeToolForTesting(
            name: "set_line_numbers_for_section",
            arguments: ["doc_id": .string("i253-lns-b"), "section_index": .int(0), "count_by": .int(1), "restart": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "restart: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_symbol.position

    func testInsertSymbolRejectsWrongTypePosition() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-is")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-is"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_symbol", arguments: ["doc_id": .string("i253-is"), "paragraph_index": .int(0), "char": .string("F020"), "position": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "position: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_drop_cap.type (value already rejected; type is not)

    func testInsertDropCapRejectsWrongTypeType() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-dc")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-dc"), "text": .string("Hello world")])
        let r = await server.invokeToolForTesting(
            name: "insert_drop_cap", arguments: ["doc_id": .string("i253-dc"), "paragraph_index": .int(0), "type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "type: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_horizontal_line.style (value already rejected; type is not)

    func testInsertHorizontalLineRejectsWrongTypeStyle() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-hl")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-hl"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_horizontal_line", arguments: ["doc_id": .string("i253-hl"), "paragraph_index": .int(0), "style": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "style: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_caption.position

    func testInsertCaptionRejectsWrongTypePosition() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-cap")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-cap"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: ["doc_id": .string("i253-cap"), "label": .string("Figure"), "paragraph_index": .int(0), "position": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "position: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - insert_tab_stop.alignment / .leader (value already rejected; type is not)

    func testInsertTabStopRejectsWrongTypeAlignment() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ts-a")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-ts-a"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("i253-ts-a"), "paragraph_index": .int(0), "position": .int(720), "alignment": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "alignment: 5 must be rejected. Got: \(textOf(r))")
    }

    func testInsertTabStopRejectsWrongTypeLeader() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-ts-b")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-ts-b"), "text": .string("x")])
        let r = await server.invokeToolForTesting(
            name: "insert_tab_stop",
            arguments: ["doc_id": .string("i253-ts-b"), "paragraph_index": .int(0), "position": .int(720), "leader": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "leader: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - add_row_to_table.position / add_column_to_table.position
    // (no validation at all — even an unrecognized VALUE silently becomes "end")

    private func docIdWithOneTable(_ server: WordMCPServer, docId: String) async {
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(docId)])
        _ = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(docId), "rows": .int(2), "cols": .int(2)]
        )
    }

    func testAddRowToTableRejectsWrongTypePosition() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-art-a")
        let r = await server.invokeToolForTesting(
            name: "add_row_to_table", arguments: ["doc_id": .string("i253-art-a"), "table_index": .int(0), "position": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "position: 5 must be rejected. Got: \(textOf(r))")
    }

    func testAddRowToTableRejectsUnrecognizedPositionValue() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-art-b")
        let r = await server.invokeToolForTesting(
            name: "add_row_to_table", arguments: ["doc_id": .string("i253-art-b"), "table_index": .int(0), "position": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "position: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    func testAddColumnToTableRejectsWrongTypePosition() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-act-a")
        let r = await server.invokeToolForTesting(
            name: "add_column_to_table", arguments: ["doc_id": .string("i253-act-a"), "table_index": .int(0), "position": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "position: 5 must be rejected. Got: \(textOf(r))")
    }

    func testAddColumnToTableRejectsUnrecognizedPositionValue() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-act-b")
        let r = await server.invokeToolForTesting(
            name: "add_column_to_table", arguments: ["doc_id": .string("i253-act-b"), "table_index": .int(0), "position": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "position: 'bogus' must be rejected. Got: \(textOf(r))")
    }

    // MARK: - set_cell_width.width_type / set_row_height.height_rule
    // (value already rejected via RawRepresentable(rawValue:); type is not)

    func testSetCellWidthRejectsWrongTypeWidthType() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-scw")
        let r = await server.invokeToolForTesting(
            name: "set_cell_width",
            arguments: ["doc_id": .string("i253-scw"), "table_index": .int(0), "row": .int(0), "col": .int(0), "width": .int(1000), "width_type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "width_type: 5 must be rejected. Got: \(textOf(r))")
    }

    func testSetRowHeightRejectsWrongTypeHeightRule() async throws {
        let server = await WordMCPServer()
        await docIdWithOneTable(server, docId: "i253-srh")
        let r = await server.invokeToolForTesting(
            name: "set_row_height",
            arguments: ["doc_id": .string("i253-srh"), "table_index": .int(0), "row_index": .int(0), "height": .int(400), "height_rule": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "height_rule: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - Regression guards: valid values must still work after the fix

    func testAllFixedToolsStillAcceptValidValues() async throws {
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i253-reg")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: ["doc_id": .string("i253-reg"), "text": .string("Hello world")])

        let createStyle = await server.invokeToolForTesting(
            name: "create_style",
            arguments: ["doc_id": .string("i253-reg"), "style_id": .string("ValidStyle"), "name": .string("Valid"), "type": .string("character")]
        )
        XCTAssertNotEqual(createStyle.isError, true, textOf(createStyle))

        let sectionBreak = await server.invokeToolForTesting(
            name: "insert_section_break", arguments: ["doc_id": .string("i253-reg"), "type": .string("continuous")]
        )
        XCTAssertNotEqual(sectionBreak.isError, true, textOf(sectionBreak))

        let dropCap = await server.invokeToolForTesting(
            name: "insert_drop_cap", arguments: ["doc_id": .string("i253-reg"), "paragraph_index": .int(0), "type": .string("drop")]
        )
        XCTAssertNotEqual(dropCap.isError, true, textOf(dropCap))

        let hLine = await server.invokeToolForTesting(
            name: "insert_horizontal_line", arguments: ["doc_id": .string("i253-reg"), "paragraph_index": .int(0), "style": .string("dashed")]
        )
        XCTAssertNotEqual(hLine.isError, true, textOf(hLine))

        let lineNumbers = await server.invokeToolForTesting(
            name: "set_line_numbers", arguments: ["doc_id": .string("i253-reg"), "enable": .bool(true), "restart": .string("newPage")]
        )
        XCTAssertNotEqual(lineNumbers.isError, true, textOf(lineNumbers))
    }
}
