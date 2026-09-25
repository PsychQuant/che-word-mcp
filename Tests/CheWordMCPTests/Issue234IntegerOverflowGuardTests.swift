import XCTest
import MCP
import OOXMLSwift
import CoreGraphics
import ImageIO
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

    // MARK: - (D) team-lead follow-up: `resolveImageDimensions` /
    // `insert_image` / `insert_image_from_path` / `update_image` —
    // package-boundary crash the team lead's reviewer found while
    // continuing to review R7 (not yet reproduced by them; reproduced here
    // via real binary over stdio before writing these tests, per the exact
    // instruction "用真實 binary 經 stdio 重現，再修正並補測試").
    //
    // This is a THIRD layer of the same bug class, distinct from (A)/(B)
    // above: `resolveImageDimensions` computes a MISSING width/height via
    // `Double(w) / aspectRatio` or `Double(h) * aspectRatio` — a runtime
    // ratio, not a fixed literal constant, so it needed its own
    // `safeInt(fromArithmeticResult:key:)` guard (mirroring `twipsLine`'s
    // shape) rather than `validatedScaledMeasurement`. But fixing THAT
    // alone was not sufficient: `Drawing.from(widthPx:heightPx:)` and
    // `Document.updateImage` — both in ooxml-swift, a SEPARATE package this
    // repo cannot modify — do their own unguarded `widthPx * 9525`/
    // `heightPx * 9525` (pixels → EMU) further downstream, reachable
    // directly (no aspect-ratio math at all) by `insert_image` (base64) and
    // `update_image`, and by `insert_image_from_path` even when BOTH
    // width/height are user-supplied (no `resolveImageDimensions` math
    // involved at all). Hence `imagePixelDimensionRange`, applied at all
    // three call sites.

    /// Real PNG file of the given pixel size (reusing the pattern already
    /// established in `Issue175SaveImageConsistencyTests.pngData`), so
    /// `ImageDimensions.detect(path:)` reads a genuine IHDR chunk and
    /// `native.aspectRatio` is the real ratio, not a stubbed value.
    private func pngData(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = { () -> CGImage? in
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                return ctx.makeImage()
            }()
        else { throw XCTSkip("CGContext unavailable") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else {
            throw XCTSkip("PNG encoder unavailable")
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func tempPNGPath(width: Int, height: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("i234-\(UUID().uuidString).png")
        try pngData(width: width, height: height).write(to: url)
        return url.path
    }

    // MARK: (D.1) `safeInt(fromArithmeticResult:key:)` unit tests

    func testSafeIntFromArithmeticResultAcceptsOrdinaryValues() throws {
        XCTAssertEqual(try WordMCPServer.safeInt(fromArithmeticResult: 1000.0, key: "width"), 1000)
        XCTAssertEqual(try WordMCPServer.safeInt(fromArithmeticResult: 0.0, key: "width"), 0)
        XCTAssertEqual(try WordMCPServer.safeInt(fromArithmeticResult: -1000.0, key: "width"), -1000)
    }

    /// The precise reason a `value <= Double(Int.max)` bound would have
    /// been wrong: `Double(Int.max)` itself is NOT exactly representable
    /// and rounds UP to exactly `0x1p63` (2^63), which is one past what
    /// `Int(_:)` can hold. `0x1p63` must be REJECTED even though it prints
    /// identically to `Double(Int.max)`.
    func testSafeIntFromArithmeticResultRejectsExactlyTwoToThe63() throws {
        XCTAssertEqual(0x1p63, Double(Int.max), "sanity: Double(Int.max) rounds up to exactly 2^63")
        do {
            _ = try WordMCPServer.safeInt(fromArithmeticResult: 0x1p63, key: "width")
            XCTFail("2^63 must be rejected, not silently accepted via Double(Int.max) rounding")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "width")
        }
    }

    func testSafeIntFromArithmeticResultRejectsNonFiniteAndOutOfRange() throws {
        // `-0x1p63 - 1024` would NOT actually test "below the floor": at
        // this magnitude the ULP is 2^11 = 2048, so subtracting 1024 (half
        // a ULP) rounds back to exactly `-0x1p63` under round-to-nearest-
        // even — which is itself IN range (the guard is `value >= -0x1p63`).
        // `-0x1p64` (one full power-of-two below, well outside any
        // rounding ambiguity) is the value that actually exercises the
        // lower-bound rejection path.
        for bad in [Double.nan, Double.infinity, -Double.infinity, 0x1p63, -0x1p64] {
            do {
                _ = try WordMCPServer.safeInt(fromArithmeticResult: bad, key: "height")
                XCTFail("expected invalidParameter for \(bad)")
            } catch WordError.invalidParameter(let key, _) {
                XCTAssertEqual(key, "height")
            } catch {
                XCTFail("expected WordError.invalidParameter, got \(error)")
            }
        }
    }

    func testSafeIntFromArithmeticResultAcceptsJustInsideTheBoundary() throws {
        // -0x1p63 itself IS in range (the guard is `value >= -0x1p63`);
        // just below 0x1p63 is the largest acceptable positive value.
        XCTAssertEqual(try WordMCPServer.safeInt(fromArithmeticResult: -0x1p63, key: "height"), Int.min)
        XCTAssertNoThrow(try WordMCPServer.safeInt(fromArithmeticResult: 0x1p63.nextDown, key: "height"))
    }

    // MARK: (D.2) `insert_image_from_path` — auto-computed dimension via
    // aspect ratio must not trap, whichever operand is the large one.

    /// Case `(.some(width), nil)` with a 100×100 (aspect ratio exactly 1.0)
    /// image — the most "ordinary" aspect ratio there is. Still traps
    /// pre-fix because `Double(Int.max) / 1.0` rounds up past `Int.max`.
    /// Caught by `safeInt`, naming "width" (the parameter the caller
    /// actually supplied).
    func testInsertImageFromPathAutoHeightFromWidthRejectsOverflow() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-autoheight"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "width": .int(Int.max)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("width"), resultText(result))
    }

    /// Case `(nil, .some(height))` with a 1×1000 (aspect ratio 0.001) image
    /// — the computed `width` (`Int.max * 0.001` ≈ 9.2e15) does NOT trap
    /// `safeInt` (it is well inside `Int`'s range), but IS far outside
    /// `imagePixelDimensionRange`, so it must still be rejected — this was
    /// the exact case still crashing after the first, incomplete fix
    /// (`safeInt` alone, before `imagePixelDimensionRange` was added).
    func testInsertImageFromPathAutoWidthFromHeightRejectsOutOfRangeResult() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-autowidth"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 1, height: 1000)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "height": .int(Int.max)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("width") || resultText(result).contains("height"), resultText(result))
    }

    /// Both width/height user-supplied directly — no aspect-ratio math in
    /// `resolveImageDimensions` at all (the `(.some, .some)` branch returns
    /// immediately), so this exercises `insertImageFromPath`'s OWN
    /// `imagePixelDimensionRange` guard, not `safeInt`.
    func testInsertImageFromPathBothDimensionsGivenRejectsOutOfRange() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-bothgiven"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "width": .int(Int.max), "height": .int(Int.max)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("width"), resultText(result))
    }

    /// Ordinary values must keep working — no regression.
    func testInsertImageFromPathOrdinaryValuesStillSucceed() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-ordinary"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "width": .int(300), "height": .int(150)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("300x150"), resultText(result))
    }

    // MARK: (D.3) `insert_image` (base64) — no `resolveImageDimensions`
    // involved at all (both width/height are `missingParameter`-required),
    // so this is purely `insertImage`'s own `imagePixelDimensionRange`
    // guard, added because `Drawing.from(widthPx:heightPx:)` is shared with
    // `insert_image_from_path`.

    func testInsertImageBase64RejectsOverflowingWidth() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-b64-width"
        try await openFixtureDocument(server, id: id)

        let result = await server.invokeToolForTesting(
            name: "insert_image",
            arguments: [
                "doc_id": .string(id), "base64": .string("AA=="), "file_name": .string("x.png"),
                "width": .int(Int.max), "height": .int(10),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("width"), resultText(result))
    }

    func testInsertImageBase64RejectsOverflowingHeight() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-b64-height"
        try await openFixtureDocument(server, id: id)

        let result = await server.invokeToolForTesting(
            name: "insert_image",
            arguments: [
                "doc_id": .string(id), "base64": .string("AA=="), "file_name": .string("x.png"),
                "width": .int(10), "height": .int(Int.max),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("height"), resultText(result))
    }

    // MARK: (D.4) `update_image` — same shared `Document.updateImage` ×
    // 9525 as `Drawing.from`; both width/height are optional here.

    func testUpdateImageRejectsOverflowingWidth() async throws {
        let server = await WordMCPServer()
        let id = "s234-img-update"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 100, height: 100)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let insert = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "width": .int(200), "height": .int(200)]
        )
        XCTAssertNotEqual(insert.isError, true, resultText(insert))
        // Parse the id out of "Inserted image 'x.png' with id 'rIdN' (...)".
        guard let range = resultText(insert).range(of: "with id '") else {
            XCTFail("could not find image id in: \(resultText(insert))"); return
        }
        let afterPrefix = resultText(insert)[range.upperBound...]
        guard let closeQuote = afterPrefix.firstIndex(of: "'") else {
            XCTFail("could not find image id in: \(resultText(insert))"); return
        }
        let imageId = String(afterPrefix[afterPrefix.startIndex..<closeQuote])

        let update = await server.invokeToolForTesting(
            name: "update_image",
            arguments: ["doc_id": .string(id), "image_id": .string(imageId), "width": .int(Int.max)]
        )
        XCTAssertEqual(update.isError, true, resultText(update))
        XCTAssertTrue(resultText(update).contains("width"), resultText(update))
    }

    // MARK: - (E) R8: crash sites an independent fuzzer found that #234's
    // own manual audit missed — team lead's explicit completion condition
    // for this round is mechanical (the fuzzer finding zero crashes), not
    // "more manual auditing." See `scripts/fuzz-extreme-params.py` for the
    // fuzzer itself (adapted from `rev232b`'s probe scripts) and this
    // round's report section for the actual fuzzer run's output.

    func testCreateNumberingDefinitionRejectsOutOfRangeIlvl() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-numdef-ilvl"
        try await openFixtureDocument(server, id: id)
        for bad: Value in [.int(Int.max), .int(Int.min), .int(9), .int(-1)] {
            let result = await server.invokeToolForTesting(
                name: "create_numbering_definition",
                arguments: [
                    "doc_id": .string(id),
                    "levels": .array([.object(["ilvl": bad, "num_format": .string("decimal"), "lvl_text": .string("%1.")])]),
                ]
            )
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("ilvl"), "\(bad): \(resultText(result))")
        }
        let ok = await server.invokeToolForTesting(
            name: "create_numbering_definition",
            arguments: [
                "doc_id": .string(id),
                "levels": .array([.object(["ilvl": .int(8), "num_format": .string("decimal"), "lvl_text": .string("%1.")])]),
            ]
        )
        XCTAssertNotEqual(ok.isError, true, resultText(ok))
    }

    func testInsertCaptionRejectsOverflowingOrNegativeParagraphIndex() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-caption-idx"
        try await openFixtureDocument(server, id: id)
        for bad: Value in [.int(Int.max), .int(-1)] {
            let result = await server.invokeToolForTesting(
                name: "insert_caption",
                arguments: ["doc_id": .string(id), "label": .string("Figure"), "caption_text": .string("c"), "paragraph_index": bad]
            )
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("paragraph_index"), "\(bad): \(resultText(result))")
        }
    }

    func testInsertTableRejectsOutOfRangeRowsAndCols() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-table-bounds"
        try await openFixtureDocument(server, id: id)
        let cases: [(String, Value, Value)] = [
            ("rows", .int(-1), .int(2)),
            ("rows", .int(0), .int(2)),
            ("rows", .int(2_147_483_648), .int(1)),
            ("cols", .int(2), .int(-1)),
            ("cols", .int(2), .int(0)),
            ("cols", .int(2), .int(64)),
        ]
        for (namedKey, rows, cols) in cases {
            let result = await server.invokeToolForTesting(
                name: "insert_table",
                arguments: ["doc_id": .string(id), "rows": rows, "cols": cols]
            )
            XCTAssertEqual(result.isError, true, "\(namedKey)=\(rows)/\(cols): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains(namedKey), "\(namedKey)=\(rows)/\(cols): \(resultText(result))")
        }
        let ok = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(id), "rows": .int(2), "cols": .int(63)]
        )
        XCTAssertNotEqual(ok.isError, true, resultText(ok))
    }

    func testInsertNestedTableRejectsOutOfRangeRowsAndCols() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-nested-bounds"
        try await openFixtureDocument(server, id: id)
        let parent = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(id), "rows": .int(2), "cols": .int(2)]
        )
        XCTAssertNotEqual(parent.isError, true, resultText(parent))
        for bad: Value in [.int(-1), .int(0), .int(2_147_483_648)] {
            let result = await server.invokeToolForTesting(
                name: "insert_nested_table",
                arguments: [
                    "doc_id": .string(id), "parent_table_index": .int(0), "row_index": .int(0), "col_index": .int(0),
                    "rows": bad, "cols": .int(1),
                ]
            )
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("rows"), "\(bad): \(resultText(result))")
        }
    }

    func testInsertTextRejectsNegativePositionInsteadOfTrapping() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-inserttext-negpos"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "text": .string("X"), "position": .int(-1)]
        )
        // R9 (review `rev232c` M-3): rejected, not clamped to 0 — see
        // `insertText`'s R9 comment. (R8 clamped it; that wrote the text at
        // the start while reporting "position -1".)
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("position"), resultText(result))
    }

    func testInsertTocRejectsOutOfRangeOrInvertedLevels() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-toc-levels"
        try await openFixtureDocument(server, id: id)
        // R9 (review `rev232c` LOW-1): each case names the parameter that is
        // actually wrong — R8 named `min_level` for all of them, and this
        // test used to lock that in for `max_level: 10`.
        let cases: [([String: Value], String)] = [
            (["min_level": .int(5), "max_level": .int(1)], "min_level"),
            (["min_level": .int(Int.max), "max_level": .int(Int.max)], "min_level"),
            (["min_level": .int(Int.min), "max_level": .int(Int.max)], "min_level"),
            (["min_level": .int(0), "max_level": .int(3)], "min_level"),
            (["min_level": .int(1), "max_level": .int(10)], "max_level"),
        ]
        for (args, key) in cases {
            var full = args
            full["doc_id"] = .string(id)
            let result = await server.invokeToolForTesting(name: "insert_toc", arguments: full)
            XCTAssertEqual(result.isError, true, "\(args): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("Invalid parameter '\(key)'"), "\(args): \(resultText(result))")
        }
        let ok = await server.invokeToolForTesting(
            name: "insert_toc", arguments: ["doc_id": .string(id), "min_level": .int(1), "max_level": .int(3)]
        )
        XCTAssertNotEqual(ok.isError, true, resultText(ok))
    }

    /// R8 (`rev232b` review of #234, "上限值的依據" §3): `left`/`right` are
    /// `UInt32Value` (unsigned) in the OOXML SDK, `top`/`bottom` are
    /// `Int32Value` (signed) — they must NOT share a range.
    func testSetPageMarginsRejectsNegativeLeftRightButAcceptsNegativeTopBottom() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-margins-signed"
        try await openFixtureDocument(server, id: id)
        for key in ["left", "right"] {
            let result = await server.invokeToolForTesting(
                name: "set_page_margins", arguments: ["doc_id": .string(id), key: .int(-100)]
            )
            XCTAssertEqual(result.isError, true, "\(key): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains(key), "\(key): \(resultText(result))")
        }
        for key in ["top", "bottom"] {
            let result = await server.invokeToolForTesting(
                name: "set_page_margins", arguments: ["doc_id": .string(id), key: .int(-100)]
            )
            XCTAssertNotEqual(result.isError, true, "\(key): \(resultText(result))")
        }
    }

    /// R8 (`rev232b` review of #234, M-234-6): this exact case — a WIDE
    /// image (aspect ratio > 1) given only `height` — was the one mutation
    /// that survived because the existing test used a TALL image (aspect
    /// ratio 0.001), where the computed `width` never got large enough to
    /// exercise `safeInt`'s own guard (it was caught by
    /// `imagePixelDimensionRange` instead, one layer downstream). This test
    /// uses a 1000×1 image (aspect ratio 1000.0) so `Double(Int.max) *
    /// 1000.0` is what `safeInt` itself must catch.
    func testInsertImageFromPathAutoWidthFromHeightWithWideImageRejectsOverflow() async throws {
        let server = await WordMCPServer()
        let id = "s234r8-img-wide-height-only"
        try await openFixtureDocument(server, id: id)
        let png = try tempPNGPath(width: 1000, height: 1)
        defer { try? FileManager.default.removeItem(atPath: png) }

        let result = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: ["doc_id": .string(id), "path": .string(png), "height": .int(Int.max)]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("height"), resultText(result))
    }

}
