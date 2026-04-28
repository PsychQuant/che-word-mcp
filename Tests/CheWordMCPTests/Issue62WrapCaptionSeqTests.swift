import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#62 Phase 2 — `wrap_caption_seq` MCP tool.
///
/// Phase 1 shipped the lib API (`WordDocument.wrapCaptionSequenceFields`) in
/// ooxml-swift v0.21.0. Phase 2 (this) adds the MCP wrapper so callers can
/// rescue plain-text caption numbering on docs pasted from external sources
/// (LaTeX-converted Word, Google Docs, Pandoc) before running
/// `insert_table_of_figures` / `insert_table_of_tables`.
///
/// Spec scenarios live at
/// `openspec/changes/wrap-caption-seq/specs/che-word-mcp-field-equation-crud/spec.md`.
final class Issue62WrapCaptionSeqTests: XCTestCase {

    // MARK: - 2.5.1 End-to-end on three figure captions (spec Scenario 1)

    func testWrapCaptionSeqEndToEndOnThreeFigureCaptions() async throws {
        let url = try docxWithThreeFigureCaptionsPlusFiller()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p62a")]
        )

        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62a"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )

        let body = textOf(r)
        XCTAssertFalse(r.isError ?? false, "unexpected error: \(body)")
        let json = try parseJSON(body)
        XCTAssertEqual(json["matched_paragraphs"] as? Int, 3,
                       "spec Scenario 1 — 3 figure captions matched. body=\(body)")
        XCTAssertEqual(json["fields_inserted"] as? Int, 3)
        let modified = json["paragraphs_modified"] as? [Int] ?? []
        XCTAssertEqual(modified.count, 3, "3 paragraphs modified, in document order")
        let skipped = json["skipped"] as? [[String: Any]] ?? []
        XCTAssertTrue(skipped.isEmpty, "no skips on first run, got: \(skipped)")

