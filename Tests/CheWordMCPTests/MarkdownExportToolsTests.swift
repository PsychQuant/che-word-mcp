import XCTest
import OOXMLSwift
@testable import CheWordMCP

final class MarkdownExportToolsTests: XCTestCase {

    // MARK: - applySummarize

    func testApplySummarizePassesThroughByDefault() {
        let text = String(repeating: "x", count: 10_000)
        XCTAssertEqual(applySummarize(text, summarize: false).count, 10_000)
    }

    func testApplySummarizeBelowThresholdReturnsComplete() {
        let text = String(repeating: "y", count: 4_999)
        XCTAssertEqual(applySummarize(text, summarize: true), text)
    }

    func testApplySummarizeAboveThresholdElides() {
        let text = String(repeating: "z", count: 6_000)
        let elided = applySummarize(text, summarize: true)
        XCTAssertTrue(elided.contains("[...]"))
        XCTAssertLessThan(elided.count, 100, "Elided length should be 30 + ' [...] ' + 30 ≈ 67")
    }

    // MARK: - formatRevisionSummaryMarkdown

    func testRevisionSummaryDefaults() {
        let revisions: [RevisionTuple] = [
            (id: 1, type: "ins", author: "Alice", paragraphIndex: 0, originalText: nil, newText: "added"),
            (id: 2, type: "del", author: "Bob", paragraphIndex: 1, originalText: "removed", newText: nil),
        ]
        let comments: [CommentTuple] = [
            (id: 1, author: "Alice", text: "comment1", paragraphIndex: 0, date: Date()),
        ]
        let md = formatRevisionSummaryMarkdown(
            fileName: "test.docx",
            revisions: revisions,
            comments: comments
        )
        XCTAssertTrue(md.contains("# test.docx — Revision Summary"))
        XCTAssertTrue(md.contains("Revisions: 2"))
        XCTAssertTrue(md.contains("Comments: 1"))
        XCTAssertTrue(md.contains("Alice"))
        XCTAssertTrue(md.contains("Bob"))
    }

    func testRevisionSummaryCommentsOnly() {
        let revisions: [RevisionTuple] = [
            (id: 1, type: "ins", author: "Alice", paragraphIndex: 0, originalText: nil, newText: "added"),
        ]
        let comments: [CommentTuple] = [
            (id: 1, author: "Alice", text: "c", paragraphIndex: 0, date: Date()),
        ]
        let md = formatRevisionSummaryMarkdown(
            fileName: "x.docx",
            revisions: revisions,
            comments: comments,
            includeRevisions: false
        )
        XCTAssertFalse(md.contains("## Revisions"))
        XCTAssertTrue(md.contains("## Comments"))
    }

    func testRevisionSummaryGroupByAuthor() {
        let revisions: [RevisionTuple] = [
            (id: 1, type: "ins", author: "Alice", paragraphIndex: 0, originalText: nil, newText: "a"),
            (id: 2, type: "del", author: "Bob", paragraphIndex: 1, originalText: "b", newText: nil),
            (id: 3, type: "ins", author: "Alice", paragraphIndex: 2, originalText: nil, newText: "c"),
        ]
        let md = formatRevisionSummaryMarkdown(
            fileName: "x.docx",
            revisions: revisions,
            comments: [],
            groupBy: .author
        )
        // Should have ### Alice and ### Bob sub-headings
        XCTAssertTrue(md.contains("### Alice"))
        XCTAssertTrue(md.contains("### Bob"))
    }

    // MARK: - formatCompareDocumentsMarkdown

    func testCompareDocumentsTimeline() {
        let docs = [
            DocumentRef(path: "/v1.docx", label: "v1"),
            DocumentRef(path: "/v2.docx", label: "v2"),
            DocumentRef(path: "/v3.docx", label: "v3"),
        ]
        let stats = [
            DocStats(label: "v1", revisionCount: 0, commentCount: 0, wordCount: 100),
            DocStats(label: "v2", revisionCount: 5, commentCount: 2, wordCount: 110),
            DocStats(label: "v3", revisionCount: 3, commentCount: 1, wordCount: 115),
        ]
        let pairs = [
            (fromLabel: "v1", toLabel: "v2", diff: "diff1"),
            (fromLabel: "v2", toLabel: "v3", diff: "diff2"),
        ]
        let md = formatCompareDocumentsMarkdown(
            documents: docs,
            docStats: stats,
            pairwiseDiffs: pairs
        )
        XCTAssertTrue(md.contains("# Manuscript Change Timeline"))
        XCTAssertTrue(md.contains("## Versions"))
        XCTAssertTrue(md.contains("v1 → v2"))
        XCTAssertTrue(md.contains("v2 → v3"))
    }

