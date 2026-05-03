import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class CommentReviewWorkflowToolsTests: XCTestCase {

    func testListCommentsCanIncludeAnchorContextPreview() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        let opened = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("comments")]
        )
        XCTAssertFalse(textOf(opened).contains("Error:"), textOf(opened))

        let listed = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: [
                "doc_id": .string("comments"),
                "include_context": .bool(true),
                "context_chars": .int(12)
            ]
        )
        let text = textOf(listed)
        XCTAssertTrue(text.contains(#""id":1"#), text)
        XCTAssertTrue(text.contains(#""anchored_run_text":"target phrase""#), text)
        XCTAssertTrue(text.contains(#""context_before":"Before ""#), text)
        XCTAssertTrue(text.contains(#""context_after":" after""#), text)
    }

    func testReplyTemplateCanResolveAndFindUnresolvedFiltersDoneComments() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("workflow")]
        )

        let reply = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: [
                "doc_id": .string("workflow"),
                "comment_id": .int(1),
                "template": .string("fix_done"),
                "vars": .object([
                    "commit_sha": .string("abc1234"),
                    "issue_number": .int(88)
                ]),
                "resolve": .bool(true),
                "author": .string("Codex")
            ]
        )
        let replyText = textOf(reply)
        XCTAssertTrue(replyText.contains("Added reply to comment 1"), replyText)
        XCTAssertTrue(replyText.contains("resolved"), replyText)

        let thread = await server.invokeToolForTesting(
            name: "get_comment_thread",
            arguments: ["doc_id": .string("workflow"), "root_comment_id": .int(1)]
        )
        XCTAssertTrue(textOf(thread).contains("Fixed in abc1234 (Refs #88)"), textOf(thread))

        let unresolved = await server.invokeToolForTesting(
            name: "find_unresolved_comments",
            arguments: ["doc_id": .string("workflow")]
        )
        let unresolvedText = textOf(unresolved)
        XCTAssertFalse(unresolvedText.contains(#""id":1"#), unresolvedText)
        XCTAssertTrue(unresolvedText.contains(#""id":2"#), unresolvedText)
    }

    func testBulkResolveReportsPartialFailures() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("bulk")]
        )

        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: [
                "doc_id": .string("bulk"),
                "comment_ids": .array([.int(1), .int(999)])
            ]
        )
        let text = textOf(result)
        XCTAssertTrue(text.contains(#""resolved":1"#), text)
        XCTAssertTrue(text.contains(#""comment_id":999"#), text)
        XCTAssertTrue(text.contains(#""error":"not_found""#), text)
    }

    func testFindInlineMathGapsScansBodyAndTableCells() async throws {
        let url = try writeGapFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("gaps")]
        )

        let result = await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: [
                "doc_id": .string("gaps"),
                "min_gap_chars": .int(2),
                "context_chars": .int(12),
                "exclude_table_captions": .bool(true)
            ]
        )
        let text = textOf(result)
        XCTAssertTrue(text.contains(#""paragraph_index":0"#), text)
        XCTAssertTrue(text.contains(#""context_before":"若""#), text)
        XCTAssertTrue(text.contains(#""context_after":"顯著為正""#), text)
        XCTAssertTrue(text.contains(#""location":"table[0].row[0].col[0].paragraph[0]""#), text)
        XCTAssertFalse(text.contains("caption"), text)
    }

    // MARK: - Issue #130 — Int.max overflow regression

    func testFindInlineMathGapsClampsHugeContextChars() async throws {
        // Pre-fix: `i + contextChars` with contextChars = Int.max trapped on
        // arithmetic overflow → MCP server actor crashed. Post-fix clamps
        // contextChars to 4096 before the addition. Verify the call returns
        // a normal JSON response without crashing.
        let url = try writeGapFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("gap_intmax")]
        )

        let result = await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: [
                "doc_id": .string("gap_intmax"),
                "context_chars": .int(.max)
            ]
        )
        let text = textOf(result)
        XCTAssertFalse(
            text.lowercased().contains("error"),
            "expected clamped context_chars to succeed without server-side error; got: \(text)"
        )
        // Sanity: response should still surface the body-level gap fixture.
        XCTAssertTrue(
            text.contains(#""paragraph_index":0"#),
            "expected normal gap output post-clamp; got: \(text)"
        )
    }

    func testFindInlineMathGapsClampsHugeMinGapChars() async throws {
        // min_gap_chars: Int.max would never match (no real paragraph has
        // INT_MAX whitespace chars), but pre-fix it still consumed the
        // gap-scan inner loop's `length >= minGapChars` comparison as a giant
        // unsigned-equivalent miss path. Post-fix clamps to 1024, covering
        // any plausible accidental whitespace run.
        let url = try writeGapFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("gap_min_intmax")]
        )

        let result = await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: [
                "doc_id": .string("gap_min_intmax"),
                "min_gap_chars": .int(.max)
            ]
        )
        let text = textOf(result)
        XCTAssertFalse(
            text.lowercased().contains("error"),
            "expected clamped min_gap_chars to succeed without error; got: \(text)"
        )
    }

    // MARK: - Helpers

    private func writeCommentFixture() throws -> URL {
        var doc = WordDocument()

        var commented = Paragraph(runs: [
            positionedRun("Before ", 1),
            positionedRun("target phrase", 3),
            positionedRun(" after", 5)
        ])
        commented.commentRangeMarkers = [
            CommentRangeMarker(kind: .start, id: 1, position: 2),
            CommentRangeMarker(kind: .end, id: 1, position: 4)
        ]
        doc.body.children.append(.paragraph(commented))
        doc.body.children.append(.paragraph(Paragraph(text: "Second paragraph")))

        doc.comments.addComment(Comment(id: 1, author: "Reviewer", text: "Please fix", paragraphIndex: 0))
        doc.comments.addComment(Comment(id: 2, author: "Reviewer", text: "Still open", paragraphIndex: 1))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comment_workflow_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func writeGapFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(text: "若  顯著為正")))
        doc.body.children.append(.paragraph(Paragraph(text: "表 1 caption  gap")))
        let table = Table(rows: [
            TableRow(cells: [
                TableCell(paragraphs: [Paragraph(text: "cell  gap")])
            ])
        ])
        doc.body.children.append(.table(table))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("math_gaps_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func positionedRun(_ text: String, _ position: Int) -> Run {
        var run = Run(text: text)
        run.position = position
        return run
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
