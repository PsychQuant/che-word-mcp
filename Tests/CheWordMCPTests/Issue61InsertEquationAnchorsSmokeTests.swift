import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#61 — `insert_equation` should accept `after_text`
/// / `before_text` / `text_instance` anchors when `display_mode=true`. Inline
/// mode (`display_mode=false`) must explicitly reject anchor parameters with
/// a structured error (semantics ambiguous: "into the para containing this
/// text" vs "around the para").
final class Issue61InsertEquationAnchorsSmokeTests: XCTestCase {

    private func minimalDocxWithAnchorPara() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "EQ_ANCHOR")])))
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "tail")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue61_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    func testInsertEquationAfterTextDisplayModeResolvesAnchor() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61a")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61a"),
                "latex": .string("a^2 + b^2 = c^2"),
                "display_mode": .bool(true),
                "after_text": .string("EQ_ANCHOR")
            ]
        )
        XCTAssertFalse(r.isError == true,
                       "insert_equation after_text (display mode) should succeed; got: \(r.content)")
    }

    func testInsertEquationBeforeTextDisplayModeResolvesAnchor() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61b")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61b"),
                "latex": .string("\\frac{a}{b}"),
                "display_mode": .bool(true),
                "before_text": .string("EQ_ANCHOR")
            ]
        )
        XCTAssertFalse(r.isError == true,
                       "insert_equation before_text (display mode) should succeed; got: \(r.content)")
    }

    func testInsertEquationAnchorRejectedInInlineMode() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61i")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61i"),
                "latex": .string("x^2"),
                "display_mode": .bool(false),
                "after_text": .string("EQ_ANCHOR")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("display mode") || txt.contains("display_mode"),
            "inline mode + anchor should reject; got: \(txt)"
        )
    }

    func testInsertEquationMissingAnchorReportsTextNotFound() async throws {
        let url = try minimalDocxWithAnchorPara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e61n")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e61n"),
                "latex": .string("y"),
                "display_mode": .bool(true),
                "after_text": .string("NO_SUCH_ANCHOR_HERE")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            r.isError == true || txt.contains("not found"),
            "missing anchor must report textNotFound; got: \(txt)"
        )
    }

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
