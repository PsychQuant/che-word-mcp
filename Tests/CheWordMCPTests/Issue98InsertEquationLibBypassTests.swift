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

    // MARK: - Test 4: inline mode + valid index → OMML APPENDED to existing
    //         paragraph (NOT new paragraph created). BREAKING vs pre-fix.
    //
    // v2 (post-verify): handler-side OMML append. Test asserts OMML structure
    // survives round-trip rather than just flatten-text inequality (which had
    // a hidden cluster #99-#103 walker dependency per Devil's Advocate finding).

    func testInlineModeWithValidIndexAppendsOMMLRunToExistingParagraph() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98d")]
        )

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

        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        let paras = saved.body.children.compactMap { (child) -> Paragraph? in
            if case .paragraph(let p) = child { return p }
            return nil
        }
        XCTAssertEqual(
            paras.count, 5,
            "inline mode must NOT add a new paragraph; expected 5 paragraphs (BREAKING vs pre-fix); got: \(paras.count)"
        )
        // Original 'para0' text must still be present.
        XCTAssertTrue(
            paras[0].runs.contains(where: { $0.text == "para0" }),
            "paragraph 0 must still contain original 'para0' run after inline append"
        )
        // OMML structure must survive in EITHER runs[].rawXML / runs[].properties.rawXML
        // OR direct-child via unrecognizedChildren (Run.toXML emits rawXML unwrapped,
        // so it can land as direct-child <w:p> on round-trip).
        let runRawOMML = paras[0].runs.contains { run in
            (run.rawXML?.contains("<m:oMath") ?? false)
                || (run.properties.rawXML?.contains("<m:oMath") ?? false)
        }
        let directChildOMML = paras[0].unrecognizedChildren.contains { child in
            child.name == "oMath" || child.name == "oMathPara"
                || child.rawXML.contains("<m:oMath")
        }
        XCTAssertTrue(
            runRawOMML || directChildOMML,
            "paragraph 0 must carry OMML in either runs or direct-child after inline append; runs=\(paras[0].runs.map { $0.text }), unrecognized=\(paras[0].unrecognizedChildren.map { $0.name })"
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

    // MARK: - Test 6 (v2 verify finding): components path inline mode also
    //         appends OMML to existing paragraph (matches latex path semantics).
    //
    // Pre-v2 (post-#98 first commit): components path always built
    // `Paragraph(runs: [eqRun])` and inserted as new paragraph regardless of
    // display_mode — same structural bug as pre-#98 but only for the
    // `components` invocation path. Devil's Advocate + Logic + Codex flagged
    // P1: CHANGELOG BREAKING claim was overbroad.

    func testComponentsPathInlineModeAppendsToExistingParagraph() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98f")]
        )

        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98f"),
                "components": .object([
                    "type": .string("run"),
                    "text": .string("x")
                ]),
                "display_mode": .bool(false),
                "paragraph_index": .int(0)
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Inserted equation"),
            "components path + inline mode + valid paragraph_index should succeed; got: \(txt)"
        )

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("e98f"), "path": .string(savePath)]
        )

        let saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        let paras = saved.body.children.compactMap { (child) -> Paragraph? in
            if case .paragraph(let p) = child { return p }
            return nil
        }
        XCTAssertEqual(
            paras.count, 5,
            "components path + inline mode must NOT add a new paragraph (matches latex path semantics post-v2 unification); got: \(paras.count)"
        )
        XCTAssertTrue(
            paras[0].runs.contains(where: { $0.text == "para0" }),
            "paragraph 0 must still contain original 'para0' after inline append (components path)"
        )
        let runRawOMML = paras[0].runs.contains { run in
            (run.rawXML?.contains("<m:oMath") ?? false)
                || (run.properties.rawXML?.contains("<m:oMath") ?? false)
        }
        let directChildOMML = paras[0].unrecognizedChildren.contains { child in
            child.name == "oMath" || child.name == "oMathPara"
                || child.rawXML.contains("<m:oMath")
        }
        XCTAssertTrue(
            runRawOMML || directChildOMML,
            "paragraph 0 must carry OMML in either runs or direct-child after components-path inline append; runs=\(paras[0].runs.map { $0.text }), unrecognized=\(paras[0].unrecognizedChildren.map { $0.name })"
        )
    }

    // MARK: - Test 7 (v2 verify finding): latex path produces STRUCTURED OMML,
    //         not deprecated flat MathEquation output.
    //
    // Pre-v2: latex path delegated to `try doc.insertEquation(at: location, latex:, displayMode:)`
    // which internally uses `MathEquation(latex:).toXML()` — `@available(*, deprecated, ...)`
    // flat output: `<m:r><m:t>(a)/(b)</m:t></m:r>` for `\frac{a}{b}`. Codex
    // reviewer flagged P1 regression: pre-#98 handler used MathComponent AST
    // which produces structured `<m:f>` (math fraction). Post-v2 handler keeps
    // MathComponent AST for both paths.

    func testLatexPathProducesStructuredOMMLForFraction() async throws {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e98g")]
        )

        let savePath = url.path + ".out"
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        // Display mode + fraction → expect <m:f> (math fraction element) in
        // saved doc, NOT the deprecated `<m:r><m:t>(a)/(b)</m:t></m:r>` flat
        // output that lib's `MathEquation` would produce.
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e98g"),
                "latex": .string("\\frac{a}{b}"),
                "display_mode": .bool(true),
                "paragraph_index": .int(0)
            ]
        )
        XCTAssertTrue(
            textOf(r).contains("Inserted equation"),
            "latex display fraction insert should succeed; got: \(textOf(r))"
        )

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("e98g"), "path": .string(savePath)]
        )

        // Inspect raw word/document.xml inside the saved .docx (zip) for <m:f>.
        // This is a hard structural check — flat MathEquation never emits <m:f>.
        let unzipped = try unzipDocumentXML(at: savePath)
        XCTAssertTrue(
            unzipped.contains("<m:f>") || unzipped.contains("<m:f "),
            "saved document.xml MUST contain structured <m:f> (math fraction) element for \\frac{a}{b}; got snippet:\n\(unzipped.prefix(2000))"
        )
        // Negative assertion: lib's deprecated flat output for \frac{a}{b}
        // would emit "(a)/(b)" via `processLatex`. Make sure we did NOT regress
        // to that pattern.
        XCTAssertFalse(
            unzipped.contains("(a)/(b)"),
            "saved document.xml must NOT contain deprecated MathEquation flat output '(a)/(b)' (was Codex-flagged P1 regression)"
        )
    }

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    /// Extract `word/document.xml` from a .docx (zip) at the given path.
    private func unzipDocumentXML(at docxPath: String) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/unzip"
        process.arguments = ["-p", docxPath, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
