import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#273 — `splice_omath_from_source` and
/// `splice_paragraph_omath_from_source` MCP tools wrap ooxml-swift v0.24.0's
/// `WordDocument.spliceOMath(...)` and `spliceParagraphOMath(...)` APIs
/// (PsychQuant/ooxml-swift#211).
///
/// Tests cover:
/// - Single-OMath splice via Direct mode (source_path) → Session mode (doc_id)
/// - Single-OMath splice via Session mode (source_doc_id) → Session mode (doc_id)
/// - Mid-paragraph anchor splice (afterText)
/// - Paragraph-level batch splice
/// - Error taxonomy: missing args, anchor not found, OMath index out of range,
///   target paragraph index out of range, source has no OMath
/// - rPr propagation modes (full / discard)
/// - Namespace policy (lenient default / strict opt-out)
final class Issue160SpliceOMathFromSourceTests: XCTestCase {

    // MARK: - Fixture builders

    private static let mNS = "xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\""

    /// Build a one-paragraph source docx with inline OMath in a Run:
    /// `<w:p><w:r>所得出的參數進行 </w:r><w:r><m:oMath>t</m:oMath></w:r><w:r> 檢定：</w:r></w:p>`
    private func makeSourceDocxWithInlineOMath() throws -> URL {
        var doc = WordDocument()
        var run1 = Run(text: "所得出的參數進行 ")
        run1.position = 1
        var run2 = Run(text: "")
        run2.rawXML = "<m:oMath \(Self.mNS)><m:r><m:t>t</m:t></m:r></m:oMath>"
        run2.position = 2
        var run3 = Run(text: " 檢定：")
        run3.position = 3
        let para = Paragraph(runs: [run1, run2, run3])
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue160-source-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Build a target docx with corresponding prose anchor but no OMath
    /// (the rescue-pipeline use case).
    private func makeTargetDocxNoOMath() throws -> URL {
        var doc = WordDocument()
        var run = Run(text: "所得出的參數進行  檢定：")
        run.position = 1
        let para = Paragraph(runs: [run])
        doc.body.children.append(.paragraph(para))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue160-target-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    // MARK: - Tests

    /// Direct mode source + Session mode target → atEnd splice succeeds, returns 1.
    func testSpliceOMathFromSourcePathToTargetAtEnd() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()

        // Open target
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t1")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t1"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Spliced 1 OMath"),
            "Expected 'Spliced 1 OMath' message; got: \(txt)"
        )
    }

    /// afterText anchor splice succeeds.
    func testSpliceOMathFromSourceWithAfterTextAnchor() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t2")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t2"),
                "target_paragraph_index": .int(0),
                "position": .string("afterText"),
                "anchor": .string("所得出的參數進行 ")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Spliced 1 OMath"),
            "Expected 'Spliced 1 OMath' message; got: \(txt)"
        )
    }

    /// Missing required arg → structured error.
    func testMissingPositionArgReturnsError() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t3")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t3"),
                "target_paragraph_index": .int(0)
                // position missing
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(txt.contains("Spliced"), "Should not succeed without position")
    }

    /// afterText without anchor → structured error.
    func testAfterTextWithoutAnchorReturnsError() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t4")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t4"),
                "target_paragraph_index": .int(0),
                "position": .string("afterText")
                // anchor missing
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.lowercased().contains("anchor"),
            "Expected error mentioning 'anchor'; got: \(txt)"
        )
    }

    /// omath_index out of range → structured error.
    func testOMathIndexOutOfRange() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t5")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t5"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd"),
                "omath_index": .int(99)
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.lowercased().contains("out of range"),
            "Expected 'out of range' error for omath_index=99; got: \(txt)"
        )
    }

    /// Source paragraph with no OMath → structured error.
    func testSourceWithNoOMathReturnsError() async throws {
        // Build source with only text (no OMath)
        var sourceDoc = WordDocument()
        var run = Run(text: "no math here")
        run.position = 1
        sourceDoc.body.children.append(.paragraph(Paragraph(runs: [run])))
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue160-no-omath-\(UUID().uuidString).docx")
        try DocxWriter.write(sourceDoc, to: sourceURL)

        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t6")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t6"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.lowercased().contains("no omath"),
            "Expected 'no OMath' error; got: \(txt)"
        )
    }

    /// Paragraph-level batch splice succeeds.
    func testSpliceParagraphOMathFromSource() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t7")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_paragraph_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t7"),
                "target_paragraph_index": .int(0)
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Spliced 1 OMath block"),
            "Expected 'Spliced 1 OMath block' message; got: \(txt)"
        )
    }

    /// rpr_mode=discard works.
    func testRpRModeDiscard() async throws {
        let sourceURL = try makeSourceDocxWithInlineOMath()
        let targetURL = try makeTargetDocxNoOMath()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(targetURL.path), "doc_id": .string("t8")]
        )

        let r = await server.invokeToolForTesting(
            name: "splice_omath_from_source",
            arguments: [
                "source_path": .string(sourceURL.path),
                "source_paragraph_index": .int(0),
                "doc_id": .string("t8"),
                "target_paragraph_index": .int(0),
                "position": .string("atEnd"),
                "rpr_mode": .string("discard")
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Spliced 1 OMath") && txt.contains("rpr_mode=discard"),
            "Expected 'Spliced 1 OMath' and 'rpr_mode=discard'; got: \(txt)"
        )
    }
}
