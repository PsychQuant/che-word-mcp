import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#215 — the #201/#172 "stub family" (回報成功但東西不在)
/// has a variant where the tool DID try to do real work, storeDocument()'d
/// unconditionally, and only then noticed nothing had actually changed:
///
/// - `set_table_style` with no recognized style arguments: storeDocument(),
///   then return "No style changes applied" — a success string, `isError`
///   unset, so #202's sweep can never see it.
/// - `splice_paragraph_omath_from_source` when the source paragraph has no
///   OMath at all: the library-level batch splice returns `0` as a graceful
///   no-op (intentional, for driver loops), and the wrapper storeDocument()'d
///   and reported "Spliced 0 OMath block(s)" as if that were success — and,
///   because the library only validates `target_paragraph_index` from inside
///   the per-OMath splice call (never reached on the 0-OMath path), an
///   out-of-range target index sailed through too.
///
/// Both are fixed to refuse (ToolRefusal → `isError: true`) instead of
/// persisting a no-op and claiming success.
final class Issue215FalseSuccessTests: XCTestCase {

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func makeTableFixture() throws -> URL {
        var doc = WordDocument()
        let cell = TableCell(paragraphs: [Paragraph(text: "cell")])
        let row = TableRow(cells: [cell])
        let table = Table(rows: [row])
        doc.body.children.append(.table(table))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue215-table-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private static let mNS = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""

    private func makeSourceDocxWithInlineOMath() throws -> URL {
        var doc = WordDocument()
        var run1 = Run(text: "所得出的參數進行 ")
        run1.position = 1
        var run2 = Run(text: "")
        run2.rawXML = "<m:oMath \(Self.mNS)><m:r><m:t>t</m:t></m:r></m:oMath>"
        run2.position = 2
        let para = Paragraph(runs: [run1, run2])
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue215-omath-source-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func makeSourceDocxWithoutOMath() throws -> URL {
        var doc = WordDocument()
        var run = Run(text: "plain prose, no math here")
        run.position = 1
        doc.body.children.append(.paragraph(Paragraph(runs: [run])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue215-no-omath-source-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Two-paragraph target — used so `target_paragraph_index: 99` is
    /// unambiguously out of range.
    private func makeTwoParagraphTargetDocx() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(text: "para 0")))
        doc.body.children.append(.paragraph(Paragraph(text: "para 1")))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue215-target-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - set_table_style

    /// No style arguments at all → refuse, not "No style changes applied".
    func testSetTableStyleWithNoArgumentsRefuses() async throws {
        let fixture = try makeTableFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("ts1")])

        let r = await server.invokeToolForTesting(
            name: "set_table_style",
            arguments: ["doc_id": .string("ts1"), "table_index": .int(0)])
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true,
            "set_table_style with no style args SHALL fail, not report 'No style changes applied'. Got: \(txt)")
        XCTAssertFalse(txt.contains("No style changes applied"),
            "the old false-success string must not reappear. Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("ts1"), "discard_changes": .bool(true)])
    }

    /// `shading_color` given without `cell_row`/`cell_col` never activates the
    /// shading branch either — same "no recognized style change" shape.
    func testSetTableStyleWithOnlyShadingColorRefuses() async throws {
        let fixture = try makeTableFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("ts2")])

        let r = await server.invokeToolForTesting(
            name: "set_table_style",
            arguments: [
                "doc_id": .string("ts2"), "table_index": .int(0),
                "shading_color": .string("FF0000")
            ])
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true,
            "set_table_style with only shading_color (no cell_row/cell_col) SHALL fail. Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("ts2"), "discard_changes": .bool(true)])
    }

    /// A real style change (border) still succeeds — the fix must not break
    /// the working path.
    func testSetTableStyleWithBorderStillSucceeds() async throws {
        let fixture = try makeTableFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("ts3")])

        let r = await server.invokeToolForTesting(
            name: "set_table_style",
            arguments: [
                "doc_id": .string("ts3"), "table_index": .int(0),
                "border_style": .string("single")
            ])
        let txt = textOf(r)
        XCTAssertNotEqual(r.isError, true,
            "a real border change SHALL still succeed. Got: \(txt)")
        XCTAssertTrue(txt.contains("Set border style"), "Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("ts3"), "discard_changes": .bool(true)])
    }

    // MARK: - splice_paragraph_omath_from_source

    /// Source paragraph has no OMath at all → refuse, not "Spliced 0 OMath block(s)".
    func testSpliceParagraphOMathFromSourceWithNoOMathInSourceRefuses() async throws {
        let sourceURL = try makeSourceDocxWithoutOMath()
        let targetURL = try makeTwoParagraphTargetDocx()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("sp1")])

        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("sp1"),
                "target_paragraph_index": .int(0)
            ])
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true,
            "no OMath in source SHALL fail, not report 'Spliced 0 OMath block(s)'. Got: \(txt)")
        XCTAssertFalse(txt.contains("Spliced 0 OMath"),
            "the old false-success string must not reappear. Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("sp1"), "discard_changes": .bool(true)])
    }

    /// Out-of-range target_paragraph_index must fail EVEN when the source also
    /// has no OMath — this is exactly the path the library skips validation on.
    func testSpliceParagraphOMathFromSourceOutOfRangeTargetRefusesEvenWithNoOMathSource() async throws {
        let sourceURL = try makeSourceDocxWithoutOMath()
        let targetURL = try makeTwoParagraphTargetDocx()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("sp2")])

        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("sp2"),
                "target_paragraph_index": .int(99)
            ])
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true,
            "target_paragraph_index=99 on a 2-paragraph document SHALL fail. Got: \(txt)")
        XCTAssertTrue(txt.lowercased().contains("out of range"),
            "expected 'out of range' in the refusal. Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("sp2"), "discard_changes": .bool(true)])
    }

    /// Out-of-range target_paragraph_index must ALSO fail when the source DOES
    /// have OMath (the path that already reached the library's own check —
    /// pinning it stays correct after the wrapper's own pre-check is added).
    func testSpliceParagraphOMathFromSourceOutOfRangeTargetRefusesWithOMathSource() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTwoParagraphTargetDocx()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("sp3")])

        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("sp3"),
                "target_paragraph_index": .int(99)
            ])
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true,
            "target_paragraph_index=99 SHALL fail even when source has OMath. Got: \(txt)")
        XCTAssertTrue(txt.lowercased().contains("out of range"), "Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("sp3"), "discard_changes": .bool(true)])
    }

    /// A real batch splice still succeeds — the fix must not break the working path.
    func testSpliceParagraphOMathFromSourceStillSucceeds() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTwoParagraphTargetDocx()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("sp4")])

        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("sp4"),
                "target_paragraph_index": .int(0)
            ])
        let txt = textOf(r)
        XCTAssertNotEqual(r.isError, true, "a real splice SHALL still succeed. Got: \(txt)")
        XCTAssertTrue(txt.contains("Spliced 1 OMath block"), "Got: \(txt)")

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("sp4"), "discard_changes": .bool(true)])
    }
}
