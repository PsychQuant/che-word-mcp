import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#144 — `estimate_paragraph_for_page` test coverage
/// gaps surfaced during verify of #114:
///
/// 1. Session Mode (`doc_id`, via `open_document`) had no DEDICATED smoke
///    test — the only path that exercised it was an incidental assertion
///    inside `Issue234IntegerOverflowGuardTests`
///    (`testSetPageMarginsAcceptsOrdinaryValuesAndEstimateStillWorks`),
///    which only asserts "not an error", not response shape.
/// 2. `page == estimated_total_pages + 1` (exactly one page beyond, as
///    opposed to a wildly out-of-range `Int.max`-style boundary already
///    covered by `Issue89EstimateParagraphForPageTests`) had no dedicated
///    test.
/// 3. The `empty_document` path (0 body-stream paragraphs) had ZERO test
///    coverage — grep confirms no test ever exercised it.
///
/// Real-shape fixtures (tables / images / mixed thesis layout) requested by
/// this issue are already covered by
/// `Issue142EstimateParagraphForPageStructuralWeightsTests`; not duplicated
/// here.
final class Issue144TestCoverageGapsTests: XCTestCase {

    // MARK: - 1. Session Mode smoke test

    func testEstimateParagraphForPageSessionModeSmokeTest() async throws {
        let server = await WordMCPServer()
        let docId = "issue144-session-mode"
        let url = try docxWithTextParagraphs(count: 15, chars: 60)
        defer { try? FileManager.default.removeItem(at: url) }

        let opened = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["doc_id": .string(docId), "path": .string(url.path)]
        )
        XCTAssertNotEqual(opened.isError, true, textOf(opened))

        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["doc_id": .string(docId), "page": .int(1)]
        )
        XCTAssertNotEqual(result.isError, true, textOf(result))

        let json = try jsonObject(from: textOf(result))
        XCTAssertNotNil(json["estimated_paragraph_range"], textOf(result))
        XCTAssertNotNil(json["confidence"], textOf(result))
        XCTAssertNotNil(json["confidence_reason"], textOf(result))
        XCTAssertNotNil(json["method"], textOf(result))
        XCTAssertEqual(json["paragraph_count"] as? Int, 15)

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string(docId), "discard_changes": .bool(true)])
    }

    // MARK: - 2. Exact boundary: page == total pages + 1

    func testEstimateParagraphForPageExactlyOneBeyondTotalPages() async throws {
        // 5 paragraphs × 100 chars weight (99 'x' + 1 break) = 500 total
        // chars. chars_per_page: 100 → estimated_total_pages == 5 exactly.
        // page: 6 is precisely one page beyond, not a huge out-of-range
        // value (that boundary is already covered elsewhere).
        let url = try docxWithTextParagraphs(count: 5, chars: 99)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(6),
                "chars_per_page": .int(100),
                "context_paragraphs": .int(0),
            ]
        )
        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(json["estimated_total_pages"] as? Int, 5, textOf(result))
        XCTAssertEqual(json["requested_page_beyond_estimated_document"] as? Bool, true, textOf(result))
        XCTAssertEqual(intArray(json["estimated_paragraph_range"]), [4, 4], textOf(result))
    }

    // MARK: - 3. empty_document path

    func testEstimateParagraphForPageEmptyDocumentThrowsStructuredError() async throws {
        let doc = WordDocument()  // zero body children → zero body-stream paragraphs
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue144_empty_doc_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: ["source_path": .string(url.path), "page": .int(1)]
        )

        // #145: this must go through the SAME error convention as every
        // other rejection in this function (thrown → isError: true, `Error:
        // ` prefix) — not a 200-shaped JSON blob with an unflagged "error"
        // key (the #238-class bug: a caller checking only `isError` would
        // believe this succeeded).
        XCTAssertEqual(result.isError, true, textOf(result))
        XCTAssertTrue(textOf(result).contains("empty_document"), textOf(result))
        XCTAssertFalse(textOf(result).contains("estimated_paragraph_range"), textOf(result))
    }

    // MARK: - Fixture builder

    private func docxWithTextParagraphs(count: Int, chars: Int) throws -> URL {
        var doc = WordDocument()
        let text = String(repeating: "x", count: chars)
        for _ in 0..<count {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue144_text_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - JSON / response helpers (mirrored from #89 test)

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
