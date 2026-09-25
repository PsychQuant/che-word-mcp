import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#234 — 8 sites multiply a user-supplied `Int`
/// (already type-checked by #232's `optionalInt`) by a fixed unit-conversion
/// constant (×2 points→half-points for `font_size`, ×20 points→twips for
/// `space_before`/`space_after`) with no range check first. Swift's `Int *
/// Int` TRAPS on overflow — this is not a catchable `WordError`, it is a
/// process-level `Fatal error` that kills the whole `che-word-mcp` server,
/// taking every open document's unsaved edits down with it. Confirmed via
/// `format_text({font_size: 9223372036854775807})` against the real debug
/// binary over stdio (`exit_during_call=-5`, `Fatal error: Overflow`) before
/// this fix, and confirmed NOT to crash — clean `isError: true` instead —
/// after it. The same real-binary stdio harness cannot run inside XCTest
/// (a trap kills the TEST process too, the same way it kills the server),
/// so the crash-reproduction evidence lives in the #234 RED section of
/// `reports/cwmint.md`, not in an XCTest here. These tests instead pin the
/// GREEN behavior end to end (via `invokeToolForTesting`, which routes
/// through the exact same code paths without spawning a subprocess) and
/// unit-test the extracted helper directly.
///
/// #234's own issue text asked for a full-file audit "不只這 8 處" (not
/// just these 8 sites) — beyond them, this file also fixes:
///  - `set_page_margins`' `top`/`right`/`bottom`/`left`: stored as-is
///    (twips, no multiplication AT THAT call site), but SUBTRACTED from
///    `pageSize.width`/`height` downstream in `estimateCharsPerPage`
///    (reachable via `estimate_paragraph_for_page`) — an unbounded margin
///    underflows/overflows THAT subtraction and traps, a different
///    function than the one that read the value.
///  - `search_text_with_formatting`'s `context_chars`: the only
///    `context_chars`-family parameter in the file with no upper bound at
///    all (its 3 siblings — `list_comments`, `find_unresolved_comments`,
///    `find_inline_math_gaps` — already clamp); used in raw
///    `position - contextChars` / `position + matchedText.count +
///    contextChars` arithmetic that can under/overflow.
final class Issue234IntegerOverflowGuardTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func openFixtureDocument(_ server: WordMCPServer, id: String) async throws {
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let para = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
        XCTAssertNotEqual(para.isError, true, resultText(para))
    }

    // MARK: - (A) `Self.validatedScaledMeasurement` unit tests

    func testValidatedScaledMeasurementAcceptsInRangeValues() throws {
        XCTAssertEqual(try WordMCPServer.validatedScaledMeasurement(12, key: "font_size", range: 1...1638, multiplier: 2), 24)
        XCTAssertEqual(try WordMCPServer.validatedScaledMeasurement(1, key: "font_size", range: 1...1638, multiplier: 2), 2)
        XCTAssertEqual(try WordMCPServer.validatedScaledMeasurement(1638, key: "font_size", range: 1...1638, multiplier: 2), 3276)
        XCTAssertEqual(try WordMCPServer.validatedScaledMeasurement(0, key: "space_before", range: 0...1584, multiplier: 20), 0)
        XCTAssertEqual(try WordMCPServer.validatedScaledMeasurement(1584, key: "space_before", range: 0...1584, multiplier: 20), 31680)
    }

    /// The exact crash input from the issue: `Int.max` must be rejected,
    /// not multiplied.
    func testValidatedScaledMeasurementRejectsOutOfRangeValuesNamingTheParameter() throws {
        for bad in [Int.max, Int.min, 1639, -1] {
            do {
                _ = try WordMCPServer.validatedScaledMeasurement(bad, key: "font_size", range: 1...1638, multiplier: 2)
                XCTFail("expected invalidParameter for \(bad)")
            } catch WordError.invalidParameter(let key, _) {
                XCTAssertEqual(key, "font_size")
            } catch {
                XCTFail("expected WordError.invalidParameter, got \(error)")
            }
        }
    }

    func testValidatedScaledMeasurementRejectsBelowFloorForSpacing() throws {
        do {
            _ = try WordMCPServer.validatedScaledMeasurement(-1, key: "space_before", range: 0...1584, multiplier: 20)
            XCTFail("expected invalidParameter for -1")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "space_before")
        }
    }

    // MARK: - (B) end-to-end: the 8 issue-listed sites, via invokeToolForTesting
    //
    // Not a subprocess crash test (see the file-level doc comment) — these
    // confirm the SAME code path `format_text`/`set_paragraph_format`/
    // `create_style`/`update_style` actually take now rejects the crash
    // input cleanly, and still accepts ordinary values.

    /// Sites 1–2: `format_text.font_size`, direct branch and
    /// `as_revision: true` branch (two separate call sites in the source,
    /// both must be fixed independently).
    func testFormatTextRejectsOutOfRangeFontSize() async throws {
        let server = await WordMCPServer()
        let id = "s234-format-text"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "font_size": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("font_size"), resultText(result))
    }

    func testFormatTextAsRevisionRejectsOutOfRangeFontSize() async throws {
        let server = await WordMCPServer()
        let id = "s234-format-text-revision"
        try await openFixtureDocument(server, id: id)
        let enable = await server.invokeToolForTesting(name: "enable_track_changes", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(enable.isError, true, resultText(enable))
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: [
                "doc_id": .string(id), "paragraph_index": .int(0),
                "font_size": .int(9_223_372_036_854_775_807), "as_revision": .bool(true),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("font_size"), resultText(result))
    }

    func testFormatTextAcceptsOrdinaryFontSize() async throws {
        let server = await WordMCPServer()
        let id = "s234-format-text-ok"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "font_size": .int(24)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let doc = await server.openDocuments[id]
        XCTAssertEqual(doc?.getParagraphs().first?.runs.first?.properties.fontSize, 48)
    }

    /// Sites 3–4: `set_paragraph_format.space_before`/`space_after`.
    func testSetParagraphFormatRejectsOutOfRangeSpacing() async throws {
        let server = await WordMCPServer()
        let id = "s234-paragraph-format"
        try await openFixtureDocument(server, id: id)
        for key in ["space_before", "space_after"] {
            let result = await server.invokeToolForTesting(
                name: "set_paragraph_format",
                arguments: ["doc_id": .string(id), "paragraph_index": .int(0), key: .int(9_223_372_036_854_775_807)]
            )
            XCTAssertEqual(result.isError, true, "\(key): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains(key), "\(key): \(resultText(result))")
        }
    }

    /// Word's own UI floors spacing before/after at 0 (verified during this
    /// issue's research — see the report) — a negative value used to be
    /// silently accepted and written as a negative twips value; now it is
    /// named and rejected, same as any other out-of-range value.
    func testSetParagraphFormatRejectsNegativeSpacing() async throws {
        let server = await WordMCPServer()
        let id = "s234-paragraph-format-negative"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_paragraph_format",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "space_before": .int(-1)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("space_before"), resultText(result))
    }

    func testSetParagraphFormatAcceptsOrdinarySpacing() async throws {
        let server = await WordMCPServer()
        let id = "s234-paragraph-format-ok"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_paragraph_format",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "space_before": .int(10), "space_after": .int(6)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let doc = await server.openDocuments[id]
        let spacing = doc?.getParagraphs().first?.properties.spacing
        XCTAssertEqual(spacing?.before, 200)  // 10 * 20
        XCTAssertEqual(spacing?.after, 120)   // 6 * 20
    }

    /// Sites 5–7: `create_style`'s `font_size`/`space_before`/`space_after`
    /// (a THIRD, independent call site for each conversion — `create_style`
    /// builds `runProps`/`paraProps` unconditionally, unlike `update_style`'s
    /// OR-gated block below).
    func testCreateStyleRejectsOutOfRangeFontSizeAndSpacing() async throws {
        let server = await WordMCPServer()
        let id = "s234-create-style"
        try await openFixtureDocument(server, id: id)
        let cases: [(String, Value)] = [
            ("font_size", .int(9_223_372_036_854_775_807)),
            ("space_before", .int(9_223_372_036_854_775_807)),
            ("space_after", .int(9_223_372_036_854_775_807)),
        ]
        for (key, value) in cases {
            let result = await server.invokeToolForTesting(
                name: "create_style",
                arguments: ["doc_id": .string(id), "style_id": .string("CS-\(key)"), "name": .string(key), "type": .string("paragraph"), key: value]
            )
            XCTAssertEqual(result.isError, true, "\(key): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains(key), "\(key): \(resultText(result))")
        }
    }

    func testCreateStyleAcceptsOrdinaryFontSizeAndSpacing() async throws {
        let server = await WordMCPServer()
        let id = "s234-create-style-ok"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "create_style",
            arguments: [
                "doc_id": .string(id), "style_id": .string("CS-ok"), "name": .string("CS-ok"), "type": .string("paragraph"),
                "font_size": .int(14), "space_before": .int(10), "space_after": .int(10),
            ]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
    }

    /// Site 8: `update_style`'s `font_size` — the OR-gated
    /// `runProps?.fontSize` block (`update_style` does NOT declare
    /// `space_before`/`space_after` in its schema, so there is no analogous
    /// spacing site here to test — confirmed by reading the schema, not
    /// assumed).
    func testUpdateStyleRejectsOutOfRangeFontSize() async throws {
        let server = await WordMCPServer()
        let id = "s234-update-style"
        try await openFixtureDocument(server, id: id)
        let create = await server.invokeToolForTesting(
            name: "create_style",
            arguments: ["doc_id": .string(id), "style_id": .string("US1"), "name": .string("US1"), "type": .string("paragraph")]
        )
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let result = await server.invokeToolForTesting(
            name: "update_style",
            arguments: ["doc_id": .string(id), "style_id": .string("US1"), "font_size": .int(9_223_372_036_854_775_807)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("font_size"), resultText(result))
    }

    // MARK: - (C) beyond the issue's 8 sites: full-file audit findings

    /// `set_page_margins.top` combined with `estimate_paragraph_for_page`
    /// (which calls the private `estimateCharsPerPage`, subtracting margins
    /// from page size) — a DIFFERENT function than the one that reads the
    /// margin value. `Int.min` is the exact crash input found during this
    /// issue's audit (verified over real binary stdio — `top: Int.max`
    /// alone does NOT trap this particular subtraction direction, only
    /// `Int.min` does; see the report's RED section for why).
    func testSetPageMarginsRejectsOutOfRangeValue() async throws {
        let server = await WordMCPServer()
        let id = "s234-page-margins"
        try await openFixtureDocument(server, id: id)
        for key in ["top", "right", "bottom", "left"] {
            for bad: Value in [.int(Int.max), .int(Int.min)] {
                let result = await server.invokeToolForTesting(
                    name: "set_page_margins",
                    arguments: ["doc_id": .string(id), key: bad]
                )
                XCTAssertEqual(result.isError, true, "\(key)=\(bad): \(resultText(result))")
                XCTAssertTrue(resultText(result).contains(key), "\(key)=\(bad): \(resultText(result))")
            }
        }
    }

    func testSetPageMarginsAcceptsOrdinaryValuesAndEstimateStillWorks() async throws {
        let server = await WordMCPServer()
        let id = "s234-page-margins-ok"
        try await openFixtureDocument(server, id: id)
        let margins = await server.invokeToolForTesting(
            name: "set_page_margins",
            arguments: ["doc_id": .string(id), "top": .int(1440), "right": .int(1440), "bottom": .int(1440), "left": .int(1440)]
        )
        XCTAssertNotEqual(margins.isError, true, resultText(margins))
        let estimate = await server.invokeToolForTesting(
            name: "estimate_paragraph_for_page", arguments: ["doc_id": .string(id), "page": .int(1)]
        )
        XCTAssertNotEqual(estimate.isError, true, resultText(estimate))
    }

    /// `search_text_with_formatting.context_chars` — clamped (not rejected)
    /// to match its 3 siblings' existing policy; a huge value must not trap
    /// and must not error, just get silently capped.
    func testSearchTextWithFormattingClampsExtremeContextChars() async throws {
        let server = await WordMCPServer()
        let id = "s234-search-context"
        try await openFixtureDocument(server, id: id)
        for bad: Value in [.int(Int.max), .int(Int.min)] {
            let result = await server.invokeToolForTesting(
                name: "search_text_with_formatting",
                arguments: ["doc_id": .string(id), "query": .string("Anchor"), "context_chars": bad]
            )
            XCTAssertNotEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("Anchor"), "\(bad): \(resultText(result))")
        }
    }
}
