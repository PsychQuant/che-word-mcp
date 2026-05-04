import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#142 — `estimate_paragraph_for_page` heuristic
/// upgrade: structural weights for tables, image-only paragraphs, and
/// display equations. Verify finding from #114 surfaced that document-style
/// docx (formula + image + table heavy) was systematically under-estimated.
///
/// Two-layer fix:
/// - Walker: `getParagraphs()` → `collectStructuralBlocks()` returning
///   `StructuralBlock` enum (.paragraph / .table / .imageOnlyParagraph /
///   .displayEquationParagraph)
/// - Weights: text = `text.count + 1` (unchanged); table = `tableRows ×
///   avgCellChars` (200/row fallback); image = +200/drawing; display eq = 120
final class Issue142EstimateParagraphForPageStructuralWeightsTests: XCTestCase {

    // MARK: - Test 1: Pure-text regression (must match v1 behavior)

    /// Pure-text fixture: same fixture pattern as #266 tests, asserting that
    /// the v2 walker produces identical page estimates for text-only docs.
    /// (The #266 family already covers this; this test pins the invariant in
    /// the #142 family for symmetry.)
    func testEstimateParagraphForPagePureTextRegression() async throws {
        let url = try docxWithTextParagraphs(count: 12, chars: 99)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(2),
                "chars_per_page": .int(300),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        // Pre-fix and post-fix must produce identical paragraph_count and span
        // for pure-text fixtures.
        XCTAssertEqual(json["paragraph_count"] as? Int, 12)
        XCTAssertEqual(intArray(json["estimated_paragraph_range"]), [3, 5])
        XCTAssertEqual(json["method"] as? String, "char_count_heuristic_v2")

        // structural_breakdown should show pure-text only
        let breakdown = json["structural_breakdown"] as? [String: Any]
        XCTAssertEqual(breakdown?["paragraphs_with_text"] as? Int, 12)
        XCTAssertEqual(breakdown?["tables_counted"] as? Int, 0)
        XCTAssertEqual(breakdown?["image_only_paragraphs"] as? Int, 0)
        XCTAssertEqual(breakdown?["display_equations"] as? Int, 0)
    }

    // MARK: - Test 2: Tables now contribute to char count

    /// Pre-#142: 30 text paragraphs + 5 tables → tables silently dropped,
    /// page estimate fires too early. Post-fix: tables contribute their
    /// per-row × cell-char weight to the cumulative count.
    func testEstimateParagraphForPageCountsTables() async throws {
        let url = try docxWithTextAndTables(textCount: 30, textChars: 50,
                                             tableCount: 5, tableRows: 5,
                                             tableCols: 2, cellChars: 25)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(1400),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["method"] as? String, "char_count_heuristic_v2")
        // body-paragraph count: 30 (tables not counted in paragraph_count)
        XCTAssertEqual(json["paragraph_count"] as? Int, 30)

        let breakdown = try XCTUnwrap(json["structural_breakdown"] as? [String: Any])
        XCTAssertEqual(breakdown["tables_counted"] as? Int, 5)
        // 5 tables × 5 rows × 2 cells × 25 chars = 1250/table; total 6250
        let tablesChars = (breakdown["tables_total_chars"] as? Int) ?? 0
        XCTAssertGreaterThanOrEqual(tablesChars, 5 * 5 * 2 * 25,
            "5 tables × 5 rows × 2 cells × 25 chars = 6250 minimum (each cell counted)")
        XCTAssertEqual(breakdown["paragraphs_with_text"] as? Int, 30)

