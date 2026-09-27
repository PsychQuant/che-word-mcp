import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#240 — ~500 string parameters were read with
/// plain `?.stringValue ?? default`, so BOTH a wrong JSON type (e.g.
/// `wrap_type: 5`) AND a well-typed-but-unrecognized value (e.g.
/// `wrap_type: "bogus"`) silently substituted the tool's default instead of
/// reporting an error — the same failure shape #232 closed for integer and
/// boolean parameters. This closes the highest-impact batch: every
/// parameter that ALREADY declares a JSON Schema `"enum"` in `tools/list`
/// (`compare_documents.mode`, `export_revision_summary_markdown.group_by`,
/// `compare_documents_markdown.diff_format`,
/// `export_comment_threads_markdown.format`, `wrap_caption_seq.format`,
/// `wrap_caption_seq.scope`), plus the issue's own flagship example
/// (`insert_floating_image.wrap_type`, which did not declare an `enum`
/// before this fix — now it does, see the Issue236 schema tests for the
/// full `items`/`enum` shape audit).
///
/// Full audit status: PARTIAL. The remaining ~500 plain-string reads are
/// NOT closed by this issue (see the delivery report for the enumerated
/// remainder) — this file exercises exactly the batch fixed here.
final class Issue240StrictEnumStringParameterTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func simpleFixtureURL(paragraphText: String = "Hello") throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: paragraphText)])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue240_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - insert_floating_image.wrap_type

    func testInsertFloatingImageRejectsWrongTypeWrapType() async throws {
        let server = await WordMCPServer()
        let docId = "i240-wt-a"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(docId)])

        let r = await server.invokeToolForTesting(
            name: "insert_floating_image",
            arguments: ["doc_id": .string(docId), "path": .string("/nonexistent.png"), "wrap_type": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "wrap_type: 5 (wrong type) must be rejected before file read. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("wrap_type"), textOf(r))
    }

    func testInsertFloatingImageRejectsUnrecognizedWrapTypeValue() async throws {
        let server = await WordMCPServer()
        let docId = "i240-wt-b"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(docId)])

        let r = await server.invokeToolForTesting(
            name: "insert_floating_image",
            arguments: ["doc_id": .string(docId), "path": .string("/nonexistent.png"), "wrap_type": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "wrap_type: 'bogus' (unrecognized value) must be rejected before file read. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("wrap_type"), textOf(r))
    }

    // MARK: - compare_documents.mode

    func testCompareDocumentsRejectsWrongTypeMode() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-a1")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-a1"), "text": .string("Hi")]
        )
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-a2")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-a2"), "text": .string("Hi")]
        )

        let r = await server.invokeToolForTesting(
            name: "compare_documents",
            arguments: ["doc_id_a": .string("i240-cmp-a1"), "doc_id_b": .string("i240-cmp-a2"), "mode": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "mode: 5 (wrong type) must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("mode"), textOf(r))
    }

    func testCompareDocumentsRejectsUnrecognizedModeValue() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-b1")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-b1"), "text": .string("Hi")]
        )
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-b2")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-b2"), "text": .string("Hi")]
        )

        let r = await server.invokeToolForTesting(
            name: "compare_documents",
            arguments: ["doc_id_a": .string("i240-cmp-b1"), "doc_id_b": .string("i240-cmp-b2"), "mode": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "mode: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("mode"), textOf(r))
    }

    func testCompareDocumentsAcceptsValidMode() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-c1")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-c1"), "text": .string("Hi")]
        )
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("i240-cmp-c2")])
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string("i240-cmp-c2"), "text": .string("Hi")]
        )

        let r = await server.invokeToolForTesting(
            name: "compare_documents",
            arguments: ["doc_id_a": .string("i240-cmp-c1"), "doc_id_b": .string("i240-cmp-c2"), "mode": .string("structure")]
        )
        XCTAssertNotEqual(r.isError, true, "mode: 'structure' is a valid enum value and must still succeed. Got: \(textOf(r))")
    }

    // MARK: - export_revision_summary_markdown.group_by

    func testExportRevisionSummaryMarkdownRejectsWrongTypeGroupBy() async throws {
        let url = try simpleFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-grp-a")]
        )
        let r = await server.invokeToolForTesting(
            name: "export_revision_summary_markdown",
            arguments: ["doc_id": .string("i240-grp-a"), "group_by": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "group_by: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("group_by"), textOf(r))
    }

    func testExportRevisionSummaryMarkdownRejectsUnrecognizedGroupByValue() async throws {
        let url = try simpleFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-grp-b")]
        )
        let r = await server.invokeToolForTesting(
            name: "export_revision_summary_markdown",
            arguments: ["doc_id": .string("i240-grp-b"), "group_by": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "group_by: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("group_by"), textOf(r))
    }

    // MARK: - compare_documents_markdown.diff_format

    func testCompareDocumentsMarkdownRejectsWrongTypeDiffFormat() async throws {
        let urlA = try simpleFixtureURL(paragraphText: "A")
        let urlB = try simpleFixtureURL(paragraphText: "B")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let server = await WordMCPServer()
        let r = await server.invokeToolForTesting(
            name: "compare_documents_markdown",
            arguments: [
                "documents": .array([
                    .object(["path": .string(urlA.path), "label": .string("v1")]),
                    .object(["path": .string(urlB.path), "label": .string("v2")])
                ]),
                "diff_format": .int(5)
            ]
        )
        XCTAssertEqual(r.isError, true, "diff_format: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("diff_format"), textOf(r))
    }

    func testCompareDocumentsMarkdownRejectsUnrecognizedDiffFormatValue() async throws {
        let urlA = try simpleFixtureURL(paragraphText: "A")
        let urlB = try simpleFixtureURL(paragraphText: "B")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }
        let server = await WordMCPServer()
        let r = await server.invokeToolForTesting(
            name: "compare_documents_markdown",
            arguments: [
                "documents": .array([
                    .object(["path": .string(urlA.path), "label": .string("v1")]),
                    .object(["path": .string(urlB.path), "label": .string("v2")])
                ]),
                "diff_format": .string("bogus")
            ]
        )
        XCTAssertEqual(r.isError, true, "diff_format: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("diff_format"), textOf(r))
    }

    // MARK: - export_comment_threads_markdown.format

    func testExportCommentThreadsMarkdownRejectsWrongTypeFormat() async throws {
        let url = try simpleFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-fmt-a")]
        )
        let r = await server.invokeToolForTesting(
            name: "export_comment_threads_markdown",
            arguments: ["doc_id": .string("i240-fmt-a"), "format": .int(5)]
        )
        XCTAssertEqual(r.isError, true, "format: 5 must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("format"), textOf(r))
    }

    func testExportCommentThreadsMarkdownRejectsUnrecognizedFormatValue() async throws {
        let url = try simpleFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-fmt-b")]
        )
        let r = await server.invokeToolForTesting(
            name: "export_comment_threads_markdown",
            arguments: ["doc_id": .string("i240-fmt-b"), "format": .string("bogus")]
        )
        XCTAssertEqual(r.isError, true, "format: 'bogus' must be rejected. Got: \(textOf(r))")
        XCTAssertTrue(textOf(r).contains("format"), textOf(r))
    }

    // MARK: - wrap_caption_seq.format / .scope (type-only; value already validated pre-fix)

    func testWrapCaptionSeqRejectsWrongTypeFormat() async throws {
        let url = try simpleFixtureURL(paragraphText: "Figure 1. hi")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-wcs-a")]
        )
        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("i240-wcs-a"), "pattern": .string(#"Figure (\d+)\."#),
                "sequence_name": .string("Figure"), "format": .int(5)
            ]
        )
        XCTAssertEqual(r.isError, true, "format: 5 must be rejected. Got: \(textOf(r))")
    }

    func testWrapCaptionSeqRejectsWrongTypeScope() async throws {
        let url = try simpleFixtureURL(paragraphText: "Figure 1. hi")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("i240-wcs-b")]
        )
        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("i240-wcs-b"), "pattern": .string(#"Figure (\d+)\."#),
                "sequence_name": .string("Figure"), "scope": .int(5)
            ]
        )
        XCTAssertEqual(r.isError, true, "scope: 5 must be rejected. Got: \(textOf(r))")
    }

    // MARK: - Coverage: every schema-declared enum string param is exercised above

    /// Trip-wire (#236/#240 shared spirit): scans the live `tools/list`
    /// schema for every property with a JSON Schema `"enum"` and asserts it
    /// is exactly the set this file exercises above. If a future PR adds a
    /// NEW `enum`-declared string parameter without adding a matching
    /// strict-validation behavior test here, this fails and says so.
    func testEnumDeclaredParametersMatchExercisedSet() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var found: Set<String> = []
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            for (paramName, paramSchema) in properties {
                guard case .object(let paramObj) = paramSchema, paramObj["enum"] != nil else { continue }
                found.insert("\(tool.name).\(paramName)")
            }
        }

        // Deliberately TOP-LEVEL only: `replace_text_batch.replacements`'s
        // `items.properties.scope` also declares an `enum`, but this shallow
        // scan intentionally does not descend into `items` — nested
        // item-level enums are out of scope for this tools/list-level
        // trip-wire (the batch tool's own per-item loop already validates
        // that field independently of this issue).
        let expectedTopLevel: Set<String> = [
            "insert_floating_image.wrap_type",
            "compare_documents.mode",
            "export_revision_summary_markdown.group_by",
            "compare_documents_markdown.diff_format",
            "export_comment_threads_markdown.format",
            "wrap_caption_seq.format",
            "wrap_caption_seq.scope",
            // `profile` (create_document / open_document / execute_script,
            // all sharing `documentProfileSchema`) already declared `enum`
            // and was ALREADY strictly validated (`resolveDocumentProfile`
            // in DocumentProfileTools.swift rejects both wrong type and
            // wrong value) before #240 — pre-existing, not part of this
            // issue's fix batch, included here only so this trip-wire
            // reflects the FULL current enum surface rather than silently
            // ignoring three real entries.
            "create_document.profile",
            "open_document.profile",
            "execute_script.profile"
        ]

        XCTAssertEqual(
            found, expectedTopLevel,
            "tools/list top-level enum-declared string parameters changed — add/remove a matching strict-validation test in this file. Found: \(found.sorted()), expected: \(expectedTopLevel.sorted())"
        )
    }
}
