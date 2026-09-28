import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#90 (H₀ Unicode subscript anchors) + its PR #115
/// verify follow-ups #150 (anchor-not-found hint / schema honesty), #151
/// (expose on search_text/replace_text/search_text_batch), #152 (reject
/// unknown/typo'd match_options keys), #154 (test coverage gaps: isError
/// assertions, insert_equation/insert_image_from_path E2E, explicit-false).
///
/// PR #115 itself was never merged (still open, branch `codex/math-script
/// -match-options`, depended on a since-superseded ooxml-swift feature
/// branch) — none of the `match_options` wiring existed in this repo's
/// `main` before this batch of work. Everything here tests THIS batch's
/// implementation from scratch, not PR #115's code.
final class Issue90MathScriptMatchOptionsTests: XCTestCase {

    // MARK: - Helpers

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    /// One paragraph whose flattened text is the ASCII form `H0` — standing
    /// in for what real OMML's `MathSubSuperScript.visibleText` actually
    /// emits (`H0`, not `H₀`) per #90's diagnosed root cause. Building a
    /// literal plain-text paragraph is sufficient here: `match_options`
    /// operates on flattened text regardless of whether the ASCII came from
    /// OMML flatten or a literal text run — the matching logic doesn't know
    /// or care which.
    private func makeH0Fixture() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "Under H0 the test statistic follows a chi-square distribution.")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue90_h0_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func writeOnePixelPNG() throws -> URL {
        let png: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue90-\(UUID().uuidString).png")
        try Data(png).write(to: url)
        return url
    }

    // MARK: - #90 core case: Unicode needle vs ASCII (OMML-flattened) haystack

    func testInsertParagraphAfterUnicodeSubscriptNeedleMatchesASCIIHaystack() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("h0-1")]
        )

        // Flag OFF: "H₀" (Unicode) must NOT match "H0" (ASCII) — this IS
        // #90's original bug, still true by default (backward compatible).
        let withoutFlag = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("h0-1"), "text": .string("new"), "after_text": .string("H₀")]
        )
        XCTAssertEqual(withoutFlag.isError, true, textOf(withoutFlag))

        // Flag ON: same call now succeeds.
        let withFlag = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("h0-1"), "text": .string("new"), "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(withFlag.isError, true, textOf(withFlag))
    }

    /// #90's diagnosis comment explicitly named `X̄` (combining macron,
    /// U+0304) as a case the original #90 fix did NOT cover ("X̄ (combining
    /// macron) explicitly listed in this issue is NOT covered yet" — PR #115
    /// verify comment, 2026-05-02). ooxml-swift's `AnchorLookupOptions
    /// .canonicalizeMathScriptVariants` has since gained NFD-decompose +
    /// nonspacing-mark-stripping (its own doc comment names `X̄ ↔ X`
    /// explicitly) — confirmed end-to-end here, not just trusted from the
    /// docstring, since this is the one Unicode class #90's own history
    /// flagged as a known gap at the time.
    func testInsertParagraphAfterCombiningMacronNeedleMatchesPlainLetterHaystack() async throws {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "Let X denote the sample mean.")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("issue90_macron_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(url.path), "doc_id": .string("macron-1")]
        )
        let withoutFlag = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("macron-1"), "text": .string("new"), "after_text": .string("X̄")]
        )
        XCTAssertEqual(withoutFlag.isError, true, textOf(withoutFlag))

        let withFlag = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("macron-1"), "text": .string("new"), "after_text": .string("X̄"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(withFlag.isError, true, textOf(withFlag))
    }

    // MARK: - #154: result.isError assertions (not just text content)

    func testInsertParagraphMathScriptFlagOnIsNotError() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("iserr-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("iserr-1"), "text": .string("new"), "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(r.isError, true, textOf(r))
    }

    // MARK: - #154: end-to-end for insert_equation

    func testInsertEquationAfterUnicodeSubscriptNeedleWithFlagOn() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("eq-1")]
        )

        let withoutFlag = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("eq-1"), "latex": .string("x^2"),
                "after_text": .string("H₀"),
            ]
        )
        XCTAssertEqual(withoutFlag.isError, true, textOf(withoutFlag))

        let withFlag = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("eq-1"), "latex": .string("x^2"),
                "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(withFlag.isError, true, textOf(withFlag))
        XCTAssertTrue(textOf(withFlag).contains("Inserted equation"), textOf(withFlag))
    }

    // MARK: - #154: end-to-end for insert_image_from_path

    func testInsertImageFromPathAfterUnicodeSubscriptNeedleWithFlagOn() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("img-1")]
        )

        let withoutFlag = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string("img-1"), "path": .string(png.path), "after_text": .string("H₀")]
        )
        XCTAssertEqual(withoutFlag.isError, true, textOf(withoutFlag))

        let withFlag = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("img-1"), "path": .string(png.path), "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(withFlag.isError, true, textOf(withFlag))
    }

    // MARK: - #154: explicit false === omitted default

    func testExplicitFalseSameAsOmittedDefault() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("false-1")]
        )
        let omitted = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("false-1"), "text": .string("new"), "after_text": .string("H₀")]
        )
        let explicitFalse = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("false-1"), "text": .string("new"), "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(false)]),
            ]
        )
        XCTAssertEqual(omitted.isError, true, textOf(omitted))
        XCTAssertEqual(explicitFalse.isError, true, textOf(explicitFalse))
        XCTAssertEqual(textOf(omitted).contains("not found"), textOf(explicitFalse).contains("not found"))
    }

    // MARK: - #154: empty match_options: {} behaves as .exact

    func testEmptyMatchOptionsIsExactDefault() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("empty-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("empty-1"), "text": .string("new"), "after_text": .string("H₀"),
                "match_options": .object([:]),
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
    }

    // MARK: - #152: reject typo'd / unknown match_options keys

    func testRejectsTypoedMatchOptionsKey() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("typo-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("typo-1"), "text": .string("new"), "after_text": .string("H₀"),
                "match_options": .object(["math_script_insensitve": .bool(true)]),  // missing 'i'
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("match_options"), textOf(r))
    }

    func testRejectsUnknownMatchOptionsKey() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("unknown-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("unknown-1"), "text": .string("new"), "after_text": .string("H0"),
                "match_options": .object(["case_insensitive": .bool(true)]),
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
    }

    func testRejectsMatchOptionsWrongType() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("wrongtype-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("wrongtype-1"), "text": .string("new"), "after_text": .string("H0"),
                "match_options": .string("true"),
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
    }

    func testRejectsMathScriptInsensitiveWrongType() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("wrongtype-2")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("wrongtype-2"), "text": .string("new"), "after_text": .string("H0"),
                "match_options": .object(["math_script_insensitive": .string("yes")]),
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
    }

    // MARK: - #150: anchor-not-found hint

    func testAnchorNotFoundHintWhenNeedleHasMathScriptCharsAndFlagOff() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("hint-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("hint-1"), "text": .string("new"), "after_text": .string("H₀")]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertTrue(textOf(r).contains("math_script_insensitive"), textOf(r))
    }

    func testAnchorNotFoundNoHintWhenNeedleIsPureASCII() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("hint-2")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("hint-2"), "text": .string("new"), "after_text": .string("this text does not exist anywhere")]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertFalse(textOf(r).contains("math_script_insensitive"), "pure-ASCII not-found should not get the hint (avoid false hint spam): " + textOf(r))
    }

    func testAnchorNotFoundNoHintWhenFlagAlreadyOn() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("hint-3")]
        )
        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("hint-3"), "text": .string("new"), "after_text": .string("H₁"),  // genuinely absent even with flag on
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertEqual(r.isError, true, textOf(r))
        XCTAssertFalse(textOf(r).contains("try match_options.math_script_insensitive"), "flag already on — hint would be pointless: " + textOf(r))
    }

    // MARK: - #150: schema description honesty

    func testMatchOptionsSchemaDescriptionEnumeratesSupportedRange() throws {
        let schema = WordMCPServer.matchOptionsSchema
        guard case .object(let obj) = schema,
              case .object(let props)? = obj["properties"],
              case .string(let desc)? = props["math_script_insensitive"]?.objectValue?["description"] else {
            XCTFail("could not read match_options schema")
            return
        }
        XCTAssertTrue(desc.contains("支援範圍"), desc)
        XCTAssertTrue(desc.contains("完整 mapping 見"), desc)
    }

    // MARK: - #151: search_text / replace_text / search_text_batch

    func testSearchTextFindsUnicodeSubscriptWithFlagOn() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("search-1")]
        )
        let withoutFlag = await server.invokeToolForTesting(
            name: "search_text", arguments: ["doc_id": .string("search-1"), "query": .string("H₀")]
        )
        XCTAssertTrue(textOf(withoutFlag).contains("No matches"), textOf(withoutFlag))

        let withFlag = await server.invokeToolForTesting(
            name: "search_text",
            arguments: [
                "doc_id": .string("search-1"), "query": .string("H₀"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertTrue(textOf(withFlag).contains("Found 1 match"), textOf(withFlag))
        XCTAssertTrue(textOf(withFlag).contains("matched_form: math_script_normalized"), textOf(withFlag))
    }

    func testSearchTextBatchInheritsTopLevelMatchOptions() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("batch-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "search_text_batch",
            arguments: [
                "doc_id": .string("batch-1"),
                "queries": .array([.string("H₀")]),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertTrue(textOf(r).contains("Found 1 match"), textOf(r))
    }

    func testReplaceTextReplacesUnicodeSubscriptNeedleAgainstASCIIHaystackWithFlagOn() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let savePath = fixture.path + ".out.docx"
        defer { try? FileManager.default.removeItem(atPath: savePath) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("replace-1")]
        )

        let withoutFlag = await server.invokeToolForTesting(
            name: "replace_text",
            arguments: ["doc_id": .string("replace-1"), "find": .string("H₀"), "replace": .string("X")]
        )
        XCTAssertTrue(textOf(withoutFlag).contains("Replaced 0"), textOf(withoutFlag))

        let withFlag = await server.invokeToolForTesting(
            name: "replace_text",
            arguments: [
                "doc_id": .string("replace-1"), "find": .string("H₀"), "replace": .string("X"),
                "match_options": .object(["math_script_insensitive": .bool(true)]),
            ]
        )
        XCTAssertNotEqual(withFlag.isError, true, textOf(withFlag))
        XCTAssertTrue(textOf(withFlag).contains("Replaced 1"), textOf(withFlag))
        XCTAssertTrue(textOf(withFlag).contains("math_script_insensitive normalization"), textOf(withFlag))

        _ = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("replace-1"), "path": .string(savePath)]
        )
        var saved = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        defer { saved.close() }
        XCTAssertTrue(saved.getText().contains("Under X the test statistic"), saved.getText())
    }

    func testReplaceTextBatchPerItemMatchOptionsOverride() async throws {
        let fixture = try makeH0Fixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(fixture.path), "doc_id": .string("batchreplace-1")]
        )
        let r = await server.invokeToolForTesting(
            name: "replace_text_batch",
            arguments: [
                "doc_id": .string("batchreplace-1"),
                "replacements": .array([
                    .object([
                        "find": .string("H₀"), "replace": .string("X"),
                        "match_options": .object(["math_script_insensitive": .bool(true)]),
                    ])
                ]),
            ]
        )
        XCTAssertTrue(textOf(r).contains("1 applied"), textOf(r))
    }
}
