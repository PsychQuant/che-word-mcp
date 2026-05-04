import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#266 — floating comments often reference "page N"
/// even though OOXML has no rendered page boundary. This tool narrows that
/// page reference to a get_paragraphs candidate range.
final class Issue89EstimateParagraphForPageTests: XCTestCase {

    func testEstimateParagraphForPageUsesOneBasedPagesAndCallerCalibration() async throws {
        let url = try docxWithFixedParagraphs(count: 12, charsPerParagraphBeforeBreak: 99)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(2),
                "chars_per_page": .int(300),
                "context_paragraphs": .int(0)
            ]
        )

        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(intArray(json["estimated_paragraph_range"]), [3, 5])
        XCTAssertEqual(intArray(json["raw_estimated_paragraph_range"]), [3, 5])
        // #142 (v2): method bumped to "char_count_heuristic_v2" with structural weights.
        // Pure-text fixtures (this test) behave identically — just the version label updated.
        XCTAssertEqual(json["method"] as? String, "char_count_heuristic_v2")
        XCTAssertEqual(json["layout_basis"] as? String, "caller_chars_per_page")
        XCTAssertEqual(json["assumed_chars_per_page"] as? Int, 300)
        XCTAssertEqual(json["page"] as? Int, 2)
        XCTAssertEqual(json["paragraph_count"] as? Int, 12)
        XCTAssertEqual(json["estimated_total_pages"] as? Int, 4)
        XCTAssertEqual(json["requested_page_beyond_estimated_document"] as? Bool, false)
        XCTAssertTrue((json["warning"] as? String ?? "").contains("OOXML does not store page boundaries"))
    }

    func testEstimateParagraphForPageMarksBeyondEstimatedDocument() async throws {
        let url = try docxWithFixedParagraphs(count: 12, charsPerParagraphBeforeBreak: 99)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(10),
                "chars_per_page": .int(300),
                "context_paragraphs": .int(0)
            ]
        )

        let json = try jsonObject(from: textOf(result))
        XCTAssertEqual(intArray(json["estimated_paragraph_range"]), [11, 11])
        XCTAssertEqual(json["requested_page_beyond_estimated_document"] as? Bool, true)
        XCTAssertEqual(json["confidence"] as? String, "low")
    }

    func testEstimateParagraphForPageRejectsInvalidPageAndCalibration() async throws {
        let url = try docxWithFixedParagraphs(count: 1, charsPerParagraphBeforeBreak: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let invalidPage = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(0)
            ]
        )
        XCTAssertTrue(textOf(invalidPage).contains("page must be"))

        let invalidCalibration = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(0)
            ]
        )
        XCTAssertTrue(textOf(invalidCalibration).contains("chars_per_page must be"))
    }

    // MARK: - Int.max overflow regression (P1 from 6-AI verify)

    func testEstimateParagraphForPageRejectsHugePage() async throws {
        // Pre-fix: `(page - 1) * charsPerPage` and `page * charsPerPage` with
        // page = Int.max trapped on arithmetic overflow → MCP server actor
        // crashed. Post-fix clamps page to 1..100_000.
        let url = try docxWithFixedParagraphs(count: 1, charsPerParagraphBeforeBreak: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(.max)
            ]
        )
        let text = textOf(result)
        XCTAssertTrue(
            text.contains("page must be") && text.contains("100000"),
            "expected structured upper-bound rejection, got: \(text)"
        )
    }

    func testEstimateParagraphForPageRejectsHugeCharsPerPage() async throws {
        // Same overflow concern with chars_per_page = Int.max.
        let url = try docxWithFixedParagraphs(count: 1, charsPerParagraphBeforeBreak: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "chars_per_page": .int(.max)
            ]
        )
        let text = textOf(result)
        XCTAssertTrue(
            text.contains("chars_per_page must be") && text.contains("200000"),
            "expected structured upper-bound rejection, got: \(text)"
        )
    }

    func testEstimateParagraphForPageRejectsHugeContextParagraphs() async throws {
        // Pre-fix: `rawStart - contextParagraphs` underflow + `rawEnd +
        // contextParagraphs` overflow on Int.max. Post-fix clamps to 0..1024.
        let url = try docxWithFixedParagraphs(count: 1, charsPerParagraphBeforeBreak: 10)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page",
            arguments: [
                "source_path": .string(url.path),
                "page": .int(1),
                "context_paragraphs": .int(.max)
            ]
        )
        let text = textOf(result)
        XCTAssertTrue(
            text.contains("context_paragraphs must be") && text.contains("1024"),
            "expected structured upper-bound rejection, got: \(text)"
        )
    }

    func testEstimateParagraphForPageSchemaDocumentsHeuristicWarning() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/CheWordMCP/Server.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("name: \"estimate_paragraph_for_page\""))
        XCTAssertTrue(source.contains("OOXML 不儲存頁面邊界"))
        XCTAssertTrue(source.contains("Word UI 頁碼（1-based"))
        XCTAssertTrue(source.contains("chars_per_page"))
        XCTAssertTrue(source.contains("context_paragraphs"))
    }

    private func docxWithFixedParagraphs(count: Int, charsPerParagraphBeforeBreak: Int) throws -> URL {
        var doc = WordDocument()
        let text = String(repeating: "x", count: charsPerParagraphBeforeBreak)
        for _ in 0..<count {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue89_page_estimate_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

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

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}
