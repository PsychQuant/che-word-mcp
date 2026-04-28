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

    // MARK: - v3.15.2 polish (PsychQuant/che-word-mcp#69 + #73)

    /// #73: regression pin for F5 guard on insert_equation. Code path was added
    /// in v3.15.1 alongside paragraph + image_from_path, but the test sweep only
    /// covered the latter two. Pins Server.swift:8762 partial-dict guard.
    func testInsertEquationMalformedIntoTableCellReportsError() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_eq_malformed_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61mal")]
        )

        // Pass into_table_cell with only table_index — missing row + col.
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61mal"),
                "latex": .string("x^2"),
                "display_mode": .bool(true),
                "into_table_cell": .object([
                    "table_index": .int(0)
                ])
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("into_table_cell") || txt.contains("missing"),
            "malformed into_table_cell on insert_equation should return structured error; got: \(txt)"
        )
    }

    /// #69: insert_paragraph append branch reported `getParagraphs().count - 1`,
    /// which skips tables and SDTs — so in a doc like `[para, table, para]` an
    /// append says "at index 2" but the actual body.children index is 3. The
    /// reported number can't round-trip as `paragraph_index` for subsequent
    /// inserts because `Document.insertParagraph(_:at:Int)` interprets its int
    /// as a body.children index (Document.swift:266-270).
    /// Fix in Server.swift:6659 — use `body.children.count - 1`.
    func testInsertParagraphAppendMessageUsesBodyChildrenIndex() async throws {
        var doc = WordDocument()
        // Body layout: [para, table, para] → body.children.count = 3,
        // getParagraphs() = [para, para] (table skipped) → count = 2.
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before-table")])))
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])
        doc.body.children.append(.table(table))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "after-table")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue69_append_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p69app")]
        )

        // Append: no anchor, no index → falls through to appendParagraph branch.
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p69app"),
                "text": .string("APPENDED")
            ]
        )
        XCTAssertFalse(r.isError == true, "append should succeed; got: \(r.content)")
        let msg = textOf(r)
        // After append, body.children.count = 4, so the new paragraph is at body
        // index 3. Pre-fix message reported "at index 2" (getParagraphs().count - 1
        // because table was skipped). Post-fix should report "at index 3".
        XCTAssertTrue(
            msg.contains("at index 3"),
            "append message should report body.children index of new paragraph (expected 'at index 3' for [para, table, para] + append); got: \(msg)"
        )
        XCTAssertFalse(
            msg.contains("at index 2"),
            "append message must NOT use getParagraphs().count - 1 (would be 2 here, skipping the table); got: \(msg)"
        )
    }

    // MARK: - v3.15.3 follow-ups (PsychQuant/che-word-mcp #78 + #79)

    /// #78: extend #69's [para, table, para] pin to bookmarkMarker / rawBlockElement /
    /// contentControl body-children. `getParagraphs()` (lib `Document.swift:205-228`) skips
    /// ALL non-paragraph BodyChild variants, not just .table; a future regression that
    /// re-introduces `getParagraphs().count - 1` would silently break in docs containing
    /// SDTs / TOC bookmark anchors / vendor extensions even if the table case still passes.

    func testInsertParagraphAppendMessageWithBookmarkMarker() async throws {
        var doc = WordDocument()
        // Body layout: [para, .bookmarkMarker, para] → body.children.count = 3,
        // getParagraphs() = [para, para] (marker skipped) → count = 2.
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before-marker")])))
        doc.body.children.append(.bookmarkMarker(BookmarkRangeMarker(kind: .start, id: 1, position: 0)))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "after-marker")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue78_bookmark_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p78bm")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p78bm"), "text": .string("APPENDED")]
        )
        XCTAssertFalse(r.isError == true, "append should succeed; got: \(r.content)")
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("at index 3"),
            "append message should report body.children index across bookmarkMarker (expected 'at index 3'); got: \(msg)"
        )
        XCTAssertFalse(
            msg.contains("at index 2"),
            "append message must NOT use getParagraphs().count - 1 (would skip bookmarkMarker); got: \(msg)"
        )
    }

    func testInsertParagraphAppendMessageWithRawBlockElement() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before-raw")])))
        // .rawBlockElement is the catch-all for unrecognized body-level XML
        // (vendor extensions, EG_BlockLevelElts members not specifically parsed).
        doc.body.children.append(.rawBlockElement(RawElement(
            name: "moveFromRangeStart",
            xml: "<w:moveFromRangeStart xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" w:id=\"42\"/>"
        )))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "after-raw")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue78_raw_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p78raw")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p78raw"), "text": .string("APPENDED")]
        )
        XCTAssertFalse(r.isError == true, "append should succeed; got: \(r.content)")
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("at index 3"),
            "append message should report body.children index across rawBlockElement (expected 'at index 3'); got: \(msg)"
        )
        XCTAssertFalse(
            msg.contains("at index 2"),
            "append message must NOT use getParagraphs().count - 1 (would skip rawBlockElement); got: \(msg)"
        )
    }

    func testInsertParagraphAppendMessageWithBlockContentControl() async throws {
        var doc = WordDocument()
        // Block-level SDT wrapping a paragraph: body.children.count counts the .contentControl
        // as one entry, but getParagraphs() recursively descends into the SDT children, so
        // SDT-wrapped paragraphs ARE counted (see Document.swift:215-220).
        // For a meaningful pin we use an empty SDT wrapper (children=[]) that is counted by
        // body.children but contributes 0 to getParagraphs.
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "before-sdt")])))
        let blockSdt = StructuredDocumentTag(
            id: 9001,
            tag: "test_wrapper",
            alias: "Test Wrapper",
            type: .richText
        )
        let control = ContentControl(sdt: blockSdt, content: "")
        doc.body.children.append(.contentControl(control, children: []))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "after-sdt")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue78_sdt_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p78sdt")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p78sdt"), "text": .string("APPENDED")]
        )
        XCTAssertFalse(r.isError == true, "append should succeed; got: \(r.content)")
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("at index 3"),
            "append message should report body.children index across empty block-level SDT (expected 'at index 3'); got: \(msg)"
        )
        XCTAssertFalse(
            msg.contains("at index 2"),
            "append message must NOT use getParagraphs().count - 1 (would skip empty SDT); got: \(msg)"
        )
    }

    /// #79: round-trip depth — verify the reported index actually round-trips
    /// as `paragraph_index` for a SUBSEQUENT insert_paragraph call. Pre-#69 fix,
    /// the message lied about which index the lib's body.children-indexed
    /// `insertParagraph(_:at:Int)` would interpret. This test demonstrates the
    /// full append-then-insert pipeline works.

    func testInsertParagraphAppendIndexRoundTripsForInsertCalls() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "FIRST")])))
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])
        doc.body.children.append(.table(table))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "SECOND")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue79_rt_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p79rt")]
        )

        // Step 1: append APPENDED, message should report "at index 3".
        let r1 = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p79rt"), "text": .string("APPENDED")]
        )
        XCTAssertFalse(r1.isError == true, "append should succeed")
        let msg1 = textOf(r1)
        XCTAssertTrue(msg1.contains("at index 3"), "expected reported index 3; got: \(msg1)")

        // Step 2: use the reported body.children index (3) + 1 = 4 to insert
        // immediately after the appended paragraph. Since insertParagraph(_:at:Int)
        // clamps at body.children.count, an index of 4 (current count) appends
        // at the very end — which is the body index AFTER our just-appended para.
        let r2 = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p79rt"),
                "text": .string("AFTER_APPENDED"),
                "index": .int(4)
            ]
        )
        XCTAssertFalse(r2.isError == true, "round-trip insert should succeed; got: \(r2.content)")

        // Step 3: verify body order via get_paragraphs.
        let r3 = await server.invokeToolForTesting(
            name: "get_paragraphs",
            arguments: ["doc_id": .string("p79rt")]
        )
        let paras = textOf(r3)
        // Expected ordering: FIRST → (table skipped) → SECOND → APPENDED → AFTER_APPENDED
        XCTAssertTrue(paras.contains("FIRST"), "FIRST missing from get_paragraphs output: \(paras)")
        XCTAssertTrue(paras.contains("SECOND"), "SECOND missing")
        XCTAssertTrue(paras.contains("APPENDED"), "APPENDED missing")
        XCTAssertTrue(paras.contains("AFTER_APPENDED"), "AFTER_APPENDED missing")
        // Verify AFTER_APPENDED comes after APPENDED.
        if let posApp = paras.range(of: "APPENDED")?.lowerBound,
           let posAfter = paras.range(of: "AFTER_APPENDED")?.lowerBound {
            XCTAssertLessThan(
                posApp, posAfter,
                "AFTER_APPENDED should appear after APPENDED in body order; got: \(paras)"
            )
        } else {
            XCTFail("could not locate APPENDED / AFTER_APPENDED in: \(paras)")
        }
    }

    /// #79 negative: pin the cross-family trade-off acknowledged in v3.15.2 CHANGELOG
    /// (also tracked as PsychQuant/ooxml-swift#10). The reported index works for
    /// `insert_paragraph(index=)` but NOT for `update_paragraph(index=)` because the
    /// latter uses paragraph-only count via `Document.bodyIndexForParagraph`.

    func testInsertParagraphAppendIndexCannotRoundTripToUpdate() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "FIRST")])))
        let table = Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])
        doc.body.children.append(.table(table))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "SECOND")])))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue79_xfam_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p79xf")]
        )

        // Append: body.children grows from 3 to 4; reported index = 3.
        let r1 = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p79xf"), "text": .string("APPENDED")]
        )
        XCTAssertFalse(r1.isError == true)
        let msg1 = textOf(r1)
        XCTAssertTrue(msg1.contains("at index 3"), "expected 'at index 3'; got: \(msg1)")

        // Try to update_paragraph(index=3) — interprets 3 as paragraph-only index,
        // but the doc only has 3 paragraphs (FIRST + SECOND + APPENDED at indices 0/1/2).
        // Index 3 is out-of-range for paragraph-only count → throws WordError.invalidIndex.
        let r2 = await server.invokeToolForTesting(
            name: "update_paragraph",
            arguments: [
                "doc_id": .string("p79xf"),
                "index": .int(3),
                "text": .string("WONT_LAND")
            ]
        )
        XCTAssertTrue(
            r2.isError == true,
            "update_paragraph should fail with cross-family index — pinning the trade-off acknowledged in v3.15.2 CHANGELOG / PsychQuant/ooxml-swift#10. Got non-error: \(r2.content)"
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
