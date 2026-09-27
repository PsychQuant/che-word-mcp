import XCTest
import MCP
import OOXMLSwift
import ZIPFoundation
@testable import CheWordMCP

/// #134 — `bulkResolveComments`/`replyToComment` mark `word/commentsExtended.xml`
/// dirty when a document transitions from "no extended comment state" to
/// "has extended comment state" (its first `done`/reply), but the ooxml-swift
/// overlay writer's `hasNewTypedParts`/`hasNewTypedRelationships` gates never
/// checked `comments.hasExtendedComments` — so the part's bytes landed in the
/// zip archive without a matching `[Content_Types].xml` Override or
/// `word/_rels/document.xml.rels` relationship. Word ignores an OPC part that
/// isn't declared that way, so the done/reply state was silently dropped on
/// the next open in Word even though che-word-mcp's own reader (which reads
/// parts by path, not through OPC declarations) reported it correctly —
/// which is exactly why this needs a raw-zip inspection, not a round-trip
/// through `open_document` again (see `CreateDocumentTrackChangesDefaultTests`
/// for the same "the claim that matters is about the saved bytes" pattern).
///
/// Root cause is cross-repo (ooxml-swift's `DocxWriter.swift`); this test
/// pins the che-word-mcp-side workaround (`markCommentsExtendedTypedPartsDirtyIfNeeded`),
/// which marks `[Content_Types].xml` and `word/_rels/document.xml.rels` dirty
/// alongside `word/commentsExtended.xml` itself whenever the document now has
/// extended comment state — `WordDocument.markPartDirty` is documented as the
/// sanctioned external-consumer escape hatch for exactly this shape of gap.
final class Issue134CommentsExtendedTypedPartsTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Issue134-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func text(_ r: CallTool.Result?) -> String {
        guard let c = r?.content.first, case .text(let t) = c else { return "" }
        return t.text
    }

    private struct PackageParts {
        let contentTypes: String
        let documentRels: String
        let hasCommentsExtendedFile: Bool
        let commentsExtended: String
    }

    private func readParts(of path: String) throws -> PackageParts {
        let archive = try Archive(url: URL(fileURLWithPath: path), accessMode: .read)
        func extract(_ name: String) -> String {
            guard let entry = archive[name] else { return "" }
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            return String(decoding: data, as: UTF8.self)
        }
        return PackageParts(
            contentTypes: extract("[Content_Types].xml"),
            documentRels: extract("word/_rels/document.xml.rels"),
            hasCommentsExtendedFile: archive["word/commentsExtended.xml"] != nil,
            commentsExtended: extract("word/commentsExtended.xml")
        )
    }

    /// Baseline fixture: two plain top-level comments, no reply, no `done`.
    /// This is the shape #134's Problem section describes as the trigger —
    /// "文件從來沒有 extended part" — and it's also what `writeCommentFixture()`
    /// in `CommentReviewWorkflowToolsTests` already builds, kept local here so
    /// this file has no cross-file test-helper dependency.
    private func writeBaselineFixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(text: "First paragraph")))
        doc.body.children.append(.paragraph(Paragraph(text: "Second paragraph")))
        doc.comments.addComment(Comment(id: 1, author: "Reviewer", text: "Please fix", paragraphIndex: 0))
        doc.comments.addComment(Comment(id: 2, author: "Reviewer", text: "Still open", paragraphIndex: 1))

        let url = tempDir.appendingPathComponent("baseline.docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    func testBaselineFixtureHasNoExtendedCommentsPart() throws {
        let url = try writeBaselineFixture()
        let parts = try readParts(of: url.path)
        XCTAssertFalse(parts.hasCommentsExtendedFile,
                       "sanity check: the baseline fixture must start with no commentsExtended.xml at all")
    }

    func testBulkResolveCommentsDeclaresCommentsExtendedInContentTypesAndRels() async throws {
        let url = try writeBaselineFixture()
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d134")]
        )
        let resolved = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string("d134"), "comment_ids": .array([.int(1)])]
        )
        XCTAssertTrue(text(resolved).contains(#""resolved":1"#), text(resolved))

        let outPath = tempDir.appendingPathComponent("resolved.docx").path
        let saved = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d134"), "path": .string(outPath)]
        )
        XCTAssertFalse(text(saved).lowercased().contains("error"), text(saved))

        let parts = try readParts(of: outPath)
        XCTAssertTrue(parts.hasCommentsExtendedFile,
                     "the part itself SHALL be written")
        XCTAssertTrue(parts.commentsExtended.contains(#"w15:done="1""#),
                     "the written part SHALL record the done state, got: \(parts.commentsExtended)")
        XCTAssertTrue(parts.contentTypes.contains("/word/commentsExtended.xml"),
                     "[Content_Types].xml SHALL declare an Override for commentsExtended.xml so Word does not ignore it, got: \(parts.contentTypes)")
        XCTAssertTrue(parts.documentRels.contains("commentsExtended"),
                     "word/_rels/document.xml.rels SHALL declare a relationship to commentsExtended.xml, got: \(parts.documentRels)")
    }

    func testReplyToCommentDeclaresCommentsExtendedInContentTypesAndRels() async throws {
        let url = try writeBaselineFixture()
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d134reply")]
        )
        let reply = await server.invokeToolForTesting(
            name: "add_comment_reply",
            arguments: ["doc_id": .string("d134reply"), "comment_id": .int(1), "text": .string("Ack")]
        )
        XCTAssertTrue(text(reply).contains("Added reply"), text(reply))

        let outPath = tempDir.appendingPathComponent("replied.docx").path
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d134reply"), "path": .string(outPath)]
        )

        let parts = try readParts(of: outPath)
        XCTAssertTrue(parts.hasCommentsExtendedFile)
        XCTAssertTrue(parts.contentTypes.contains("/word/commentsExtended.xml"),
                     "got: \(parts.contentTypes)")
        XCTAssertTrue(parts.documentRels.contains("commentsExtended"),
                     "got: \(parts.documentRels)")
    }

    /// Unrelated parts (theme, webSettings, etc.) that overlay mode normally
    /// preserves verbatim must survive the workaround too — marking
    /// `[Content_Types].xml` dirty routes through `ContentTypesOverlay`,
    /// which merges rather than replaces, but this is exactly the kind of
    /// silent regression a narrower "does commentsExtended exist" assertion
    /// would miss.
    func testContentTypesStillDeclaresCoreOverridesAfterTheWorkaround() async throws {
        let url = try writeBaselineFixture()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("d134ct")]
        )
        _ = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string("d134ct"), "comment_ids": .array([.int(1)])]
        )
        let outPath = tempDir.appendingPathComponent("ct.docx").path
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d134ct"), "path": .string(outPath)]
        )
        let parts = try readParts(of: outPath)
        XCTAssertTrue(parts.contentTypes.contains("document.xml"), parts.contentTypes)
        XCTAssertTrue(parts.contentTypes.contains("comments.xml") || parts.contentTypes.contains("wordprocessingml.comments"),
                     parts.contentTypes)
    }
}
