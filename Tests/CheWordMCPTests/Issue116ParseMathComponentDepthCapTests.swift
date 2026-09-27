import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#116 — `parseMathComponent` (`Server.swift`,
/// `insert_equation`'s `components:` JSON-tree parser) recurses into
/// `numerator`/`denominator`/`radicand`/`base`/`sub`/`sup` with no depth
/// counter. A caller-supplied `components` tree nested deep enough exhausts
/// the Swift call stack — an uncatchable trap that kills the whole MCP
/// server process, not just this one tool call, taking every other open
/// document session down with it.
///
/// This is the same underlying recursion #117's body described (that issue's
/// title ended up being about a different, already-shipped `display_mode`
/// strict-bool fix — see the wave1 report for the title/body mismatch across
/// both #116 and #117).
///
/// Threat model: an AI-agent caller (or a fuzzer, or a malicious MCP client)
/// builds a `components` tree thousands of levels deep — trivial to do
/// programmatically, unlike hand-typed LaTeX. Nothing before this fix stops
/// `parseMathComponent` from recursing arbitrarily deep to service it.
final class Issue116ParseMathComponentDepthCapTests: XCTestCase {

    private func minimalDocxOnePara() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue116_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Builds a `radical`-of-`radical`-of-`radical`... `components` tree
    /// `depth` levels deep, bottom-up via a loop (NOT recursion — this
    /// helper must not itself be vulnerable to the bug under test). Each
    /// level matches `parseMathComponent`'s "radical" case: a `radicand`
    /// array holding one child component.
    private func deeplyNestedRadicalComponents(depth: Int) -> Value {
        var inner: Value = .object(["type": .string("run"), "text": .string("x")])
        for _ in 0..<depth {
            inner = .object(["type": .string("radical"), "radicand": .array([inner])])
        }
        return inner
    }

    /// RED (pre-fix): a components tree far deeper than any genuine equation
    /// (500 levels — ~8x the chosen cap of 64) crashes the whole test
    /// process with a stack overflow trap before this fix lands (verified
    /// directly: reverting the depth-cap guard and re-running this exact
    /// test reproduces "exited with unexpected signal code 10"). Post-fix:
    /// `parseMathComponent` must reject it with a structured error naming
    /// the nesting-depth problem, never a crash and never a silent success.
    ///
    /// 500 (not the issue's own cited 5,000-10,000) is a deliberate choice:
    /// at tens of thousands of levels, simply holding — and later
    /// deallocating — the nested `Value`/`MathComponent` tree in THIS TEST's
    /// own memory recurses deep enough to crash on its own (Swift's
    /// automatic ARC release of a deeply nested enum-of-arrays is itself a
    /// recursive call chain), independent of whether `parseMathComponent`
    /// is fixed. That is a real, separate hazard (unbounded nesting is
    /// unsafe for the whole `Value` type, not just this one parser) but it
    /// is out of scope for #116/#117, which name `parseMathComponent`
    /// specifically. 500 is comfortably past both the cap (64) and the
    /// issue's own "~3,000 levels exhausts a 512 KB stack at ~160
    /// bytes/frame" arithmetic scaled down for this parser's smaller,
    /// per-level frame cost, while staying well clear of the ARC-dealloc
    /// hazard observed empirically at 20,000.
    func testDeeplyNestedComponentsTreeIsRejectedNotCrashed() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e116a")]
        )

        let deepComponents = deeplyNestedRadicalComponents(depth: 500)
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e116a"),
                "components": deepComponents,
            ]
        )
        let txt = textOf(r)
        XCTAssertFalse(
            txt.contains("Inserted equation"),
            "a 500-level-deep components tree must NOT silently succeed; got: \(txt)"
        )
        XCTAssertTrue(
            txt.contains("Error"),
            "expected a structured Error response, not a crash or silent success; got: \(txt)"
        )
        XCTAssertTrue(
            txt.lowercased().contains("depth") || txt.lowercased().contains("nest"),
            "expected the error to name the nesting-depth problem; got: \(txt)"
        )
    }

    /// A component tree at a realistic, generous depth (well within any
    /// genuine hand-authored equation) must still succeed — the cap must not
    /// reject ordinary use.
    func testModeratelyNestedComponentsTreeStillSucceeds() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("e116b")]
        )

        let shallowComponents = deeplyNestedRadicalComponents(depth: 8)
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("e116b"),
                "components": shallowComponents,
            ]
        )
        let txt = textOf(r)
        XCTAssertTrue(
            txt.contains("Inserted equation"),
            "an 8-level-deep components tree is well within any genuine equation and must succeed; got: \(txt)"
        )
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