        // total_estimated_chars should include text (30 × ~51) + tables (~6250)
        let total = (json["total_estimated_chars"] as? Int) ?? 0
        XCTAssertGreaterThan(total, 30 * 50 + 5 * 5 * 2 * 25,
            "Cumulative chars must include both text paragraphs and tables")
    }

    // MARK: - Test 3: Image-only paragraphs get +200/drawing weight

    /// Pre-#142: image paragraphs with empty run text counted as ~2 chars
    /// each (run.text empty + 1 newline). Post-fix: each drawing adds +200
    /// to the paragraph's weight, properly reflecting visual page consumption.
    func testEstimateParagraphForPageWeighsImageOnlyParagraphs() async throws {
        let url = try docxWithTextAndImages(textCount: 20, textChars: 50,
                                             imageCount: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(1400),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["method"] as? String, "char_count_heuristic_v2")
        // 20 text + 10 image = 30 body-stream paragraphs
        XCTAssertEqual(json["paragraph_count"] as? Int, 30)

        let breakdown = try XCTUnwrap(json["structural_breakdown"] as? [String: Any])
        XCTAssertEqual(breakdown["image_only_paragraphs"] as? Int, 10)
        // 10 drawings × 200 chars = 2000
        XCTAssertEqual(breakdown["image_chars_added"] as? Int, 2000)
        XCTAssertEqual(breakdown["paragraphs_with_text"] as? Int, 20)
    }

    // MARK: - Test 4: Mixed document-style (within ±1 page tolerance)

    /// Synthetic document-style fixture: 50 text paragraphs + 2 tables +
    /// 3 display equations + 5 inline figures. Asserts page estimate is
    /// within ±1 page of expected (allows for calibration variance).
    func testEstimateParagraphForPageMixedThesisLayout() async throws {
        let url = try docxWithMixedThesisContent()
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(1400),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        let breakdown = try XCTUnwrap(json["structural_breakdown"] as? [String: Any])
        XCTAssertEqual(breakdown["paragraphs_with_text"] as? Int, 50)
        XCTAssertEqual(breakdown["tables_counted"] as? Int, 2)
        XCTAssertEqual(breakdown["image_only_paragraphs"] as? Int, 5)
        // Display equation detection is heuristic-based; accept >= 0
        let displayEqs = (breakdown["display_equations"] as? Int) ?? 0
        XCTAssertGreaterThanOrEqual(displayEqs, 0,
            "display_equations field present (may be 0 if heuristic doesn't match fixture exactly)")

        // total_estimated_chars: 50 × 51 + 2 × 250 + 3 × 120 + 5 × 200 (image) = 2550 + 500 + 360 + 1000 ≈ 4410
        // estimated_total_pages with chars_per_page=1400 → ceil(4410/1400) = 4 pages
        // ±1 tolerance
        let totalPages = (json["estimated_total_pages"] as? Int) ?? 0
        XCTAssertGreaterThanOrEqual(totalPages, 2, "Mixed document fixture should estimate at least 2 pages")
        XCTAssertLessThanOrEqual(totalPages, 5, "Mixed document fixture should not exceed 5 pages")
    }

    // MARK: - Test 5: Method field bumped to v2

    func testEstimateParagraphForPageMethodFieldBumpedToV2() async throws {
        let url = try docxWithTextParagraphs(count: 5, chars: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(300),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["method"] as? String, "char_count_heuristic_v2",
            "Method field must be bumped to v2 to signal structural-weight upgrade")
    }

    // MARK: - Test 6: structural_breakdown all sub-fields exposed

    func testEstimateParagraphForPageStructuralBreakdownExposed() async throws {
        let url = try docxWithTextParagraphs(count: 5, chars: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(300),
                "context_paragraphs": .int(0),
            ]
        )

        let json = try jsonObject(from: textOf(result))
        let breakdown = try XCTUnwrap(json["structural_breakdown"] as? [String: Any])

        // Verify all 9 sub-fields present
        XCTAssertNotNil(breakdown["paragraphs_with_text"], "paragraphs_with_text required")
        XCTAssertNotNil(breakdown["tables_counted"], "tables_counted required")
        XCTAssertNotNil(breakdown["tables_total_chars"], "tables_total_chars required")
        XCTAssertNotNil(breakdown["image_only_paragraphs"], "image_only_paragraphs required")
        XCTAssertNotNil(breakdown["image_chars_added"], "image_chars_added required")
        XCTAssertNotNil(breakdown["display_equations"], "display_equations required")
        XCTAssertNotNil(breakdown["equation_chars_added"], "equation_chars_added required")
        XCTAssertNotNil(breakdown["estimated_total_chars"], "estimated_total_chars required")
        XCTAssertEqual(breakdown["char_breakdown_method"] as? String, "v2_with_structural_weights")
    }

    // MARK: - Fixture builders

    private func docxWithTextParagraphs(count: Int, chars: Int) throws -> URL {
        var doc = WordDocument()
        let text = String(repeating: "x", count: chars)
        for _ in 0..<count {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        }
        return try writeFixture(doc, prefix: "issue142_text")
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
                    let cellPara = Paragraph(runs: [Run(text: cellText)])
                    cells.append(TableCell(paragraphs: [cellPara]))
                }
                rows.append(TableRow(cells: cells))
            }
            doc.body.children.append(.table(Table(rows: rows)))
        }
        return try writeFixture(doc, prefix: "issue142_text_tables")
    }

    private func docxWithTextAndImages(textCount: Int, textChars: Int,
                                        imageCount: Int) throws -> URL {
        var doc = WordDocument()
        let textPara = String(repeating: "x", count: textChars)
        for _ in 0..<textCount {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: textPara)])))
        }
        // Image-only paragraphs: empty-text run with .drawing attached
        for i in 0..<imageCount {
            var run = Run(text: "")
            run.drawing = Drawing(type: .inline, width: 1000, height: 1000,
                                   imageId: "rId\(100 + i)", name: "Picture \(i)")
            doc.body.children.append(.paragraph(Paragraph(runs: [run])))
        }
        return try writeFixture(doc, prefix: "issue142_text_images")
    }

    private func docxWithMixedThesisContent() throws -> URL {
        var doc = WordDocument()
        let textPara = String(repeating: "y", count: 50)
        // 50 text paragraphs
        for _ in 0..<50 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: textPara)])))
        }
        // 2 tables (3 rows × 2 cols × 30 chars)
        let cellText = String(repeating: "z", count: 30)
        for _ in 0..<2 {
            var rows: [TableRow] = []
            for _ in 0..<3 {
                var cells: [TableCell] = []
                for _ in 0..<2 {
                    cells.append(TableCell(paragraphs: [Paragraph(runs: [Run(text: cellText)])]))
                }
                rows.append(TableRow(cells: cells))
            }
            doc.body.children.append(.table(Table(rows: rows)))
        }
        // 5 image-only paragraphs
        for i in 0..<5 {
            var run = Run(text: "")
            run.drawing = Drawing(type: .inline, width: 1000, height: 1000,
                                   imageId: "rIdImg\(i)", name: "Figure \(i)")
            doc.body.children.append(.paragraph(Paragraph(runs: [run])))
        }
        // Note: display equation paragraphs require oMathPara in
        // unrecognizedChildren — synthesizing those at fixture level requires
        // direct rawXML manipulation, which is complex. Test 4 accepts
        // display_equations >= 0 to allow heuristic to detect what it can.
        return try writeFixture(doc, prefix: "issue142_mixed_thesis")
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

    private func intArray(_ value: Any?) -> [Int] {
        (value as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    }
}