    func testCompareDocumentsSummaryOnly() {
        let docs = [DocumentRef(path: "/a", label: "a"), DocumentRef(path: "/b", label: "b")]
        let stats = [
            DocStats(label: "a", revisionCount: 0, commentCount: 0, wordCount: 10),
            DocStats(label: "b", revisionCount: 1, commentCount: 1, wordCount: 12),
        ]
        let md = formatCompareDocumentsMarkdown(
            documents: docs,
            docStats: stats,
            pairwiseDiffs: [],
            includePerPairDiff: false
        )
        XCTAssertTrue(md.contains("## Versions"))
        XCTAssertFalse(md.contains("Pairwise transitions"))
    }

    // MARK: - buildCommentThreads + formatCommentThreadsMarkdown

    func testCommentThreadingParentAndReply() {
        var parent = Comment(id: 1, author: "Alice", text: "parent comment", paragraphIndex: 0)
        let reply = Comment(id: 2, author: "Bob", text: "reply text", parentId: 1)
        let threads = buildCommentThreads(
            comments: [parent, reply],
            aliases: AuthorAliasMap([:])
        )
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].parent.id, 1)
        XCTAssertEqual(threads[0].replies.count, 1)
        XCTAssertEqual(threads[0].replies[0].id, 2)
        // Suppress unused warning
        _ = parent
    }

    func testCommentThreadingAliasNormalization() {
        let a = Comment(id: 1, author: "kllay's PC", text: "p", paragraphIndex: 0)
        let b = Comment(id: 2, author: "Lay", text: "r", parentId: 1)
        let threads = buildCommentThreads(
            comments: [a, b],
            aliases: AuthorAliasMap(["kllay's PC": "Lay", "Lay": "Lay"])
        )
        XCTAssertEqual(threads[0].parent.author, "Lay", "raw 'kllay's PC' canonicalized to 'Lay'")
        XCTAssertEqual(threads[0].replies[0].author, "Lay")
    }

    func testDetectOldPatternMatches() {
        let result = detectOldPattern(in: "Old: previous wording\nnew wording")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.quoted, "previous wording")
        XCTAssertEqual(result?.newWording, "new wording")
    }

    func testDetectOldPatternRejectsNonMatch() {
        XCTAssertNil(detectOldPattern(in: "Just a regular reply"))
    }

    func testCommentThreadsTableFormat() {
        let parent = Comment(id: 1, author: "Alice", text: "parent", paragraphIndex: 0)
        let threads = buildCommentThreads(comments: [parent], aliases: AuthorAliasMap([:]))
        let md = formatCommentThreadsMarkdown(threads: threads, format: .table)
        XCTAssertTrue(md.contains("# Comment Threads"))
        XCTAssertTrue(md.contains("| Alice"))
    }

    func testCommentThreadsThreadedFormat() {
        let parent = Comment(id: 1, author: "Alice", text: "parent", paragraphIndex: 0)
        let threads = buildCommentThreads(comments: [parent], aliases: AuthorAliasMap([:]))
        let md = formatCommentThreadsMarkdown(threads: threads, format: .threaded)
        XCTAssertTrue(md.contains("## Thread #1"))
    }

    func testCommentThreadsNarrativeFormat() {
        let parent = Comment(id: 1, author: "Alice", text: "parent", paragraphIndex: 0)
        let threads = buildCommentThreads(comments: [parent], aliases: AuthorAliasMap([:]))
        let md = formatCommentThreadsMarkdown(threads: threads, format: .narrative)
        // Note: paragraph context escapes `#`, so "Thread #1" appears as "Thread \\#1"
        XCTAssertTrue(md.contains("Thread"))
        XCTAssertTrue(md.contains("Alice"))
        XCTAssertTrue(md.contains("paragraph 0"))
    }
}
