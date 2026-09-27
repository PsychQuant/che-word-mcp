import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#143 — `estimate_paragraph_for_page`'s confidence
/// labeling had two problems:
///
/// 1. **Semantic inversion**: a caller who provided their own measured
///    `chars_per_page` (more trustworthy than the server's own guess) was
///    scored the SAME as — or lower than — the default heuristic, because
///    the pre-fix branch only granted `"medium"` when `layout_basis ==
///    "section_properties"`. Caller calibration could never reach
///    `"medium"`, let alone anything higher.
/// 2. **No `"high"` tier existed at all** — the field was binary
///    (`"medium"`/`"low"`), so there was no way to signal "this estimate is
///    unusually trustworthy" even when a caller supplied ground-truth
///    calibration.
///
/// This file pins the corrected ordering (see `estimateParagraphForPage`'s
/// confidence block): "beyond the estimated document" always wins (it's
/// unreliable no matter how `chars_per_page` was obtained), then
/// caller-provided calibration is `"high"`, then default-heuristic
/// long/simple documents are `"medium"`, and everything else defaults to
/// `"low"` with a `confidence_reason` naming which case applied.
final class Issue143ConfidenceCalibrationTests: XCTestCase {

    // MARK: - high: caller calibration

    func testCallerProvidedCharsPerPageYieldsHighConfidenceEvenWithComplexLayout() async throws {
        // Tables present (complex layout) — under the DEFAULT heuristic this
        // would be "low", but caller calibration must still win.
        let url = try docxWithTextAndTables(textCount: 10, textChars: 40, tableCount: 2, tableRows: 3, tableCols: 2, cellChars: 20)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(5000),
            ]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["confidence"] as? String, "high", textOf(result))
        XCTAssertEqual(json["confidence_reason"] as? String, "caller_provided_chars_per_page", textOf(result))
    }

    // MARK: - medium: default heuristic, simple layout, long enough document

    func testDefaultHeuristicSimpleLongDocumentYieldsMediumConfidence() async throws {
        // 30 plain-text paragraphs, no chars_per_page override (default
        // heuristic derived from section_properties), no tables/images/
        // display equations. paragraph_count (30) >= 10.
        let url = try docxWithTextParagraphs(count: 30, chars: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["layout_basis"] as? String, "section_properties", textOf(result))
        XCTAssertEqual(json["confidence"] as? String, "medium", textOf(result))
        XCTAssertEqual(json["confidence_reason"] as? String, "default_heuristic_simple_layout", textOf(result))
    }

    // MARK: - low: default heuristic, short document

    func testDefaultHeuristicShortDocumentYieldsLowConfidence() async throws {
        // Only 5 paragraphs (< 10) — too short for the char-count noise to
        // average out, even though the layout is simple.
        let url = try docxWithTextParagraphs(count: 5, chars: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["confidence"] as? String, "low", textOf(result))
        XCTAssertEqual(json["confidence_reason"] as? String, "short_doc_or_fallback_layout", textOf(result))
    }

    // MARK: - low: default heuristic, complex layout

    func testDefaultHeuristicComplexLayoutYieldsLowConfidence() async throws {
        // 20 text paragraphs + 3 tables, no chars_per_page override.
        // paragraph_count (20) >= 10 but tables make the layout "complex" —
        // structural weights (#142) are the roughest approximations in the
        // whole heuristic, so this must stay "low" even though the document
        // is long enough to otherwise qualify for "medium".
        let url = try docxWithTextAndTables(textCount: 20, textChars: 50, tableCount: 3, tableRows: 3, tableCols: 2, cellChars: 20)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["confidence"] as? String, "low", textOf(result))
        XCTAssertEqual(json["confidence_reason"] as? String, "complex_layout_default_heuristic", textOf(result))
    }

    // MARK: - low: beyond estimated document outranks caller calibration

    func testBeyondEstimatedDocumentYieldsLowConfidenceEvenWithCallerCalibration() async throws {
        let url = try docxWithTextParagraphs(count: 5, chars: 99)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(50),
                "chars_per_page": .int(100),
            ]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["requested_page_beyond_estimated_document"] as? Bool, true, textOf(result))
        XCTAssertEqual(json["confidence"] as? String, "low", textOf(result))
        XCTAssertEqual(json["confidence_reason"] as? String, "beyond_estimated_document", textOf(result))
    }

    // MARK: - Fixture builders (mirrors Issue142's helpers; kept local/private

    // to avoid cross-file coupling between test targets)

    private func docxWithTextParagraphs(count: Int, chars: Int) throws -> URL {
        var doc = WordDocument()
        let text = String(repeating: "x", count: chars)
        for _ in 0..<count {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        }
        return try writeFixture(doc, prefix: "issue143_text")
    }

    private func docxWithTextAndTables(textCount: Int, textChars: Int,
                                        tableCount: Int, tableRows: Int,
                                        tableCols: Int, cellChars: Int) throws -> URL {
        var doc = WordDocument()
        let textPara = String(repeating: "x", count: textChars)
        let cellText = String(repeating: "c", count: cellChars)
        for _ in 0..<textCount {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: textPara)])))
        }
        for _ in 0..<tableCount {
            var rows: [TableRow] = []
            for _ in 0..<tableRows {
                var cells: [TableCell] = []
                for _ in 0..<tableCols {
                    cells.append(TableCell(paragraphs: [Paragraph(runs: [Run(text: cellText)])]))
                }
                rows.append(TableRow(cells: cells))
            }
            doc.body.children.append(.table(Table(rows: rows)))
        }
        return try writeFixture(doc, prefix: "issue143_text_tables")
    }

    private func writeFixture(_ doc: WordDocument, prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - JSON / response helpers (mirrored from #266 test)

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func jsonObject(from text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
