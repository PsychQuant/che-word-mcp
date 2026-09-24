import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#232 — every integer/boolean tool parameter goes
/// through `optionalInt`/`optionalBool` instead of `Value.intValue`/
/// `Value.boolValue` directly. `Value.intValue`/`Value.boolValue` treat "the
/// caller sent the wrong JSON type" and "the caller sent nothing" identically
/// (both become `nil`), so `args["x"]?.intValue ?? default` silently runs
/// with the default and reports success for a present-but-mistyped value.
/// `set_header_row` (#230) is the motivating example: `row_count: "3"`
/// (string) used to be indistinguishable from an absent `row_count`, so the
/// call silently fell back to `row_index=0` instead of erroring.
///
/// Three independent layers, matching che-pptx-mcp#5 / che-pptx-mcp#10:
///  (A) direct unit tests of `optionalInt`/`optionalBool` themselves —
///      exhaustive over the JSON type space, no document fixture needed.
///  (B) a schema-driven source sweep — every `"type": "integer"` /
///      `"type": "boolean"` property in `tools/list` must NOT be read via the
///      unsafe `ident["key"]?.intValue` / `ident["key"]?.boolValue` pattern
///      anywhere in Sources/, and (with two documented exceptions) must have
///      a matching `optionalInt(..., "key")` / `optionalBool(..., "key")`
///      call site. This is what fails when a future contributor adds a new
///      integer/boolean parameter and reads it the old way.
///  (C) representative end-to-end calls through `invokeToolForTesting`,
///      spanning every call-site shape the #232 migration touched (required
///      int via guard+missingParameter, optional int with a numeric
///      default, optional int/bool with no default, optional bool with a
///      default, and a multi-clause nested-dict guard).
final class Issue232StrictIntegerBooleanParameterTests: XCTestCase {

