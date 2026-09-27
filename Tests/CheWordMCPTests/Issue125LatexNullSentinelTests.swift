import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#125 (and #122, the same fix — see note below) —
/// `insert_equation`'s `components`+`latex` conflict guard used to check
/// `args["components"] != nil && args["latex"] != nil`, which is
/// key-existence, not "did the caller actually pass two values." An MCP
/// client that serializes every schema field (populating the ones it left
/// blank with JSON `null`) sending `{components: {...}, latex: null}` got
/// rejected with "pass either 'components' OR 'latex', not both" — a message
/// that lied about what was sent, since `latex` was never actually provided.
///
/// #232 R1 already made this decision for `display_mode: null` (treated as
/// absent, not a type error). This closes the same gap for `components` /
/// `latex`, using the same type-filtered presence check the file already
/// uses for anchors (`Self.anchorPresence`, `.objectValue` / `.stringValue`).
///
/// #122 note: that issue was filed with a title copied from a *different*
/// issue in this batch ("paragraph_index schema missing inline-mode bounds
/// asymmetry note" — that's actually #123's topic). #122's own body is this
/// exact `latex: null` conflict-guard problem, i.e. the same bug #125
/// describes and the same fix. Both issue numbers are closed by this file.
final class Issue125LatexNullSentinelTests: XCTestCase {

    private func minimalDocxFiveParas() throws -> URL {
        var doc = WordDocument()
        for i in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "para\(i)")])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue125_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func invoke(_ args: [String: Value], docId: String) async throws -> CallTool.Result {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )
        var full = args
        full["doc_id"] = .string(docId)
        return await server.invokeToolForTesting(name: "insert_equation", arguments: full)
    }

    // MARK: - `latex: null` alongside real `components` must NOT be treated
    // as "both provided" — it must fall through and use `components`.

    func testInsertEquationAcceptsLatexExplicitNullWhenComponentsProvided() async throws {
        let r = try await invoke([
            "components": .object(["type": .string("run"), "text": .string("y")]),
            "latex": .null
        ], docId: "e125-a")
        let txt = textOf(r)
        XCTAssertNotEqual(
            r.isError, true,
            "components + latex:null must not be rejected as a conflict; got: \(txt)"
        )
        XCTAssertTrue(
            txt.contains("Inserted equation"),
            "components path should proceed normally when latex is explicit null; got: \(txt)"
        )
    }

    // MARK: - Symmetric case: `components: null` alongside real `latex` must
    // NOT be treated as "both provided" either — it must fall through and
    // use `latex`.

    func testInsertEquationAcceptsComponentsExplicitNullWhenLatexProvided() async throws {
        let r = try await invoke([
            "latex": .string("x"),
            "components": .null
        ], docId: "e125-b")
        let txt = textOf(r)
        XCTAssertNotEqual(
            r.isError, true,
            "latex + components:null must not be rejected as a conflict; got: \(txt)"
        )
        XCTAssertTrue(
            txt.contains("Inserted equation"),
            "latex path should proceed normally when components is explicit null; got: \(txt)"
        )
    }

    // MARK: - Both explicit null (neither actually provided) → the
    // pre-existing "argument required" error, not the conflict error.

    func testInsertEquationBothExplicitNullReportsArgumentRequiredNotConflict() async throws {
        let r = try await invoke([
            "latex": .null,
            "components": .null
        ], docId: "e125-c")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "neither latex nor components actually provided; must fail. Got: \(txt)")
        XCTAssertFalse(
            txt.lowercased().contains("not both"),
            "both explicit null must NOT be reported as a conflict (neither was actually provided); got: \(txt)"
        )
        XCTAssertTrue(
            txt.contains("required"),
            "expected the pre-existing 'either components or latex required' error; got: \(txt)"
        )
    }

    // MARK: - Genuine conflict (both real values) must still be rejected,
    // and the message now echoes what was received (#129).

    func testInsertEquationStillRejectsRealComponentsAndLatexTogether() async throws {
        let r = try await invoke([
            "components": .object(["type": .string("run"), "text": .string("y")]),
            "latex": .string("x")
        ], docId: "e125-d")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "real components + real latex is a genuine conflict; got: \(txt)")
        XCTAssertTrue(
            txt.contains("components") && txt.contains("latex") && txt.lowercased().contains("not both"),
            "expected conflict error mentioning components, latex, and not both; got: \(txt)"
        )
        // #129 — the conflict message now echoes the received values.
        XCTAssertTrue(
            txt.contains("received"),
            "expected the conflict error to echo the received values (#129); got: \(txt)"
        )
    }
}
