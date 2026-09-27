import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#237 — `estimate_paragraph_for_page`'s
/// `estimateCharsPerPage` subtracts/multiplies the document's OWN
/// `sectionProperties.pageSize`/`pageMargins` with no range check.
/// `set_page_margins`/`set_page_size` validate at the TOOL-INPUT boundary
/// (#234), but that does not protect this path: a `.docx` can carry an
/// out-of-range `<w:pgSz w:w="...">` that no che-word-mcp tool ever wrote
/// (hand-edited XML, or — as here — a value set directly through the
/// underlying ooxml-swift model, which has no such gate). `Int`
/// subtraction/multiplication TRAPS on overflow in Swift — an uncatchable
/// crash that kills the whole MCP server process (every other open
/// document's unsaved edits go with it), triggered merely by CALLING a
/// read-only estimation tool on a document that was just opened normally.
final class Issue237EstimateParagraphForPagePageSizeOverflowTests: XCTestCase {

    /// One-paragraph fixture whose section has an out-of-range
    /// `pageSize.width`/`height` — mirrors hand-editing `<w:pgSz w:w="...">`
    /// to an extreme value (#237's own repro), but goes through the real
    /// writer/reader round-trip (ooxml-swift's `PageSize` is a plain `Int`
    /// with no range check of its own) instead of raw zip surgery.
    private func docxWithPageSize(width: Int, height: Int) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello")])))
        doc.sectionProperties.pageSize = PageSize(width: width, height: height)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue237_pagesize_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// RED (pre-fix): `width: Int.max, height: Int.max` against default
    /// (1440 twips) margins does not overflow the SUBTRACTION
    /// (`pageSize.width - margins...` stays a huge but valid positive
    /// `Int`), but does overflow the downstream MULTIPLICATION
    /// (`charsPerLine * linesPerPage`, both derived from a ~1e16-scale
    /// usable-area value) — `Int * Int` traps in Swift, crashing the whole
    /// test process (and, in production, the whole MCP server).
    func testExtremePositivePageSizeDoesNotCrashEstimateParagraphForPage() async throws {
        let url = try docxWithPageSize(width: Int.max, height: Int.max)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        let r = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Error"),
            "an out-of-range pageSize must return a structured error, not crash or silently succeed; got: \(txt)"
        )
    }

    /// RED (pre-fix): `width: Int.min` against default (1440 twips)
    /// margins underflows the SUBTRACTION directly
    /// (`Int.min - 1440 - 1440 - 0`) — the exact shape of #237's own repro
    /// (`<w:pgSz w:w="-9223372036854775808">`), just reached via the typed
    /// model instead of hand-edited XML.
    func testExtremeNegativePageSizeDoesNotCrashEstimateParagraphForPage() async throws {
        let url = try docxWithPageSize(width: Int.min, height: 15840)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        let r = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Error"),
            "an out-of-range negative pageSize must return a structured error, not crash; got: \(txt)"
        )
    }

    /// A document with realistic page geometry (the writer's own
    /// `.letter`/`.normal` defaults) must still produce a normal estimate —
    /// the new range check must not reject ordinary documents.
    func testOrdinaryPageSizeStillProducesAnEstimate() async throws {
        let url = try docxWithPageSize(width: PageSize.letter.width, height: PageSize.letter.height)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        let r = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let txt = textOf(r)
        XCTAssertFalse(txt.contains("Error"), "an ordinary Letter-size document must not be rejected; got: \(txt)")
        XCTAssertTrue(txt.contains("estimated_paragraph_range"), "expected a normal estimate payload; got: \(txt)")
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