    // MARK: - (A) optionalInt / optionalBool unit tests

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    func testOptionalIntAcceptsJSONInteger() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalInt(["k": .int(5)], "k")
        XCTAssertEqual(value, 5)
    }

    func testOptionalIntAcceptsWholeValuedDouble() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalInt(["k": .double(5.0)], "k")
        XCTAssertEqual(value, 5)
    }

    func testOptionalIntTreatsAbsentKeyAsNil() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalInt([:], "k")
        XCTAssertNil(value)
    }

    func testOptionalIntTreatsJSONNullAsNil() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalInt(["k": .null], "k")
        XCTAssertNil(value)
    }

    /// The exact #230/#232 regression: a present string must error, not be
    /// treated the same as absent.
    func testOptionalIntRejectsStringNamingTheKey() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalInt(["row_count": .string("3")], "row_count")
            XCTFail("expected invalidParameter")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "row_count")
        }
    }

    func testOptionalIntRejectsBool() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalInt(["k": .bool(true)], "k")
            XCTFail("expected invalidParameter")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "k")
        }
    }

    func testOptionalIntRejectsArray() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalInt(["k": .array([.int(1)])], "k")
            XCTFail("expected invalidParameter")
        } catch is WordError { /* expected */ }
    }

    func testOptionalIntRejectsObject() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalInt(["k": .object([:])], "k")
            XCTFail("expected invalidParameter")
        } catch is WordError { /* expected */ }
    }

    func testOptionalIntRejectsFractionalDouble() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalInt(["k": .double(0.5)], "k")
            XCTFail("expected invalidParameter")
        } catch is WordError { /* expected */ }
    }

    /// #5's crash: `Int(3.5)`-style truncation must never run — the pptx-mcp
    /// incident this repo is copying the fix from was exactly a Double →
    /// Int trap on out-of-range magnitudes, not just silent truncation.
    func testOptionalIntRejectsNaNAndInfinityWithoutTrapping() async throws {
        let server = await WordMCPServer()
        for bad: Double in [.nan, .infinity, -.infinity] {
            do {
                _ = try await server.optionalInt(["k": .double(bad)], "k")
                XCTFail("expected invalidParameter for \(bad)")
            } catch is WordError { /* expected, and did not trap */ }
        }
    }

    /// JSON numbers can carry magnitudes far outside `Int` (e.g. `1e300`,
    /// or `2^63` which `JSONDecoder` hands `Value` as `.double` since it
    /// doesn't fit `Int`). `Int(exactly:)` must reject these, never trap.
    func testOptionalIntRejectsOutOfRangeDoublesWithoutTrapping() async throws {
        let server = await WordMCPServer()
        for bad: Double in [1e300, -1e300, 9_223_372_036_854_775_808, -9_223_372_036_854_777_856] {
            do {
                _ = try await server.optionalInt(["k": .double(bad)], "k")
                XCTFail("expected invalidParameter for \(bad)")
            } catch is WordError { /* expected, and did not trap */ }
        }
    }

    func testOptionalBoolAcceptsJSONBool() async throws {
        let server = await WordMCPServer()
        let t = try await server.optionalBool(["k": .bool(true)], "k")
        let f = try await server.optionalBool(["k": .bool(false)], "k")
        XCTAssertEqual(t, true)
        XCTAssertEqual(f, false)
    }

    func testOptionalBoolTreatsAbsentAndNullAsNil() async throws {
        let server = await WordMCPServer()
        let absent = try await server.optionalBool([:], "k")
        let nullValue = try await server.optionalBool(["k": .null], "k")
        XCTAssertNil(absent)
        XCTAssertNil(nullValue)
    }

    /// che-pptx-mcp#10's motivating example: a string `"true"` must not be
    /// silently coerced to a boolean.
    func testOptionalBoolRejectsStringTrue() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalBool(["flag": .string("true")], "flag")
            XCTFail("expected invalidParameter")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "flag")
        }
    }

    func testOptionalBoolRejectsIntZeroAndOne() async throws {
        let server = await WordMCPServer()
        for bad: Value in [.int(0), .int(1)] {
            do {
                _ = try await server.optionalBool(["flag": bad], "flag")
                XCTFail("expected invalidParameter for \(bad)")
            } catch is WordError { /* expected */ }
        }
    }

    // MARK: - (B) schema-driven source sweep

    private static var sourcesDir: URL {
        // Tests/CheWordMCPTests/<this file> → ../../Sources/CheWordMCP
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheWordMCP", isDirectory: true)
    }

    private struct SourceLine {
        let file: String
        let lineNumber: Int
        let trimmed: String
    }

    /// Every non-comment line under Sources/CheWordMCP, for both the
    /// anti-pattern sweep and the positive coverage sweep.
    private static func allSourceLines() throws -> [SourceLine] {
        let fm = FileManager.default
        var files: [URL] = []
        if let walker = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertFalse(files.isEmpty, "sweep found no Swift sources under \(sourcesDir.path)")
        var lines: [SourceLine] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }   // doc comments may quote the anti-pattern as an example
                lines.append(SourceLine(file: url.lastPathComponent, lineNumber: i + 1, trimmed: trimmed))
            }
        }
        return lines
    }

    /// (B.1) — the exact unsafe pattern `optionalInt`/`optionalBool` replace
    /// (`ident["key"]?.intValue` / `ident["key"]?.boolValue`, which cannot
    /// distinguish "wrong type" from "absent") must not exist anywhere in
    /// Sources/CheWordMCP any more. Catches a regression regardless of which
    /// tool or parameter name it lands on.
    ///
    /// Known limitation (Codex R1): this is a textual/regex lint, not a
    /// Swift parser — same tradeoff `RefusalIsErrorSweepTests.swift`'s
    /// source sweep already accepts in this file. It cannot see an
    /// equivalent unsafe read spelled differently (e.g. `let v = args["k"];
    /// v?.intValue ?? 0` split across two statements), only the exact
    /// single-line subscript-chain shape #232's migration actually used.
    func testNoDirectIntOrBoolValueSubscriptChainRemainsInSources() throws {
        let unsafeInt = try NSRegularExpression(pattern: #"\b\w+\["[^"]+"\]\?\.intValue\b"#)
        let unsafeBool = try NSRegularExpression(pattern: #"\b\w+\["[^"]+"\]\?\.boolValue\b"#)
        var offenders: [String] = []
        for line in try Self.allSourceLines() {
            let range = NSRange(line.trimmed.startIndex..., in: line.trimmed)
            if unsafeInt.firstMatch(in: line.trimmed, range: range) != nil
                || unsafeBool.firstMatch(in: line.trimmed, range: range) != nil {
                offenders.append("\(line.file):\(line.lineNumber)  \(line.trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "unsafe direct .intValue/.boolValue subscript chain found:\n\(offenders.joined(separator: "\n"))")
    }

    /// (B.2) — every `"type": "integer"` / `"type": "boolean"` schema
    /// property (besides the documented exceptions) has a matching
    /// `optionalInt(..., "key")` / `optionalBool(..., "key")` call site.
    /// This is what fails when a new integer/boolean parameter is added but
    /// never actually gets the strict-typing treatment. It caught two real,
    /// pre-existing bugs this way: `insert_sequence_field` read
    /// `reset_on_heading` while its schema declared `reset_level`, and
    /// `insert_checkbox` read `is_checked` while its schema declared
    /// `checked` — both fixed alongside this test (see (C) below for the
    /// end-to-end regression tests for each).
    ///
    /// Known limitation (Codex R1): `hasCall` matches a key name against
    /// EVERY `optionalInt`/`optionalBool` call site in the file, not just
    /// the specific tool's own handler — it does not parse the `switch` in
    /// `executeToolTask` to scope the search per tool. In principle a new
    /// tool that declares an integer/boolean parameter sharing a key name
    /// already read by some unrelated tool (e.g. a hypothetical new
    /// `"index"` parameter that is never actually read) could pass this
    /// sweep. It did catch both real bugs above because neither
    /// `reset_level` nor `checked` was read by any handler before the fix —
    /// building a dispatch-table-aware, handler-scoped version would close
    /// this gap but is a larger, separate undertaking.
    func testEveryIntegerAndBooleanSchemaParameterHasAStrictReader() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()
        let lines = try Self.allSourceLines()

        // `insert_watermark` / `insert_image_watermark` are permanent #201
        // stubs (see WatermarkToolsHonestFailureTests.swift): every call
        // throws ToolNotImplemented before any argument is inspected, so
        // `rotation` / `scale` / `washout` / `semitransparent` are schema-
        // documented for the future implementation but never read today —
        // there is no code path to attach optionalInt/optionalBool to.
        let intExceptions: Set<String> = [
            "insert_watermark.rotation",
            "insert_image_watermark.scale",
        ]
        let boolExceptions: Set<String> = [
            "insert_watermark.semitransparent",
            "insert_image_watermark.washout",
            // Issue98InsertEquationLibBypassTests pins an error message that
            // names both "display_mode" and the English word "boolean" —
            // left as its original hand-rolled check (same "present-but-
            // mistyped errors" contract as optionalBool, different wording)
            // rather than changing a pinned test's contract out of #232's
            // scope.
            "insert_equation.display_mode",
            // ScriptPipelineTools.swift's export_script/execute_script
            // already implement the identical "present-but-mistyped errors,
            // explicit null counts as absent" contract by hand (#134, #227),
            // predating #232's shared helper. Left as-is per the
            // coordinator's request not to touch that file's
            // paragraphs-only path while it is under separate concurrent
            // work (ooxml-swift upgrade).
            "execute_script.overwrite",
            "export_script.paragraphs_only",
            // `checkpoint` / `finalize_document` / `save_document` already
            // parse this through the dedicated `allowOrphanImagesFlag(_:)`
            // static helper (R1 #14) — same "absent/null → false, present
            // non-bool → invalidParameter" contract as `optionalBool`, just
            // predating it. `Issue175R2SaveGateTests.swift` calls
            // `WordMCPServer.allowOrphanImagesFlag` by name directly, so
            // folding it into `optionalBool` would need updating that pin
            // for no behavioural change — left alone.
            "checkpoint.allow_orphan_images",
            "finalize_document.allow_orphan_images",
            "save_document.allow_orphan_images",
        ]

        func hasCall(_ fn: String, key: String) -> Bool {
            lines.contains { $0.trimmed.contains("\(fn)(") && $0.trimmed.contains("\"\(key)\")") }
        }

        var missingInt: [String] = []
        var missingBool: [String] = []
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            for (key, property) in properties {
                guard case .object(let p) = property, case .string(let type)? = p["type"] else { continue }
                let pairName = "\(tool.name).\(key)"
                switch type {
                case "integer":
                    if intExceptions.contains(pairName) { continue }
                    if !hasCall("optionalInt", key: key) { missingInt.append(pairName) }
                case "boolean":
                    if boolExceptions.contains(pairName) { continue }
                    if !hasCall("optionalBool", key: key) { missingBool.append(pairName) }
                default:
                    continue
                }
            }
        }
        XCTAssertTrue(missingInt.isEmpty, "integer schema params with no optionalInt(...) call site: \(missingInt.sorted())")
        XCTAssertTrue(missingBool.isEmpty, "boolean schema params with no optionalBool(...) call site: \(missingBool.sorted())")
    }

    // MARK: - (C) representative end-to-end calls

    private func openFixtureDocument(_ server: WordMCPServer, id: String) async throws {
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let para = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
        XCTAssertNotEqual(para.isError, true, resultText(para))
        let table = await server.invokeToolForTesting(
            name: "insert_table",
            arguments: ["doc_id": .string(id), "rows": .int(2), "cols": .int(2)]
        )
        XCTAssertNotEqual(table.isError, true, resultText(table))
    }

    /// `list_comments` returns early with a non-error "No comments in
    /// document" string before it ever reaches `context_chars`/
    /// `include_context` — a fixture with no comments would make a
    /// wrong-type probe pass for the wrong reason.
    private func insertFixtureComment(_ server: WordMCPServer, id: String) async throws {
        let comment = await server.invokeToolForTesting(
            name: "insert_comment",
            arguments: [
                "doc_id": .string(id), "text": .string("note"),
                "author": .string("tester"), "paragraph_index": .int(0),
            ]
        )
        XCTAssertNotEqual(comment.isError, true, resultText(comment))
    }

    /// #230/#232 motivating example: a present-but-mistyped `row_count`
    /// must be rejected, not silently treated as absent and fall back to
    /// `row_index=0`.
    /// #232 R1 (Codex finding 6): `get_document_text` cannot observe a
    /// `<w:tblHeader/>` change at all — it is a table row PROPERTY, not
    /// text — so comparing text before/after would pass even if the
    /// rejected call *had* silently applied `row_index=0` (the exact #230
    /// regression this issue exists to close). Read the row flags
    /// (`TablesHyperlinksHeadersToolsTests.swift`'s own verification seam)
    /// directly off the in-memory document instead.
    private func headerFlags(_ server: WordMCPServer, id: String, tableIndex: Int = 0) async -> [Bool] {
        let doc = await server.openDocuments[id]
        let tables = doc?.getTables() ?? []
        guard tableIndex < tables.count else { return [] }
        return tables[tableIndex].rows.map(\.properties.isHeader)
    }

    func testSetHeaderRowRejectsStringRowCountNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-header-row"
        try await openFixtureDocument(server, id: id)
        let beforeFlags = await headerFlags(server, id: id)

        let result = await server.invokeToolForTesting(
            name: "set_header_row",
            arguments: ["doc_id": .string(id), "table_index": .int(0), "row_count": .string("3")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("row_count"), resultText(result))

        let afterFlags = await headerFlags(server, id: id)
        XCTAssertEqual(beforeFlags, afterFlags, "a rejected set_header_row must not mark any row as header")
        XCTAssertEqual(afterFlags, [false, false], "row_count=\"3\" must not silently fall back to row_index=0 (#230's motivating regression)")
    }

    /// #232 R2 (Codex LOW finding): `row_count: 1.0` marks exactly one row
    /// as header, which is indistinguishable from the pre-#232 regression
    /// (a silently-ignored row_count falling back to `row_index=0`, also
    /// one row). Use `row_count: 2.0` on this fixture's 2-row table instead
    /// — `[true, true]` can only come from the double actually converting
    /// to `2`, not from any fallback path.
    func testSetHeaderRowAcceptsWholeValuedDoubleRowCount() async throws {
        let server = await WordMCPServer()
        let id = "s232-header-row-double"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_header_row",
            arguments: ["doc_id": .string(id), "table_index": .int(0), "row_count": .double(2.0)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let flags = await headerFlags(server, id: id)
        XCTAssertEqual(flags, [true, true], "row_count=2.0 must mark both fixture rows as header")
    }

    func testInsertTableRejectsStringRowsNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-insert-table"
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))

        let result = await server.invokeToolForTesting(
            name: "insert_table", arguments: ["doc_id": .string(id), "rows": .string("2"), "cols": .int(2)]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("rows"), resultText(result))
        let dirtyAfterRejection = await server.isDocumentDirtyForTesting(id)
        XCTAssertEqual(dirtyAfterRejection, false, "a rejected insert_table must not dirty the document")
    }

    func testUpdateCellRejectsBoolRowNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-update-cell"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "update_cell",
            arguments: ["doc_id": .string(id), "table_index": .int(0), "row": .bool(true), "col": .int(0), "text": .string("x")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("row"), resultText(result))
    }

    /// #232 R1 (Codex finding 5): `insert_checkbox` used to read `is_checked`,
    /// a key the schema never declared (it declares `checked`) — the fix
    /// renamed the read. Confirms the schema's actual key now flows through
    /// end-to-end, not just that *some* key is read.
    func testInsertCheckboxHonoursSchemaCheckedKey() async throws {
        let server = await WordMCPServer()
        let id = "s232-checkbox-checked"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_checkbox",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "name": .string("cb1"), "checked": .bool(true)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("checked: true"), resultText(result))
    }

    /// #232 R1 (Codex finding 5): `insert_sequence_field` used to read
    /// `reset_on_heading`, a key the schema never declared (it declares
    /// `reset_level`) — every value, of any type, was silently ignored. A
    /// wrong-type `reset_level` naming the parameter proves the schema's
    /// actual key is now being read, not just that the tool errors for some
    /// unrelated reason.
    func testInsertSequenceFieldRejectsStringResetLevelNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-seqfield-reset-level"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_sequence_field",
            arguments: [
                "doc_id": .string(id), "paragraph_index": .int(0), "identifier": .string("Figure"),
                "reset_level": .string("1"),
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("reset_level"), resultText(result))
    }

    func testGetCaptionRejectsStringIndexNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-get-caption"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "get_caption", arguments: ["doc_id": .string(id), "index": .string("0")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("index"), resultText(result))
    }

    /// `format_text`'s `bold`/`italic`/`underline` are optional booleans
    /// with NO default (nil means "leave unchanged") — a different call
    /// shape than `set_header_row`'s defaulted optionals.
    func testFormatTextRejectsStringBoldNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-format-text"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "bold": .string("true")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("bold"), resultText(result))
    }

    /// `format_text`'s `font_size` is an optional integer with no default.
    func testFormatTextRejectsDoubleFontSizeNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-format-text-fontsize"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "font_size": .double(12.5)]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("font_size"), resultText(result))
    }

    /// `list_comments`' `context_chars` is an optional integer WITH a
    /// numeric default (`?? 50`), wrapped in `max(0, ...)` — the shape that
    /// needed the `try` placement fix during the #232 migration.
    func testListCommentsRejectsStringContextCharsNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-list-comments"
        try await openFixtureDocument(server, id: id)
        try await insertFixtureComment(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string(id), "context_chars": .string("50")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("context_chars"), resultText(result))
    }

    /// `list_comments`' `include_context` is an optional boolean with a
    /// default (`?? false`).
    func testListCommentsRejectsIntIncludeContextNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-list-comments-bool"
        try await openFixtureDocument(server, id: id)
        try await insertFixtureComment(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string(id), "include_context": .int(1)]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("include_context"), resultText(result))
    }

    /// #232 R1 (Codex finding 3): `list_comments` returns an early,
    /// non-error "No comments in document" before it used to reach
    /// `context_chars`/`include_context` at all — a mistyped value on a
    /// comment-free document silently succeeded, the same "mistyped ==
    /// absent" shape #232 closes elsewhere, reached via a different code
    /// path. The fixture here deliberately has NO comments (unlike the two
    /// tests above), so this only passes because parsing now happens before
    /// the early return.
    func testListCommentsRejectsStringContextCharsEvenWithNoComments() async throws {
        let server = await WordMCPServer()
        let id = "s232-list-comments-empty"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "list_comments",
            arguments: ["doc_id": .string(id), "context_chars": .string("50")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("context_chars"), resultText(result))
    }

    /// `create_document`'s `autosave` is an optional boolean with a default
    /// — exercises the top-level (non-nested) `args["x"]` shape once more,
    /// on a tool that needs no fixture document.
    func testCreateDocumentRejectsStringAutosaveNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let result = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("s232-create-autosave"), "autosave": .string("true")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("autosave"), resultText(result))
    }

    /// `insert_paragraph`'s `into_table_cell` is a nested object whose
    /// `table_index`/`row`/`col` fields are read via a multi-clause
    /// `guard let ... = try optionalInt(cellDict, "...")` — the shape that
    /// needed each clause converted independently during the migration.
    func testInsertParagraphRejectsStringTableIndexInsideIntoTableCellNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232-insert-paragraph-cell"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string(id),
                "text": .string("cell text"),
                "into_table_cell": .object([
                    "table_index": .string("0"), "row": .int(0), "col": .int(0),
                ]),
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("table_index"), resultText(result))
    }

    /// #232 R1 (Codex finding "batch worth testing more"): `replace_text_batch`
    /// documents itself as "Non-atomic per-item: individual failures ...
    /// reported but don't rollback prior successes." The mechanical
    /// migration first put `try optionalBool(item, "regex")` OUTSIDE that
    /// item's `do { ... } catch { per-item failure } ` block — a mistyped
    /// `regex` on item N would throw straight out of the whole function,
    /// aborting the call AND silently discarding item N-1's already-applied
    /// (but not yet persisted) replacement. Fixed by moving the parse
    /// inside an equivalent per-item catch.
    ///
    /// Valid → invalid → valid (R2, Codex LOW finding): proves the failure
    /// doesn't just "not roll back what came before" but also doesn't stop
    /// the loop — item 2, which comes AFTER the failing item, must still
    /// run and its effect must be observable.
    func testReplaceTextBatchIsolatesAPerItemBoolTypeErrorFromOtherItems() async throws {
        let server = await WordMCPServer()
        let id = "s232-replace-batch"
        try await openFixtureDocument(server, id: id)

        let result = await server.invokeToolForTesting(
            name: "replace_text_batch",
            arguments: [
                "doc_id": .string(id),
                "replacements": .array([
                    .object(["find": .string("Anchor"), "replace": .string("Anchored")]),
                    .object(["find": .string("Anchored"), "replace": .string("x"), "regex": .string("no")]),
                    .object(["find": .string("Anchored"), "replace": .string("Final")]),
                ]),
            ]
        )
        XCTAssertNotEqual(result.isError, true, "a per-item type error must not fail the whole batch call: \(resultText(result))")
        let text = resultText(result)
        XCTAssertTrue(text.contains("2 applied, 1 failed"), text)
        XCTAssertTrue(text.contains("regex"), "the failed item's message should name the parameter: \(text)")

        let search = await server.invokeToolForTesting(
            name: "search_text", arguments: ["doc_id": .string(id), "query": .string("Final")]
        )
        XCTAssertNotEqual(search.isError, true, resultText(search))
        XCTAssertTrue(
            resultText(search).contains("Found 1 match"),
            "item 2 (after the failing item) must still have run: \(resultText(search))"
        )
    }

    /// Same shape as the replace_text_batch fix, for `search_text_batch`'s
    /// per-query `case_sensitive`. Valid → invalid → valid, and each valid
    /// item's assertion checks the actual match count, not just that its
    /// `=== [i] query=... ===` heading line is present (R2, Codex LOW
    /// finding — the heading alone appears for a zero-match query too).
    func testSearchTextBatchIsolatesAPerItemBoolTypeErrorFromOtherItems() async throws {
        let server = await WordMCPServer()
        let id = "s232-search-batch"
        try await openFixtureDocument(server, id: id)

        let result = await server.invokeToolForTesting(
            name: "search_text_batch",
            arguments: [
                "doc_id": .string(id),
                "queries": .array([
                    .string("Anchor"),
                    .object(["query": .string("Anchor"), "case_sensitive": .string("no")]),
                    .string("Anchor"),
                ]),
            ]
        )
        XCTAssertNotEqual(result.isError, true, "a per-item type error must not fail the whole batch call: \(resultText(result))")
        let text = resultText(result)
        XCTAssertTrue(
            text.contains("[0] query='Anchor' ===\nFound 1 match"),
            "the first (valid) query must have actually found a match, not just run: \(text)"
        )
        XCTAssertTrue(text.contains("[1] FAIL:") && text.contains("case_sensitive"), text)
        XCTAssertTrue(
            text.contains("[2] query='Anchor' ===\nFound 1 match"),
            "the third query (after the failing item) must still run and find a match: \(text)"
        )
    }

    /// #232 R2 (Codex MEDIUM finding): `border_size` used to be parsed only
    /// inside the `border_style`-gated block, so a mistyped `border_size`
    /// supplied WITHOUT `border_style` was never read and never errored.
    func testSetTableStyleRejectsStringBorderSizeEvenWithoutBorderStyle() async throws {
        let server = await WordMCPServer()
        let id = "s232-table-style-border-size"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_table_style",
            arguments: ["doc_id": .string(id), "table_index": .int(0), "border_size": .string("4")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("border_size"), resultText(result))
    }

    /// #232 R2 (Codex MEDIUM finding): `cell_col`'s type was only checked
    /// when `cell_row` was also present — an `if let a = ..., let b = ...`
    /// chain short-circuits, so `cell_col`'s `try optionalInt` was never
    /// even evaluated when `cell_row` was absent.
    func testSetTableStyleRejectsStringCellColEvenWithoutCellRow() async throws {
        let server = await WordMCPServer()
        let id = "s232-table-style-cell-col"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_table_style",
            arguments: ["doc_id": .string(id), "table_index": .int(0), "cell_col": .string("0")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("cell_col"), resultText(result))
    }
}
