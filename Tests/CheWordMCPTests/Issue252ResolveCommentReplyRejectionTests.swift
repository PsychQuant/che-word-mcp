import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#252 — #137 (v4.6.0) made `add_comment_reply` /
/// `reply_to_comment` reject "reply to a reply" and "resolve=true on a
/// reply", because Word's `done` state is a THREAD-ROOT-level flag (keyed
/// by the root comment's `paraId` in `commentsExtended.xml`), not a
/// per-comment one. But `resolve_comment` (and `bulk_resolve_comments` for
/// a single id) called `CommentsCollection.markAsDone` directly with no
/// such check, so a caller could still mark a REPLY done in isolation,
/// producing a state Word cannot display consistently (the thread's done
/// indicator reads from the root, not from whichever reply got the flag).
///
/// Fixture: `Comment(id: 1)` is a thread root; `doc.comments.addReply(to:
/// 1, ...)` allocates the next id (2, since only comment 1 exists before
/// it) as a reply with `parentId == 1`.
final class Issue252ResolveCommentReplyRejectionTests: XCTestCase {

    private func writeCommentFixtureWithReply() throws -> URL {
        var doc = WordDocument()
        var commented = Paragraph(runs: [Run(text: "Before "), Run(text: "target"), Run(text: " after")])
        commented.commentRangeMarkers = [
            CommentRangeMarker(kind: .start, id: 1, position: 0),
            CommentRangeMarker(kind: .end, id: 1, position: 1)
        ]
        doc.body.children.append(.paragraph(commented))
        doc.comments.addComment(Comment(id: 1, author: "Reviewer", text: "Please fix", paragraphIndex: 0))
        _ = doc.comments.addReply(to: 1, author: "Author", text: "Working on it")

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue252_reply_fixture_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func open(_ server: WordMCPServer, docId: String) async throws {
        let url = try writeCommentFixtureWithReply()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )
    }

    /// The reply got id 2 (comment 1 is the only pre-existing id;
    /// `nextCommentId()` allocates max+1). Calling `resolve_comment` on it
    /// directly must be rejected the same way #137 rejects
    /// `add_comment_reply`/`reply_to_comment` targeting a reply.
    func testResolveCommentRejectsAReplyId() async throws {
        let server = await WordMCPServer()
        let docId = "i252a"
        try await open(server, docId: docId)

        let r = await server.invokeToolForTesting(
            name: "resolve_comment",
            arguments: ["doc_id": .string(docId), "comment_id": .int(2)]
        )
        XCTAssertEqual(r.isError, true, "resolve_comment on a reply id must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("comment_id"), textOf(r))
        XCTAssertTrue(textOf(r).lowercased().contains("reply") || textOf(r).contains("parent"), textOf(r))
    }

    /// The thread root (id 1) must still resolve normally — #252 only
    /// tightens the reply case, it does not touch root behavior.
    func testResolveCommentStillAcceptsThreadRoot() async throws {
        let server = await WordMCPServer()
        let docId = "i252b"
        try await open(server, docId: docId)

        let r = await server.invokeToolForTesting(
            name: "resolve_comment",
            arguments: ["doc_id": .string(docId), "comment_id": .int(1)]
        )
        XCTAssertNotEqual(r.isError, true, "resolve_comment on the thread root must still succeed. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("resolved"), textOf(r))
    }

    /// `bulk_resolve_comments` must apply the SAME rule for a single id,
    /// consistent with `resolve_comment` — per its own documented "不中斷於
    /// 單筆失敗" contract, the reply id fails THAT entry via `failed`
    /// (not an isError for the whole call), and is not marked done.
    func testBulkResolveCommentsFailsAReplyIdWithoutAbortingTheBatch() async throws {
        let server = await WordMCPServer()
        let docId = "i252c"
        try await open(server, docId: docId)

        let r = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string(docId), "comment_ids": .array([.int(1), .int(2)])]
        )
        let text = textOf(r)
        XCTAssertNotEqual(r.isError, true, "bulk_resolve_comments must not abort the whole batch for one reply id. Got: \(text)")
        XCTAssertTrue(text.contains(#""resolved":1"#), text)
        XCTAssertTrue(text.contains(#""comment_id":2"#), text)
        XCTAssertTrue(text.contains(#""error":"is_reply""#), text)

        // The reply must NOT have been marked done as a side effect.
        let thread = await server.invokeToolForTesting(
            name: "get_comment_thread",
            arguments: ["doc_id": .string(docId), "root_comment_id": .int(1)]
        )
        // Root (1) WAS resolved by this same call; only the reply (2) must
        // be excluded from that state change. We can't directly assert
        // reply.done == false from the markdown export alone without
        // parsing further, so we cross-check via a direct single-id
        // resolve_comment call, which must still reject it (i.e. its
        // parentId — and therefore its "still a reply" status — didn't
        // change).
        let stillRejects = await server.invokeToolForTesting(
            name: "resolve_comment",
            arguments: ["doc_id": .string(docId), "comment_id": .int(2)]
        )
        XCTAssertEqual(stillRejects.isError, true, "reply id 2 must still be a reply (rejected) after the bulk call. Got: \(textOf(stillRejects))")
        _ = thread
    }
}
