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

    // MARK: - Issue #131 — output size caps (limit/offset + non-silent truncation disclosure)

    func testListCommentsJSONModeIsPaginatedWithExplicitDisclosure() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("cap")]
        )

        let result = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string("cap"), "include_context": .bool(true), "limit": .int(1)]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(#""total":2"#), out)
        XCTAssertTrue(out.contains(#""returned":1"#), out)
        XCTAssertTrue(out.contains(#""truncated":true"#), out)
        XCTAssertTrue(out.contains(#""id":1"#), out)
        XCTAssertFalse(out.contains(#""id":2"#),
                       "limit:1 SHALL NOT silently include the second comment, got: \(out)")
    }

    func testListCommentsRejectsNonPositiveLimit() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("cap0")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string("cap0"), "limit": .int(0)]
        )
        XCTAssertEqual(result.isError, true, textOf(result))
        XCTAssertTrue(textOf(result).contains("limit"), textOf(result))
    }

    func testFindUnresolvedCommentsIsPaginatedWithExplicitDisclosure() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("unresolvedcap")]
        )
        let result = await server.invokeToolForTesting(
            name: "find_unresolved_comments",
            arguments: ["doc_id": .string("unresolvedcap"), "limit": .int(1)]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(#""total":2"#), out)
        XCTAssertTrue(out.contains(#""returned":1"#), out)
        XCTAssertTrue(out.contains(#""truncated":true"#), out)
    }

    func testFindInlineMathGapsIsPaginatedWithExplicitDisclosure() async throws {
        let url = try writeGapFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("gapcap")]
        )
        let result = await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: ["doc_id": .string("gapcap"), "limit": .int(1)]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(#""total":2"#), out)
        XCTAssertTrue(out.contains(#""returned":1"#), out)
        XCTAssertTrue(out.contains(#""truncated":true"#), out)
        XCTAssertTrue(out.contains(#""gaps":["#), out)
    }

    func testFindInlineMathGapsFlattenedTextSurvivesInFullByDefault() async throws {
        // #178 policy: full text unless summarize:true is explicitly requested.
        let url = try writeGapFixtureWithLongParagraph()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("gaplong")]
        )
        let result = await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: ["doc_id": .string("gaplong")]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(Self.longGapPadding), "expected full text by default, got: \(out.prefix(200))")
        XCTAssertFalse(out.contains(" [...] "), out)

        let summarized = textOf(await server.invokeToolForTesting(
            name: "find_inline_math_gaps",
            arguments: ["doc_id": .string("gaplong"), "summarize": .bool(true)]
        ))
        XCTAssertTrue(summarized.contains(" [...] "),
                      "past the shared 5000-char threshold, summarize:true SHALL elide, got: \(summarized.prefix(200))")
    }

    // MARK: - Issue #132 — bulk_resolve_comments dedupe + size cap + O(M+N)

    func testBulkResolveCommentsDedupesRepeatedIds() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("dedupe")]
        )
        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string("dedupe"), "comment_ids": .array([.int(1), .int(1), .int(1)])]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(#""resolved":1"#),
                      "three duplicate ids SHALL resolve exactly one comment, got: \(out)")
        XCTAssertFalse(out.contains(#""resolved":3"#), out)
    }

    func testBulkResolveCommentsRejectsOversizedBatch() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("oversized")]
        )
        let hugeIds: [Value] = (1...1001).map { .int($0) }
        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string("oversized"), "comment_ids": .array(hugeIds)]
        )
        XCTAssertEqual(result.isError, true, textOf(result))
        XCTAssertTrue(textOf(result).contains("1000"), textOf(result))
    }

    func testBulkResolveCommentsHandlesRealisticMixedBatchWithoutHanging() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("mixed")]
        )
        // 800 requested ids against a 2-comment document: 2 valid (1, 2,
        // duplicated), the rest not_found. Exercises the O(M+N) lookup path
        // (#132) at a size where the old O(M×N) `contains(where:)` would
        // still finish, but the shape under test is correctness, not timing.
        var ids: [Value] = [.int(1), .int(2)]
        ids.append(contentsOf: (1000..<1798).map { .int($0) })
        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string("mixed"), "comment_ids": .array(ids)]
        )
        let out = textOf(result)
        XCTAssertTrue(out.contains(#""resolved":2"#), out)
        XCTAssertTrue(out.contains(#""error":"not_found""#), out)
    }

    // MARK: - Issue #133 — add_comment_reply / reply_to_comment schema symmetry

    func testAddCommentReplyAndReplyToCommentSchemasAreSymmetric() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()
        guard let addReply = tools.first(where: { $0.name == "add_comment_reply" }),
              let replyTo = tools.first(where: { $0.name == "reply_to_comment" }) else {
            XCTFail("expected both tools to be registered")
            return
        }

        for tool in [addReply, replyTo] {
            guard let schema = tool.inputSchema.objectValue,
                  let properties = schema["properties"]?.objectValue else {
                XCTFail("\(tool.name) schema missing properties")
                continue
            }
            XCTAssertNotNil(properties["comment_id"], "\(tool.name) SHALL accept comment_id")
            XCTAssertNotNil(properties["parent_comment_id"], "\(tool.name) SHALL accept parent_comment_id")
            guard let oneOf = schema["oneOf"]?.arrayValue else {
                XCTFail("\(tool.name) SHALL declare oneOf requiring comment_id or parent_comment_id")
                continue
            }
            let requiredNames = oneOf.compactMap { $0.objectValue?["required"]?.arrayValue }
                .flatMap { $0.compactMap(\.stringValue) }
            XCTAssertTrue(requiredNames.contains("comment_id"), "\(tool.name): \(requiredNames)")
            XCTAssertTrue(requiredNames.contains("parent_comment_id"), "\(tool.name): \(requiredNames)")
        }
    }

    func testReplyToCommentAcceptsCommentIdAlias() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("aliasA")]
        )
        let result = await server.invokeToolForTesting(
            name: "reply_to_comment",
            arguments: ["doc_id": .string("aliasA"), "comment_id": .int(1), "text": .string("via comment_id")]
        )
        XCTAssertFalse(result.isError ?? false, textOf(result))
        XCTAssertTrue(textOf(result).contains("Added reply to comment 1"), textOf(result))
    }

    func testAddCommentReplyAcceptsParentCommentIdAlias() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("aliasB")]
        )
        let result = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: ["doc_id": .string("aliasB"), "parent_comment_id": .int(1), "text": .string("via parent_comment_id")]
        )
        XCTAssertFalse(result.isError ?? false, textOf(result))
        XCTAssertTrue(textOf(result).contains("Added reply to comment 1"), textOf(result))
    }

    func testReplyToCommentRejectsWhenNeitherIdAliasProvided() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("neither")]
        )
        let result = await server.invokeToolForTesting(
            name: "reply_to_comment",
            arguments: ["doc_id": .string("neither"), "text": .string("no id given")]
        )
        XCTAssertEqual(result.isError, true, textOf(result))
        XCTAssertTrue(textOf(result).contains("comment_id"), textOf(result))
    }

    // MARK: - Issue #135 — list_comments / find_unresolved_comments reply policy + parent_id

    func testListCommentsDefaultExcludesRepliesIncludeRepliesOptsIn() async throws {
        let url = try writeCommentFixtureWithReply()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("replypolicy")]
        )

        let defaultResult = textOf(await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string("replypolicy"), "include_context": .bool(true)]
        ))
        XCTAssertTrue(defaultResult.contains(#""id":1"#), defaultResult)
        XCTAssertFalse(defaultResult.contains(#""id":2"#),
                       "reply SHALL be excluded by default, got: \(defaultResult)")

        let withReplies = textOf(await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string("replypolicy"), "include_context": .bool(true), "include_replies": .bool(true)]
        ))
        XCTAssertTrue(withReplies.contains(#""id":2"#), withReplies)
        XCTAssertTrue(withReplies.contains(#""parent_id":1"#),
                     "reply SHALL expose its parent_id, got: \(withReplies)")
        XCTAssertTrue(withReplies.contains(#""anchored_run_text":null"#), withReplies)
    }

    func testFindUnresolvedCommentsIncludeRepliesOptsIn() async throws {
        let url = try writeCommentFixtureWithReply()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("unresolvedreplypolicy")]
        )

        let defaultResult = textOf(await server.invokeToolForTesting(
            name: "find_unresolved_comments",
            arguments: ["doc_id": .string("unresolvedreplypolicy")]
        ))
        XCTAssertFalse(defaultResult.contains(#""id":2"#), defaultResult)

        let withReplies = textOf(await server.invokeToolForTesting(
            name: "find_unresolved_comments",
            arguments: ["doc_id": .string("unresolvedreplypolicy"), "include_replies": .bool(true)]
        ))
        XCTAssertTrue(withReplies.contains(#""id":2"#), withReplies)
        XCTAssertTrue(withReplies.contains(#""parent_id":1"#), withReplies)
    }

    func testThreadRootCommentsExposeNullParentId() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("rootparent")]
        )
        let out = textOf(await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string("rootparent"), "include_context": .bool(true)]
        ))
        XCTAssertTrue(out.contains(#""parent_id":null"#), out)
    }

    // MARK: - Issue #137 — reject reply-to-reply and resolving a reply

    func testAddCommentReplyRejectsReplyToReply() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("nested")]
        )
        let firstReply = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: ["doc_id": .string("nested"), "comment_id": .int(1), "text": .string("first reply")]
        )
        XCTAssertFalse(firstReply.isError ?? false, textOf(firstReply))
        // writeCommentFixture() seeds ids 1 and 2, so the new reply is id 3.
        let nestedReply = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: ["doc_id": .string("nested"), "comment_id": .int(3), "text": .string("reply to a reply")]
        )
        XCTAssertEqual(nestedReply.isError, true, textOf(nestedReply))
        XCTAssertTrue(textOf(nestedReply).contains("reply to a reply"), textOf(nestedReply))
    }

    func testAddCommentReplyRejectsResolvingAReply() async throws {
        let url = try writeCommentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("nestedresolve")]
        )
        let firstReply = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: ["doc_id": .string("nestedresolve"), "comment_id": .int(1), "text": .string("first reply")]
        )
        XCTAssertFalse(firstReply.isError ?? false, textOf(firstReply))
        let result = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: [
                "doc_id": .string("nestedresolve"),
                "comment_id": .int(3),
                "text": .string("also trying to resolve"),
                "resolve": .bool(true)
            ]
        )
        XCTAssertEqual(result.isError, true, textOf(result))
    }

    // MARK: - Helpers

    private static let longGapPadding = String(repeating: "P", count: 6000)

    private func writeGapFixtureWithLongParagraph() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(text: "若  顯著為正 " + Self.longGapPadding)))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("math_gaps_long_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func writeCommentFixtureWithReply() throws -> URL {
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
        doc.comments.addComment(Comment(id: 1, author: "Reviewer", text: "Please fix", paragraphIndex: 0))
        _ = doc.comments.addReply(to: 1, author: "Author", text: "Working on it")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("comment_reply_fixture_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

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
