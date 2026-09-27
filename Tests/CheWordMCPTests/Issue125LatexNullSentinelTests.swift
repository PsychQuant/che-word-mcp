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
/// `latex`.
///
/// #122 note: that issue was filed with a title copied from a *different*
/// issue in this batch ("paragraph_index schema missing inline-mode bounds
/// asymmetry note" — that's actually #123's topic). #122's own body is this
/// exact `latex: null` conflict-guard problem, i.e. the same bug #125
/// describes and the same fix. Both issue numbers are closed by this file.
///
/// R2 (independent review FAIL, HIGH finding): the first fix used
/// `.objectValue != nil` / `.stringValue != nil` as the PRESENCE test itself
/// — which conflates "absent-or-null" with "present but the wrong JSON
/// type". That is exactly the #232 anti-pattern the long comment above
/// `optionalInt`/`optionalBool` in `Server.swift` already diagnoses: "a
/// wrong JSON type... OR a JSON null OR an absent key all fall through to
/// nil identically". Reintroducing it here (just with different accessor
/// names) meant `{"components": "oops"}` (a string, not null) got the false
/// "either components or latex required" message instead of a message
/// naming `components` and echoing what it actually received, and
/// `{"components": [1,2,3], "latex": "real"}` silently dropped the
/// malformed `components` and "succeeded" using only `latex` — no error at
/// all. The R2 tests below (`test*TypeError*` and
/// `testBothPresent*TreatedAsConflict`) pin the fix: presence is now
/// "key exists and is not JSON null" (mirrors `display_mode`'s existing
/// `!= .null` pattern), and each side validates its OWN type and throws a
/// named, value-echoing error rather than falling through to the other
/// parameter or to the generic "required" message.
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

    // MARK: - R2: present-but-wrong-type must NEVER look like absent.
    //
    // Each of these gives exactly ONE side a non-null value of the wrong
    // JSON type, with the OTHER side entirely absent. The expected error
    // names the parameter that was actually given and echoes what it
    // received — NOT the generic "either components or latex required"
    // (that message is only correct when NEITHER side was given).

    func testComponentsStringTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["components": .string("oops-not-an-object")], docId: "e125-r2-a")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(
            txt.contains("either 'components'"),
            "components WAS provided (just wrong type) — must not fall to the generic 'either...required' message; got: \(txt)"
        )
        XCTAssertTrue(txt.contains("components"), "error must name 'components'; got: \(txt)")
        XCTAssertTrue(
            txt.contains("\"oops-not-an-object\""),
            "error must echo the received value; got: \(txt)"
        )
    }

    func testComponentsArrayTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["components": .array([.int(1), .int(2), .int(3)])], docId: "e125-r2-b")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(txt.contains("either 'components'"), "got: \(txt)")
        XCTAssertTrue(txt.contains("components"), "got: \(txt)")
        XCTAssertTrue(txt.contains("array of 3") || txt.contains("<array"), "error should echo an array-shaped value; got: \(txt)")
    }

    func testComponentsNumberTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["components": .int(5)], docId: "e125-r2-c")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(txt.contains("either 'components'"), "got: \(txt)")
        XCTAssertTrue(txt.contains("components"), "got: \(txt)")
        XCTAssertTrue(txt.contains("5"), "error should echo the received int 5; got: \(txt)")
    }

    func testLatexNumberTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["latex": .int(5)], docId: "e125-r2-d")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(
            txt.contains("either 'components'"),
            "latex WAS provided (just wrong type) — must not fall to the generic 'either...required' message; got: \(txt)"
        )
        XCTAssertTrue(txt.contains("latex"), "error must name 'latex'; got: \(txt)")
        XCTAssertTrue(txt.contains("string"), "error should say latex must be a string; got: \(txt)")
        XCTAssertTrue(txt.contains("5"), "error should echo the received int 5; got: \(txt)")
    }

    func testLatexObjectTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["latex": .object(["a": .int(1)])], docId: "e125-r2-e")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(txt.contains("either 'components'"), "got: \(txt)")
        XCTAssertTrue(txt.contains("latex"), "got: \(txt)")
        XCTAssertTrue(txt.contains("<object>"), "error should echo an object-shaped value; got: \(txt)")
    }

    func testLatexArrayTypeErrorNamesParameterAndEchoesValue() async throws {
        let r = try await invoke(["latex": .array([.int(1), .int(2), .int(3)])], docId: "e125-r2-f")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(txt.contains("either 'components'"), "got: \(txt)")
        XCTAssertTrue(txt.contains("latex"), "got: \(txt)")
        XCTAssertTrue(txt.contains("array of 3") || txt.contains("<array"), "got: \(txt)")
    }

    // MARK: - R2: both sides present (non-null), one of them wrong-typed —
    // must be treated as a genuine conflict, never a silent drop-and-succeed
    // on the other side. This is the R1 regression the review caught:
    // `{"components": [1,2,3], "latex": "real"}` used to "succeed" using
    // only `latex`, discarding a malformed `components` with no error.

    func testBothPresentComponentsWrongTypeLatexValidTreatedAsConflict() async throws {
        let r = try await invoke([
            "components": .array([.int(1), .int(2), .int(3)]),
            "latex": .string("real")
        ], docId: "e125-r2-g")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "malformed components + valid latex must NOT silently succeed using only latex; got: \(txt)")
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "must not silently drop the malformed components and proceed; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("not both"),
            "both sides were non-null present (one wrong-typed) — expected the conflict error; got: \(txt)"
        )
    }

    func testBothPresentComponentsValidLatexWrongTypeTreatedAsConflict() async throws {
        let r = try await invoke([
            "components": .object(["type": .string("run"), "text": .string("y")]),
            "latex": .int(5)
        ], docId: "e125-r2-h")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(txt.contains("Inserted equation"), "got: \(txt)")
        XCTAssertTrue(
            txt.lowercased().contains("not both"),
            "both sides were non-null present (one wrong-typed) — expected the conflict error, not a type error on latex alone; got: \(txt)"
        )
    }
}
