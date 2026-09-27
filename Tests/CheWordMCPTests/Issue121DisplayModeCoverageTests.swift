import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#121 — `insert_equation`'s `display_mode` type-check
/// (#107, `Issue98InsertEquationLibBypassTests.testInsertEquationRejectsStringDisplayMode`)
/// only ever pinned the string case (`"false"`). The other non-boolean JSON
/// types a caller could send — number, array, object, and `null` — had no
/// dedicated test, so a future refactor of the `args["display_mode"]` guard
/// (`Server.swift`, the `if let displayModeValue = ..., displayModeValue != .null`
/// block) could silently narrow or widen the check for those types without
/// any test noticing.
///
/// Behavior pinned here (empirically probed against this checkout before
/// writing these assertions, not assumed from reading the guard):
///
/// - number / array / object → `isError: true`, the same
///   "display_mode must be a boolean true/false, not a string or other JSON
///   type" message the string case gets.
/// - explicit JSON `null` → **not** an error. The guard's own condition
///   (`displayModeValue != .null`) treats an explicit `null` exactly like an
///   absent key, so it falls through to the default (`true`, display mode).
///   This is a real, intentional asymmetry (documented in Server.swift as
///   "#232 R1: explicit JSON null now counts as absent here too"), not an
///   oversight this test should paper over.
final class Issue121DisplayModeCoverageTests: XCTestCase {

    private func minimalDocxFiveParas() throws -> URL {
        var doc = WordDocument()
        for i in 0..<5 {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "para\(i)")])))
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue121_eq_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func invokeWithDisplayMode(_ value: Value, docId: String) async throws -> CallTool.Result {
        let url = try minimalDocxFiveParas()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string(docId)]
        )
        return await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string(docId),
                "latex": .string("x"),
                "display_mode": value
            ]
        )
    }

    // MARK: - Non-bool, non-string JSON types → type error

    func testInsertEquationRejectsIntegerDisplayMode() async throws {
        let r = try await invokeWithDisplayMode(.int(1), docId: "e121-int")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "integer display_mode SHALL fail. Got: \(txt)")
        XCTAssertTrue(txt.contains("display_mode") && txt.lowercased().contains("boolean"),
            "expected type error mentioning display_mode and boolean; got: \(txt)")
    }

    func testInsertEquationRejectsDoubleDisplayMode() async throws {
        let r = try await invokeWithDisplayMode(.double(1.5), docId: "e121-double")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "floating-point display_mode SHALL fail. Got: \(txt)")
        XCTAssertTrue(txt.contains("display_mode") && txt.lowercased().contains("boolean"),
            "expected type error mentioning display_mode and boolean; got: \(txt)")
    }

    func testInsertEquationRejectsArrayDisplayMode() async throws {
        let r = try await invokeWithDisplayMode(.array([.bool(true)]), docId: "e121-array")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "array display_mode SHALL fail. Got: \(txt)")
        XCTAssertTrue(txt.contains("display_mode") && txt.lowercased().contains("boolean"),
            "expected type error mentioning display_mode and boolean; got: \(txt)")
    }

    func testInsertEquationRejectsObjectDisplayMode() async throws {
        let r = try await invokeWithDisplayMode(.object(["x": .bool(true)]), docId: "e121-object")
        let txt = textOf(r)
        XCTAssertEqual(r.isError, true, "object display_mode SHALL fail. Got: \(txt)")
        XCTAssertTrue(txt.contains("display_mode") && txt.lowercased().contains("boolean"),
            "expected type error mentioning display_mode and boolean; got: \(txt)")
    }

    // MARK: - Explicit JSON null → treated as absent, NOT a type error

    /// This is the asymmetric case: unlike every other non-boolean JSON type,
    /// explicit `null` does not error. It is deliberately absorbed into the
    /// "absent" branch (`displayModeValue != .null` in the guard) and falls
    /// back to the default `display_mode: true`. Empirically confirmed
    /// against this checkout before writing this assertion — this is not an
    /// assumption carried over from reading the guard's source.
    func testInsertEquationExplicitNullDisplayModeFallsBackToDefaultTrue() async throws {
        let r = try await invokeWithDisplayMode(.null, docId: "e121-null")
        let txt = textOf(r)
        XCTAssertNotEqual(r.isError, true,
            "explicit JSON null display_mode SHALL NOT be treated as a type error (it falls back to the default, matching optionalBool's absent-key contract elsewhere in this file). Got: \(txt)")
        XCTAssertTrue(txt.contains("display mode: true"),
            "explicit null SHALL fall back to the display_mode=true default, same as omitting the key entirely. Got: \(txt)")
    }
}