        // Re-running on the same doc must report all 3 in skipped (idempotency
        // proves the SEQ fields really landed; lib-level tests cover
        // cachedResult preservation directly via flattenedDisplayText).
        let r2 = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62a"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )
        let json2 = try parseJSON(textOf(r2))
        XCTAssertEqual(json2["fields_inserted"] as? Int, 0, "second run inserts no new fields")
        XCTAssertEqual((json2["skipped"] as? [[String: Any]])?.count, 3,
                       "second run reports all 3 as skipped — proves SEQ fields landed")
    }

    // MARK: - 2.5.2 Idempotent re-run (spec Scenario 2)

    func testWrapCaptionSeqIdempotentReRun() async throws {
        let url = try docxWithThreeFigureCaptionsPlusFiller()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p62b")]
        )

        // First run wraps everything.
        _ = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62b"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )

        // Second run — all 3 should report skipped, none modified.
        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62b"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )

        let body = textOf(r)
        XCTAssertFalse(r.isError ?? false, "unexpected error: \(body)")
        let json = try parseJSON(body)
        XCTAssertEqual(json["matched_paragraphs"] as? Int, 3, "matched count survives idempotency")
        XCTAssertEqual(json["fields_inserted"] as? Int, 0, "no new fields inserted on re-run")
        XCTAssertEqual((json["paragraphs_modified"] as? [Int])?.count ?? -1, 0,
                       "no paragraphs modified on re-run")
        let skipped = json["skipped"] as? [[String: Any]] ?? []
        XCTAssertEqual(skipped.count, 3, "all 3 captions reported in skipped")
        for s in skipped {
            XCTAssertEqual(s["reason"] as? String, "already wraps SEQ Figure")
            XCTAssertNotNil(s["paragraph_index"] as? Int)
        }
    }

    // MARK: - 2.5.3 Pattern with zero capture groups rejected (spec Scenario 3)

    func testWrapCaptionSeqRejectsZeroCaptureGroupPattern() async throws {
        let url = try docxWithSingleCaption()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p62c")]
        )

        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62c"),
                "pattern": .string(#"圖 4-\d+:"#),  // no parens — 0 capture groups
                "sequence_name": .string("Figure")
            ]
        )

        let body = textOf(r)
        XCTAssertEqual(
            body,
            "Error: wrap_caption_seq: pattern must contain exactly one capture group, got 0",
            "spec Scenario 3 — exact error string per #70 tool-prefix convention"
        )

        // Document MUST be unmodified — a follow-up valid wrap call should
        // still find the caption (proves no partial mutation happened).
        let r2 = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62c"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )
        let json2 = try parseJSON(textOf(r2))
        XCTAssertEqual(json2["matched_paragraphs"] as? Int, 1,
                       "the rejected call left the document untouched, so the caption is still findable")
        XCTAssertEqual(json2["fields_inserted"] as? Int, 1)
    }

    // MARK: - 2.5.4 insert_bookmark = true without bookmark_template rejected
    //         (spec Scenario 5)

    func testWrapCaptionSeqRejectsBookmarkTrueWithoutTemplate() async throws {
        let url = try docxWithSingleCaption()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p62d")]
        )

        let r = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62d"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure"),
                "insert_bookmark": .bool(true)
                // bookmark_template intentionally missing
            ]
        )

        XCTAssertEqual(
            textOf(r),
            "Error: wrap_caption_seq: bookmark_template required when insert_bookmark is true",
            "spec Scenario 5 — exact error string"
        )
    }

    // MARK: - 2.5.5 After-call enables update_all_fields + insert_table_of_figures

    func testWrapCaptionSeqAfterCallEnablesUpdateAllFieldsAndTOF() async throws {
        let url = try docxWithThreeFigureCaptionsPlusFiller()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p62e")]
        )

        // Wrap captions in SEQ fields.
        let wrapR = await server.invokeToolForTesting(
            name: "wrap_caption_seq",
            arguments: [
                "doc_id": .string("p62e"),
                "pattern": .string(#"圖 4-(\d+):"#),
                "sequence_name": .string("Figure")
            ]
        )
        XCTAssertFalse(wrapR.isError ?? false, "wrap_caption_seq must succeed: \(textOf(wrapR))")

        // F9-equivalent re-numbering should now find these SEQ fields and
        // succeed without error. update_all_fields returns a JSON map of
        // identifier → final-count when SEQ fields exist.
        let updR = await server.invokeToolForTesting(
            name: "update_all_fields",
            arguments: ["doc_id": .string("p62e")]
        )
        XCTAssertFalse(updR.isError ?? false, "update_all_fields must succeed: \(textOf(updR))")

        // Insert TOF — must succeed without error (the wrapped SEQ fields are
        // what the TOF generator scans for). insert_table_of_figures requires
        // a paragraph_index anchor.
        let tofR = await server.invokeToolForTesting(
            name: "insert_table_of_figures",
            arguments: [
                "doc_id": .string("p62e"),
                "caption_label": .string("Figure"),
                "paragraph_index": .int(0)
            ]
        )
        XCTAssertFalse(tofR.isError ?? false, "insert_table_of_figures must succeed: \(textOf(tofR))")
    }

    // MARK: - Helpers

    private func docxWithThreeFigureCaptionsPlusFiller() throws -> URL {
        var doc = WordDocument()
        doc.body.children = [
            .paragraph(Paragraph(runs: [Run(text: "圖 4-1:架構圖")])),
            .paragraph(Paragraph(runs: [Run(text: "圖 4-2:流程圖")])),
            .paragraph(Paragraph(runs: [Run(text: "圖 4-3:時序圖")])),
            .paragraph(Paragraph(runs: [Run(text: "lorem ipsum")])),
            .paragraph(Paragraph(runs: [Run(text: "dolor sit amet")])),
            .paragraph(Paragraph(runs: [Run(text: "consectetur adipiscing")])),
            .paragraph(Paragraph(runs: [Run(text: "elit sed do")])),
            .paragraph(Paragraph(runs: [Run(text: "eiusmod tempor")]))
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue62_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func docxWithSingleCaption() throws -> URL {
        var doc = WordDocument()
        doc.body.children = [
            .paragraph(Paragraph(runs: [Run(text: "圖 4-7:架構圖")]))
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue62_single_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func parseJSON(_ s: String) throws -> [String: Any] {
        guard let data = s.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("body is not valid JSON: \(s)")
            return [:]
        }
        return obj
    }
}
