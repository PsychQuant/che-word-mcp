import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// che-word-mcp#184 — `restrict_editing_region` was grouped with the other
/// four protection tools in #172 (validates arguments, then throws
/// `ToolNotImplemented`) even though the OOXML it needs
/// (`Paragraph.permissionRangeMarkers`, ooxml-swift #56 Phase 4) already
/// round-trips — nothing upstream was missing, only the server-side handler
/// that creates the markers.
///
/// Per the issue's own Acceptance section, every assertion here reads the
/// SAVED `word/document.xml` (via `RawPartChannel`, the same reader
/// `ScriptPipelineParityTests` uses for byte-level checks) rather than the
/// typed model, and the three "reject rather than silently clamp" cases
/// (start_paragraph == 0, a range spanning a table, an inverted range) each
/// get their own test.
final class Issue184RestrictEditingRegionTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i184-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A 4-paragraph document ("p0".."p3"), opened as `docId`, saved to a
    /// scratch path handed back for direct XML inspection.
    private func openFourParagraphDoc(_ server: WordMCPServer, docId: String, in dir: URL) async throws -> URL {
        var doc = WordDocument()
        for i in 0..<4 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p\(i)")])))
        }
        let url = dir.appendingPathComponent("\(docId).docx")
        try DocxWriter.write(doc, to: url)
        let open = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)])
        XCTAssertFalse(textOf(open).hasPrefix("Error"), "open failed: \(textOf(open))")
        return url
    }

    private func documentXML(at url: URL) throws -> String {
        let parts = try RawPartChannel.readAllParts(from: url)
        return String(decoding: parts["word/document.xml"] ?? Data(), as: UTF8.self)
    }

    // MARK: - Success path, verified against the saved document.xml

    func testRestrictsRegionAndWritesPermStartPermEndAroundIt() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        let url = try await openFourParagraphDoc(server, docId: "d1", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d1"),
                        "start_paragraph": .int(1), "end_paragraph": .int(2),
                        "editor": .string("che")])
        XCTAssertFalse(textOf(result).hasPrefix("Error"), "restrict_editing_region failed: \(textOf(result))")

        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("d1")])
        XCTAssertFalse(textOf(save).hasPrefix("Error"), "save failed: \(textOf(save))")

        let xml = try documentXML(at: url)
        XCTAssertTrue(xml.contains("<w:permStart"), "document.xml must carry <w:permStart>: \(xml)")
        XCTAssertTrue(xml.contains("<w:permEnd"), "document.xml must carry <w:permEnd>: \(xml)")
        XCTAssertTrue(xml.contains("w:ed=\"che\""), "the named editor must reach w:ed: \(xml)")
        XCTAssertFalse(xml.contains("w:edGrp"), "an explicit editor must not also carry a group")

        // permStart lands after p0 (the preceding paragraph) and before p1;
        // permEnd lands after p2 (the last paragraph IN the region) and
        // before p3 — so document order is: p0, permStart, p1, p2, permEnd, p3.
        func index(of needle: String) -> String.Index {
            xml.range(of: needle)!.lowerBound
        }
        XCTAssertLessThan(index(of: ">p0<"), index(of: "<w:permStart"))
        XCTAssertLessThan(index(of: "<w:permStart"), index(of: ">p1<"))
        XCTAssertLessThan(index(of: ">p1<"), index(of: ">p2<"))
        XCTAssertLessThan(index(of: ">p2<"), index(of: "<w:permEnd"))
        XCTAssertLessThan(index(of: "<w:permEnd"), index(of: ">p3<"))

        // The two markers share one id (a real permStart/permEnd pair).
        let startId = try XCTUnwrap(xml.range(of: #"<w:permStart w:id="(\d+)""#, options: .regularExpression))
        let endId = try XCTUnwrap(xml.range(of: #"<w:permEnd w:id="(\d+)""#, options: .regularExpression))
        func idDigits(_ range: Range<String.Index>) -> String {
            xml[range].filter(\.isNumber)
        }
        XCTAssertEqual(idDigits(startId), idDigits(endId))
    }

    func testDefaultsToEveryoneGroupWhenNeitherEditorNorGroupGiven() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        let url = try await openFourParagraphDoc(server, docId: "d2", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d2"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1)])
        XCTAssertFalse(textOf(result).hasPrefix("Error"), textOf(result))
        _ = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("d2")])

        let xml = try documentXML(at: url)
        XCTAssertTrue(xml.contains("w:edGrp=\"everyone\""), "default must be w:edGrp=\"everyone\": \(xml)")
    }

    func testEditorGroupIsHonoredWhenGivenExplicitly() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        let url = try await openFourParagraphDoc(server, docId: "d3", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d3"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1),
                        "editor_group": .string("contributors")])
        XCTAssertFalse(textOf(result).hasPrefix("Error"), textOf(result))
        _ = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("d3")])

        let xml = try documentXML(at: url)
        XCTAssertTrue(xml.contains("w:edGrp=\"contributors\""), xml)
    }

    /// Two non-overlapping calls in the same session must not collide on id.
    func testSecondCallGetsANonCollidingId() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        let url = try await openFourParagraphDoc(server, docId: "d4", in: dir)

        let first = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d4"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1)])
        XCTAssertFalse(textOf(first).hasPrefix("Error"), textOf(first))
        let second = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d4"),
                        "start_paragraph": .int(2), "end_paragraph": .int(2)])
        XCTAssertFalse(textOf(second).hasPrefix("Error"), textOf(second))
        _ = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string("d4")])

        let xml = try documentXML(at: url)
        let starts = xml.components(separatedBy: "<w:permStart").count - 1
        let ends = xml.components(separatedBy: "<w:permEnd").count - 1
        XCTAssertEqual(starts, 2, "two calls must produce two permStart markers: \(xml)")
        XCTAssertEqual(ends, 2, "two calls must produce two permEnd markers: \(xml)")

        let ids = xml.matches(of: try! Regex(#"<w:permStart w:id="(\d+)""#))
            .map { String(xml[$0.range]) }
        XCTAssertEqual(Set(ids).count, ids.count, "permStart ids must be pairwise distinct: \(ids)")
    }

    // MARK: - Explicit rejections (reject rather than silently clamp/guess)

    func testRejectsStartParagraphZero() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        _ = try await openFourParagraphDoc(server, docId: "d5", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d5"),
                        "start_paragraph": .int(0), "end_paragraph": .int(1)])
        XCTAssertEqual(result.isError, true, "start_paragraph == 0 must be refused, not approximated")
        XCTAssertTrue(textOf(result).contains("start_paragraph"), textOf(result))
    }

    func testRejectsInvertedRange() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        _ = try await openFourParagraphDoc(server, docId: "d6", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d6"),
                        "start_paragraph": .int(2), "end_paragraph": .int(1)])
        XCTAssertEqual(result.isError, true, "an inverted range must be refused")
    }

    func testRejectsRangeSpanningATable() async throws {
        let dir = try makeScratch()
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p0")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p1")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p2")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p3")])))
        let url = dir.appendingPathComponent("d7.docx")
        try DocxWriter.write(doc, to: url)

        let server = await WordMCPServer()
        let open = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d7")])
        XCTAssertFalse(textOf(open).hasPrefix("Error"), textOf(open))

        // getParagraphs() flattens to [p0, p1, p2, p3] (indices 0..3); a
        // table sits between flattened index 1 (p1) and 2 (p2) in real body
        // order even though they look adjacent in that flattened space.
        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d7"),
                        "start_paragraph": .int(1), "end_paragraph": .int(2)])
        XCTAssertEqual(result.isError, true, "a range spanning a table must be refused: \(textOf(result))")
    }

    /// R2 (independent review, HIGH finding): `<w:permStart>` is anchored to
    /// the END of the PRECEDING paragraph (`start_paragraph - 1`), so the
    /// actual marked-editable span begins at the body-order GAP between
    /// that anchor and `start_paragraph` — not at `start_paragraph` itself.
    /// A table sitting in exactly that gap is document-flow-INSIDE the
    /// range even though it is outside the caller's requested window.
    /// Structure: `[p0, TABLE, p1, p2, p3]` → `getParagraphs()` flattens to
    /// `[p0, p1, p2, p3]` (indices 0..3); requesting `[1, 2]` anchors
    /// `<w:permStart>` to p0 (index 0), and the table sits exactly between
    /// p0 and p1 — inside the anchor-to-end span, must be refused.
    func testRejectsRangeWhereTableSitsBetweenTheAnchorAndTheStartParagraph() async throws {
        let dir = try makeScratch()
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p0")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p1")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p2")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p3")])))
        let url = dir.appendingPathComponent("d-anchor-gap.docx")
        try DocxWriter.write(doc, to: url)

        let server = await WordMCPServer()
        let open = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d-anchor-gap")])
        XCTAssertFalse(textOf(open).hasPrefix("Error"), textOf(open))

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d-anchor-gap"),
                        "start_paragraph": .int(1), "end_paragraph": .int(2)])
        XCTAssertEqual(result.isError, true,
                       "a table between the permStart anchor (start_paragraph - 1) and start_paragraph "
                       + "must be refused — it is inside the actual marked range: \(textOf(result))")
    }

    func testAdjacentRangeNotCrossingTheTableStillSucceeds() async throws {
        let dir = try makeScratch()
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p0")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p1")])))
        doc.body.children.append(.table(Table(rows: [
            TableRow(cells: [TableCell(paragraphs: [Paragraph(runs: [Run(text: "cell")])])])
        ])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p2")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "p3")])))
        let url = dir.appendingPathComponent("d8.docx")
        try DocxWriter.write(doc, to: url)

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d8")])

        // [1, 1] (just p1) does not cross the table.
        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d8"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1)])
        XCTAssertFalse(textOf(result).hasPrefix("Error"), textOf(result))
        XCTAssertNotEqual(result.isError, true, textOf(result))
    }

    // MARK: - editor / editor_group mapping (asserted, not assumed)

    func testRejectsBothEditorAndEditorGroup() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        _ = try await openFourParagraphDoc(server, docId: "d9", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d9"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1),
                        "editor": .string("che"), "editor_group": .string("everyone")])
        XCTAssertEqual(result.isError, true, "editor + editor_group together must be refused, not silently resolved")
    }

    func testRejectsUnknownEditorGroup() async throws {
        let dir = try makeScratch()
        let server = await WordMCPServer()
        _ = try await openFourParagraphDoc(server, docId: "d10", in: dir)

        let result = await server.invokeToolForTesting(
            name: "restrict_editing_region",
            arguments: ["doc_id": .string("d10"),
                        "start_paragraph": .int(1), "end_paragraph": .int(1),
                        "editor_group": .string("nonsense")])
        XCTAssertEqual(result.isError, true, "an unknown w:edGrp value must be refused, not passed through")
    }
}
