import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#98 — `insert_equation` MCP handler currently bypasses
/// the lib `WordDocument.insertEquation(at: InsertLocation, latex:, displayMode:)`
/// overload (added in #84/#91). Three bug surfaces:
///
/// 1. **Silent-clamp** on out-of-range `paragraph_index` — handler calls the
///    non-throwing `insertParagraph(_:at: Int)` overload which silently clamps
///    to the last paragraph (`Document.swift:266-270`). User sees a success
///    message but the equation lands in the wrong place.
/// 2. **Lib overload bypass** — handler self-builds OMML and routes through
///    `insertParagraph` directly for all anchor types, never delegating to the
///    lib overload that handles bounds-check + structured errors centrally.
/// 3. **Inline mode structural bug** — handler always wraps the OMML run in a
///    NEW `Paragraph(runs: [eqRun])` (Server.swift:8919) regardless of
///    `display_mode`. Lib semantics: inline mode appends the OMML run to the
///    EXISTING paragraph at `paragraph_index`. Current behavior creates a new
///    paragraph for inline equations, which is structurally wrong.
///
/// These RED tests pin the post-fix contract: structured `Error: insert_equation: ...`
/// strings on bad input + correct inline-mode append semantics.
final class Issue98InsertEquationLibBypassTests: XCTestCase {

    /// Five-paragraph fixture so we have stable indices to anchor against.
    private func minimalDocxFiveParas() throws -> URL {
        var doc = WordDocument()
        for i in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "para\(i)")])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue98_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    // MARK: - Test 1: inline mode + out-of-range paragraph_index → structured error

    func testInlineModeWithOutOfRangeIndexReturnsStructuredError() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98a")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98a"),
                "latex": .string("x"),
                "display_mode": .bool(false),
                "paragraph_index": .int(9999)
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "inline mode + out-of-range paragraph_index must NOT silent-success; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("out of range") || txt.lowercased().contains("invalid"),
            "expected structured error mentioning 'out of range' or 'invalid'; got: \(txt)"
        )
    }

    // MARK: - Test 2: inline mode without paragraph_index → structured error

    func testInlineModeWithoutParagraphIndexReturnsStructuredError() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98b")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98b"),
                "latex": .string("x"),
                "display_mode": .bool(false)
                // no anchor at all → lib should reject inline w/o paragraph_index
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "inline mode without paragraph_index must NOT silently append at end; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("inline") && txt.contains("paragraph_index"),
            "expected structured error mentioning 'inline' + 'paragraph_index'; got: \(txt)"
        )
    }

    // MARK: - Test 3: display mode + out-of-range paragraph_index → structured error

    func testDisplayModeWithOutOfRangeIndexReturnsStructuredError() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98c")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98c"),
                "latex": .string("a^2 + b^2 = c^2"),
                "display_mode": .bool(true),
                "paragraph_index": .int(9999)
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "display mode + out-of-range paragraph_index must NOT silent-clamp; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("out of range") || txt.lowercased().contains("invalid"),
            "expected structured error mentioning 'out of range' or 'invalid'; got: \(txt)"
        )
    }

    // MARK: - Test 4: inline mode + valid index → OMML run APPENDED to existing
    //         paragraph (NOT new paragraph created). BREAKING vs current handler.

    func testInlineModeWithValidIndexAppendsOMMLRunToExistingParagraph() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98d")]
        )

        // Snapshot baseline: 5 paragraphs, paragraph 0 has 1 run.
        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98d"),
                "latex": .string("x"),
                "display_mode": .bool(false),
                "paragraph_index": .int(0)
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Inserted equation"),
            "inline mode + valid paragraph_index should succeed; got: \(txt)"
        )

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("e98d"), "path": .string(savePath)]
        )

        // Re-open the saved file to inspect on-disk structure.
        // Note: lib's inline-mode legacy delegate (Document.swift:4063-4064)
        // assigns `run.properties.rawXML = OMML`, which `Run.toXML()` serializes
        // unwrapped — the OMML lands as a direct child of `<w:p>` rather than
        // wrapped in `<w:r>`. On read-back the cluster #99-#103 fix preserves
        // it via `Paragraph.unrecognizedChildren` and surfaces it via
        // `flattenedDisplayText()`. The semantic contract from the caller's
        // perspective: paragraph 0 still exists, no new paragraph was inserted,
        // and paragraph 0's display text grew to include the equation content.
        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        let paras = saved.body.children.compactMap { (child) -> Paragraph? in
            if case .paragraph(let p) = child { return p }
            return nil
        }
        XCTAssertEqual(
            paras.count, 5,
            "inline mode must NOT add a new paragraph; expected 5 paragraphs (BREAKING vs pre-fix); got: \(paras.count)"
        )
        let para0Flat = paras[0].flattenedDisplayText()
        XCTAssertTrue(
            para0Flat.contains("para0"),
            "paragraph 0 must still contain original 'para0' text after inline append; got: \(para0Flat)"
        )
        XCTAssertNotEqual(
            para0Flat, "para0",
            "paragraph 0's flattened text must grow beyond 'para0' to include OMML content (post-cluster #99-#103 walker sees direct-child OMML); got: \(para0Flat)"
        )
    }

    // MARK: - Test 5: components path + out-of-range paragraph_index → structured error

    func testComponentsPathSilentClampReplaced() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98e")]
        )

        // Components-tree path (not latex). Single run component is enough to
        // exercise the components branch of the handler fork.
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98e"),
                "components": .object([
                    "type": .string("run"),
                    "text": .string("x")
                ]),
                "display_mode": .bool(true),
                "paragraph_index": .int(9999)
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "components path + out-of-range paragraph_index must NOT silent-clamp; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("out of range") || txt.lowercased().contains("invalid"),
            "expected structured error mentioning 'out of range' or 'invalid'; got: \(txt)"
        )
    }

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
