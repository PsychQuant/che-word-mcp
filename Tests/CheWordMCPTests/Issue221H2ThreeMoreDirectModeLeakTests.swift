import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#221 H2 (`review-cwm450.md` finding, code-review
/// identified, confirmed real by direct inspection here and fixed with the
/// same "one specific path" test technique #221's own tests use) — three
/// MORE independent Direct Mode (`source_path`) read paths that never
/// called `.close()` on the `WordDocument` they read, same root cause as
/// #221's `resolveDocument` and #221 H1's `revert_to_disk`/
/// `reload_from_disk`/`recover_from_autosave`:
///
/// - `resolveSourceParagraph` (`splice_omath_from_source` /
///   `splice_paragraph_omath_from_source`'s `source_path` branch) —
///   extracts one `Paragraph` by value and lets the whole `WordDocument`
///   (and its tempDir) fall out of scope unclosed.
/// - `loadDocumentFromArgs` (shared by 7 read-only tools: `list_content_controls`,
///   `get_content_control`, `get_style_inheritance_chain`,
///   `list_numbering_definitions`, `get_numbering_definition`,
///   `get_all_sections`, `get_section_header_map`) — returns the freshly
///   read `WordDocument` straight to the caller, never closed.
/// - `export_markdown` (`source_path` only, no session) — reads, converts,
///   writes the `.md` file, never closes.
final class Issue221H2ThreeMoreDirectModeLeakTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func archiveTempDir(event: String, from events: [WordMCPServer.DebugLogEvent]) throws -> String {
        let matches = events.filter { $0.event == event }
        XCTAssertEqual(matches.count, 1, "expected exactly one '\(event)' event, got \(matches.count)")
        let path = try XCTUnwrap(matches.first?.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
        XCTAssertNotEqual(path, "nil")
        return path
    }

    // MARK: - resolveSourceParagraph (splice_omath_from_source)

    private static let mNS = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""

    private func makeSourceDocxWithInlineOMath() throws -> URL {
        var doc = WordDocument()
        var run1 = Run(text: "prefix ")
        run1.position = 1
        var run2 = Run(text: "")
        run2.rawXML = "<m:oMath \(Self.mNS)><m:r><m:t>t</m:t></m:r></m:oMath>"
        run2.position = 2
        var run3 = Run(text: " suffix")
        run3.position = 3
        let para = Paragraph(runs: [run1, run2, run3])
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue221h2-source-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func makeTargetDocxNoOMath() throws -> URL {
        var doc = WordDocument()
        var run = Run(text: "prefix  suffix")
        run.position = 1
        let para = Paragraph(runs: [run])
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue221h2-target-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// RED (pre-fix): `splice_omath_from_source`'s Direct Mode
    /// `source_path` read (via `resolveSourceParagraph`) leaks its tempDir
    /// — the source document is never part of any session, so nothing
    /// ever closes it, ever, for the life of the server process.
    func testResolveSourceParagraphClosesDirectModeSourceRead() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer(forceDebugLogging: true)
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(targetURL.path), "doc_id": .string("t1")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t1"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        let events = await server.debugEventLogForTesting()
        let sourceArchive = try archiveTempDir(event: "resolveSourceParagraph.archiveExtracted", from: events)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sourceArchive),
            "resolveSourceParagraph's Direct Mode (source_path) read must release its own tempDir — leaked at: \(sourceArchive)"
        )
    }

    /// `source_doc_id` (an already-open SESSION document, not a fresh
    /// Direct Mode read) must NEVER be closed by this function — doing so
    /// would delete the tempDir out from under the still-active session
    /// (ooxml-swift's `PreservedArchive` is a class; every copy of the
    /// `WordDocument` shares the same underlying cleanup state). This test
    /// pins that the fix's `isTemporary` gate is actually gating, not
    /// unconditionally closing.
    func testResolveSourceParagraphDoesNotCloseAnAlreadyOpenSessionSource() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer(forceDebugLogging: true)
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(sourceURL.path), "doc_id": .string("s1")]
        )
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(targetURL.path), "doc_id": .string("t1")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_doc_id": .string("s1"),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t1"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd"),
            ]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        // The source session must still be fully usable afterward — if its
        // archive had been wrongly closed, a subsequent read-affecting
        // operation on it would misbehave or its archive path would be gone
        // while the session is still nominally open.
        let events = await server.debugEventLogForTesting()
        let sourceOpenArchive = try archiveTempDir(event: "openDocument.archiveExtracted", from: events.filter {
            $0.keyValues.contains { $0.0 == "doc_id" && $0.1 == "s1" }
        })
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceOpenArchive),
            "source_doc_id's already-open session archive must NOT be closed by resolveSourceParagraph"
        )
        let closedSource = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("s1")])
        XCTAssertFalse(closedSource.isError == true, textOf(closedSource))
    }

    // MARK: - loadDocumentFromArgs (list_content_controls)

    private func docxWithOneContentControl() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue221h2-cc-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// RED (pre-fix): `list_content_controls` via Direct Mode
    /// (`source_path`) leaks its tempDir through the shared
    /// `loadDocumentFromArgs` helper.
    func testLoadDocumentFromArgsClosesDirectModeRead() async throws {
        let url = try docxWithOneContentControl()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        let r = await server.invokeToolForTesting(
            name: "list_content_controls", arguments: ["source_path": .string(url.path)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        let events = await server.debugEventLogForTesting()
        let archive = try archiveTempDir(event: "loadDocumentFromArgs.archiveExtracted", from: events)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archive),
            "loadDocumentFromArgs's Direct Mode (source_path) read must release its own tempDir — leaked at: \(archive)"
        )
    }

    /// Same shared helper, a DIFFERENT one of its 7 callers
    /// (`get_all_sections`) — confirms the fix is centralized in
    /// `loadDocumentFromArgs`, not accidentally tool-specific.
    func testLoadDocumentFromArgsClosesDirectModeReadForADifferentCaller() async throws {
        let url = try docxWithOneContentControl()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        let r = await server.invokeToolForTesting(
            name: "get_all_sections", arguments: ["source_path": .string(url.path)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        let events = await server.debugEventLogForTesting()
        let archive = try archiveTempDir(event: "loadDocumentFromArgs.archiveExtracted", from: events)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive))
    }

    // MARK: - exportMarkdown

    /// RED (pre-fix): `export_markdown` leaks its Direct Mode tempDir.
    func testExportMarkdownClosesDirectModeRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("issue221h2-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello markdown")])))
        let sourceURL = dir.appendingPathComponent("source.docx")
        try DocxWriter.write(doc, to: sourceURL)
        let outputPath = dir.appendingPathComponent("out.md").path

        let server = await WordMCPServer(forceDebugLogging: true)
        let r = await server.invokeToolForTesting(
            name: "export_markdown",
            arguments: ["source_path": .string(sourceURL.path), "path": .string(outputPath)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath), "sanity: the export must have actually written the .md file")

        let events = await server.debugEventLogForTesting()
        let archive = try archiveTempDir(event: "exportMarkdown.archiveExtracted", from: events)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archive),
            "export_markdown's Direct Mode read must release its own tempDir — leaked at: \(archive)"
        )
    }
}
