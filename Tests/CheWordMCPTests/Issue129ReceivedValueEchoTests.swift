import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#129 — `insert_equation`'s two argument-validation
/// error messages (`components`+`latex` conflict, non-boolean `display_mode`)
/// never echoed the value the caller actually sent, so an agent trying to
/// self-repair had to guess what it had passed. Both now append the received
/// value(s) as a parenthetical suffix — the pinned substrings other tests
/// check for (`"components"`/`"latex"`/`"not both"`, `"display_mode"`/
/// `"boolean"`) are unaffected since the new text is appended after them.
final class Issue129ReceivedValueEchoTests: XCTestCase {

    private func minimalDocxFiveParas() throws -> URL {
        var doc = WordDocument()
        for i in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "para\(i)")])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue129_eq_\(UUID().uuidString).docx")
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

    // MARK: - display_mode type error echoes the received value

    func testDisplayModeTypeErrorEchoesReceivedStringValue() async throws {
        let r = try await invoke([
            "latex": .string("x"),
            "display_mode": .string("false")
        ], docId: "e129-a")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "string display_mode must still be rejected; got: \(txt)")
        // Pre-existing pinned substrings (Issue98's testInsertEquationRejectsStringDisplayMode).
        XCTAssertTrue(txt.contains("display_mode") && txt.lowercased().contains("boolean"), "got: \(txt)")
        // #129: the received value itself, quoted, must be echoed.
        XCTAssertTrue(
            txt.contains("received") && txt.contains("\"false\""),
            "expected the error to echo the received string value \"false\"; got: \(txt)"
        )
    }

    func testDisplayModeTypeErrorEchoesReceivedIntValue() async throws {
        let r = try await invoke([
            "latex": .string("x"),
            "display_mode": .int(1)
        ], docId: "e129-b")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "int display_mode must still be rejected; got: \(txt)")
        XCTAssertTrue(
            txt.contains("received") && txt.contains("1"),
            "expected the error to echo the received int value 1; got: \(txt)"
        )
    }

    // MARK: - components+latex conflict error echoes both received values

    func testComponentsLatexConflictErrorEchoesBothReceivedValues() async throws {
        let r = try await invoke([
            "components": .object(["type": .string("run"), "text": .string("y")]),
            "latex": .string("some-latex")
        ], docId: "e129-c")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "real conflict must still be rejected; got: \(txt)")
        // Pre-existing pinned substrings (Issue98's testInsertEquationRejectsComponentsAndLatexTogether).
        XCTAssertTrue(
            txt.contains("components") && txt.contains("latex") && txt.lowercased().contains("not both"),
            "got: \(txt)"
        )
        // #129: echo of what was actually received on each side.
        XCTAssertTrue(txt.contains("received"), "expected the conflict error to echo received values; got: \(txt)")
        XCTAssertTrue(
            txt.contains("\"some-latex\""),
            "expected the echoed latex value to be quoted verbatim; got: \(txt)"
        )
    }

    // MARK: - Echoed string values are truncated (no unbounded-length DoS
    // vector reintroduced via the new echo text — #129's own caveat).

    func testComponentsLatexConflictErrorTruncatesLongLatexValue() async throws {
        let longLatex = String(repeating: "a", count: 500)
        let r = try await invoke([
            "components": .object(["type": .string("run"), "text": .string("y")]),
            "latex": .string(longLatex)
        ], docId: "e129-d")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "got: \(txt)")
        XCTAssertFalse(
            txt.contains(longLatex),
            "the full 500-char latex value must not appear verbatim in the error message; got length \(txt.count)"
        )
        XCTAssertTrue(
            txt.contains("..."),
            "expected a truncation marker in the echoed value; got: \(txt)"
        )
    }
}
