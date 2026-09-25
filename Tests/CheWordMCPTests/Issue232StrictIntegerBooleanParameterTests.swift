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
///  (A) direct unit tests of `optionalInt`/`optionalBool` themselves — every
///      JSON `Value` case that isn't the expected one (string/bool/array/
///      object for `optionalInt`; string/int/array/object for
///      `optionalBool`), plus the numeric edge cases (fractional, NaN,
///      ±Infinity, out-of-`Int`-range), no document fixture needed.
///  (B) a schema-driven source sweep — every top-level `"type": "integer"` /
///      `"type": "boolean"` property in `tools/list` must NOT be read via the
///      unsafe `ident["key"]?.intValue` / `ident["key"]?.boolValue` pattern
///      anywhere in Sources/, and (with the documented exceptions in
///      `testEveryIntegerAndBooleanSchemaParameterHasAStrictReader` below)
///      must have a matching `optionalInt(..., "key")` /
///      `optionalBool(..., "key")` call site SOMEWHERE in the file. This is
///      what fails when a future contributor adds a new top-level
///      integer/boolean parameter and reads it the old way — it does not
///      recurse into nested object/array schemas, and it does not prove the
///      call site is reachable on every code path (see that test's own doc
///      comment for both limitations in detail).
///  (C) representative end-to-end calls through `invokeToolForTesting`,
///      spanning every call-site shape the #232 migration touched (required
///      int via guard+missingParameter, optional int with a numeric
///      default, optional int/bool with no default, optional bool with a
///      default, a multi-clause nested-dict guard, and two conditionally-
///      gated reads that used to skip validation entirely — see
///      `testSetTableStyleRejectsStringBorderSizeEvenWithoutBorderStyle`).
///
/// #232 R7 (`rev232b` review LOW-2): this comment used to say the sites
/// below "were not individually fixed" and that closing them was "a
/// separate, larger undertaking better suited to its own follow-up issue."
/// That was true when Codex's R3 review wrote it — it is NOT true any more.
/// R4 fixed every site R3 actually named (`format_text.run_index`, the
/// page-margin presets, `accept_revision`/`reject_revision.revision_id`,
/// `replyToComment`'s `comment_id ?? parent_comment_id` short-circuit); R5
/// and R6 went on to close every other conditionally-gated read the file's
/// static sweeps and an independent human-assigned re-review (`rev232b`,
/// PASS, zero remaining HIGH findings) could find. #232's policy, as
/// team-lead finally settled it in R5, IS "every argument must validate
/// regardless of which branch of the tool's own logic would actually use
/// it" — the narrower R3-era framing this comment used to describe is
/// obsolete. What's left, as of R7, are two DIFFERENT classes of problem
/// this policy was never meant to cover: a value read via the wrong
/// STRICT-TYPING HELPER for its schema's declared type (`insert_floating_
/// image`'s position parameters read `optionalInt` when the schema says
/// `"string"` — fixed in R7 M3; see the CHANGELOG's `R7` entry), and
/// pre-existing `Int * Int` overflow traps unrelated to #232's
/// wrong-type-vs-absent conflation (e.g. `format_text({font_size:
/// Int.max})`, present on `gh/main` before #232 and explicitly left alone
/// by R7 M2 as a different bug class — see the CHANGELOG's M2 entry).
final class Issue232StrictIntegerBooleanParameterTests: XCTestCase {

    /// #232 R6 (review LOW-6): `R5FixtureFile.existingFilePath` writes a
    /// throwaway `.bin` file under `NSTemporaryDirectory()` the first time
    /// any test in this class touches it, and — being a lazily-initialized
    /// `static let` — never had anywhere natural to delete it again, so
    /// every test run left one more `s232r5-fixture-*.bin` behind. Class-level
    /// `tearDown()` runs once after every test in this class has finished
    /// (unlike instance `tearDown()`, which runs per-test and would fire
    /// before later tests still needed the fixture), so it's the right place
    /// to remove it exactly once.
    override class func tearDown() {
        R5FixtureFile.cleanUp()
        super.tearDown()
    }

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

    /// (Codex R3): `optionalBool` had no direct test naming `.double`,
    /// `.array`, or `.object` explicitly, only `.string`/`.int` — the
    /// doc comment above claims exhaustive coverage of the JSON type space,
    /// so it needs one per remaining case.
    func testOptionalBoolRejectsDoubleArrayAndObject() async throws {
        let server = await WordMCPServer()
        for bad: Value in [.double(1.0), .array([.bool(true)]), .object([:])] {
            do {
                _ = try await server.optionalBool(["flag": bad], "flag")
                XCTFail("expected invalidParameter for \(bad)")
            } catch is WordError { /* expected */ }
        }
    }

    // MARK: - (A.2) optionalDouble unit tests
    //
    // #232 R6 (review "範圍外" item): `optionalDouble` is the `"type":
    // "number"`-schema counterpart to `optionalInt`/`optionalBool`, added to
    // fix `set_paragraph_format`'s `line_spacing`, which used to read
    // `args["line_spacing"]?.doubleValue` directly — a call that only
    // matches the `.double` JSON case, so a whole-valued `line_spacing`
    // (JSON `2`, which decodes to `.int` on this platform, exactly like
    // every other whole-valued JSON number here — see the `optionalInt` doc
    // comment above) fell through to `nil` and was silently dropped, not
    // even applied with a default. That is a worse failure mode than #232's
    // original "wrong type silently defaults": a *correctly-typed,
    // in-range, documented* value was thrown away with no error at all.

    func testOptionalDoubleAcceptsJSONDouble() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalDouble(["k": .double(1.5)], "k")
        XCTAssertEqual(value, 1.5)
    }

    /// The exact `line_spacing` motivating bug: a whole-valued number must
    /// be accepted, not silently dropped because it happens to decode as
    /// `.int` rather than `.double`.
    func testOptionalDoubleAcceptsJSONInteger() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalDouble(["k": .int(2)], "k")
        XCTAssertEqual(value, 2.0)
    }

    func testOptionalDoubleTreatsAbsentKeyAsNil() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalDouble([:], "k")
        XCTAssertNil(value)
    }

    func testOptionalDoubleTreatsJSONNullAsNil() async throws {
        let server = await WordMCPServer()
        let value = try await server.optionalDouble(["k": .null], "k")
        XCTAssertNil(value)
    }

    func testOptionalDoubleRejectsStringNamingTheKey() async throws {
        let server = await WordMCPServer()
        do {
            _ = try await server.optionalDouble(["line_spacing": .string("1.5")], "line_spacing")
            XCTFail("expected invalidParameter")
        } catch WordError.invalidParameter(let key, _) {
            XCTAssertEqual(key, "line_spacing")
        }
    }

    func testOptionalDoubleRejectsBoolArrayAndObject() async throws {
        let server = await WordMCPServer()
        for bad: Value in [.bool(true), .array([.double(1.0)]), .object([:])] {
            do {
                _ = try await server.optionalDouble(["k": bad], "k")
                XCTFail("expected invalidParameter for \(bad)")
            } catch is WordError { /* expected */ }
        }
    }

    // MARK: - (A.3) anchorPresence int predicates (review LOW-1)
    //
    // #232 R6 (review LOW-1): `WordMCPServer.anchorPresence`'s three int-typed
    // anchor predicates (`index`, `paragraph_index`, `after_table_index`) used
    // to read `$0.intValue != nil` directly — only matching `.int` — which was
    // inconsistent with `optionalInt`'s `Int(exactly:)` rule (a whole-valued
    // `.double` like `3.0` counts as present everywhere else in this file).
    // Fixed via the private `looksLikeIntAnchor(_:)` helper, which isn't
    // directly reachable from this test target (it's `private`, and this is a
    // separate module even with `@testable import`) — but `anchorPresence`
    // itself is internal and already exercised directly by
    // `AnchorDXConsistencyTests.swift`, so calling its closures is the way to
    // observe `looksLikeIntAnchor`'s behavior without loosening its access
    // level just for a test.
    func testAnchorPresenceIndexPredicatesAcceptWholeValuedDouble() {
        for key in ["index", "paragraph_index", "after_table_index"] {
            let predicate = WordMCPServer.anchorPresence[key]
            XCTAssertNotNil(predicate, "anchorPresence missing entry for \(key)")
            XCTAssertTrue(predicate?(.double(3.0)) ?? false, "\(key): whole-valued .double(3.0) should count as present")
            XCTAssertTrue(predicate?(.int(3)) ?? false, "\(key): .int(3) should count as present")
            XCTAssertFalse(predicate?(.double(3.5)) ?? true, "\(key): fractional .double(3.5) must NOT count as present")
            XCTAssertFalse(predicate?(.string("3")) ?? true, "\(key): .string(\"3\") must NOT count as present")
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

    /// (B.1) — the exact unsafe pattern `optionalInt`/`optionalBool`/
    /// `optionalDouble` replace (`ident["key"]?.intValue` /
    /// `ident["key"]?.boolValue` / `ident["key"]?.doubleValue`, none of
    /// which can distinguish "wrong type" from "absent") must not exist
    /// anywhere in Sources/CheWordMCP any more. Catches a regression
    /// regardless of which tool or parameter name it lands on.
    ///
    /// #232 R6 (review "範圍外" item): added the `.doubleValue` regex
    /// alongside the pre-existing `.intValue`/`.boolValue` ones — this is
    /// the same unsafe shape that let `set_paragraph_format`'s
    /// `line_spacing` silently drop whole-valued input (see the
    /// `optionalDouble` unit tests above), just for the `number`-typed
    /// schema case instead of `integer`/`boolean`.
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
        let unsafeDouble = try NSRegularExpression(pattern: #"\b\w+\["[^"]+"\]\?\.doubleValue\b"#)
        var offenders: [String] = []
        for line in try Self.allSourceLines() {
            let range = NSRange(line.trimmed.startIndex..., in: line.trimmed)
            if unsafeInt.firstMatch(in: line.trimmed, range: range) != nil
                || unsafeBool.firstMatch(in: line.trimmed, range: range) != nil
                || unsafeDouble.firstMatch(in: line.trimmed, range: range) != nil {
                offenders.append("\(line.file):\(line.lineNumber)  \(line.trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "unsafe direct .intValue/.boolValue/.doubleValue subscript chain found:\n\(offenders.joined(separator: "\n"))")
    }

    /// (B.2) — every TOP-LEVEL `"type": "integer"` / `"type": "boolean"` /
    /// `"type": "number"` schema property (besides the documented
    /// exceptions) has a matching `optionalInt(..., "key")` /
    /// `optionalBool(..., "key")` / `optionalDouble(..., "key")` call site.
    /// This is what fails when a new integer/boolean/number parameter is
    /// added but never actually gets the strict-typing treatment. It caught
    /// two real, pre-existing bugs this way: `insert_sequence_field` read
    /// `reset_on_heading` while its schema declared `reset_level`, and
    /// `insert_checkbox` read `is_checked` while its schema declared
    /// `checked` — both fixed alongside this test (see (C) below for the
    /// end-to-end regression tests for each).
    ///
    /// #232 R6 (review "範圍外" item): added the `"number"`/`optionalDouble`
    /// leg. At the time of writing there is exactly one `"type": "number"`
    /// schema parameter in this file (`set_paragraph_format.line_spacing`),
    /// so this leg currently only re-confirms that one call site — but it
    /// means the NEXT number-typed parameter anyone adds is swept
    /// automatically instead of silently repeating the `line_spacing` bug
    /// (a `.doubleValue` read that drops whole-valued input).
    ///
    /// Known limitations, neither closed by this test (Codex R1/R3):
    ///  - `hasCall` matches a key name against EVERY `optionalInt`/
    ///    `optionalBool` call site in the file, not just the specific
    ///    tool's own handler — it does not parse the `switch` in
    ///    `executeToolTask` to scope the search per tool. In principle a
    ///    new tool that declares an integer/boolean parameter sharing a key
    ///    name already read by some unrelated tool (e.g. a hypothetical new
    ///    `"index"` parameter that is never actually read) could pass this
    ///    sweep. It did catch both real bugs above because neither
    ///    `reset_level` nor `checked` was read by any handler before the
    ///    fix — building a dispatch-table-aware, handler-scoped version
    ///    would close this gap but is a larger, separate undertaking.
    ///  - It only walks `schema["properties"]` one level deep. A newly
    ///    declared integer/boolean property nested inside an `"object"`- or
    ///    `"array"`-typed top-level property (like `insert_paragraph`'s
    ///    `into_table_cell.table_index`, which IS covered, but only by the
    ///    one representative runtime test in (C), not by this sweep) is
    ///    invisible to this test. It does not recurse.
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

        // No number exceptions today — line_spacing has a real optionalDouble
        // call site (see below), and there is no #201-style permanent stub,
        // pinned-message tool, or predating hand-rolled reader among
        // number-typed parameters yet. Kept as an empty set (rather than
        // omitting the mechanism) so a future exception has an obvious place
        // to be documented, matching intExceptions/boolExceptions above.
        let numberExceptions: Set<String> = []

        var missingInt: [String] = []
        var missingBool: [String] = []
        var missingNumber: [String] = []
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
                case "number":
                    if numberExceptions.contains(pairName) { continue }
                    if !hasCall("optionalDouble", key: key) { missingNumber.append(pairName) }
                default:
                    continue
                }
            }
        }
        XCTAssertTrue(missingInt.isEmpty, "integer schema params with no optionalInt(...) call site: \(missingInt.sorted())")
        XCTAssertTrue(missingBool.isEmpty, "boolean schema params with no optionalBool(...) call site: \(missingBool.sorted())")
        XCTAssertTrue(missingNumber.isEmpty, "number schema params with no optionalDouble(...) call site: \(missingNumber.sorted())")
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

    /// `list_comments` used to return early with a non-error "No comments in
    /// document" string before it ever reached `context_chars`/
    /// `include_context` (fixed in R1, see `testListCommentsRejectsStringContextCharsEvenWithNoComments`
    /// below — parsing now happens before that early return). This fixture
    /// helper is kept anyway for the two tests above: it exercises the
    /// non-empty-comments code path specifically (the branch that reads
    /// `comments` for real), which is a different code path worth covering
    /// in its own right, not a workaround for the now-fixed bypass.
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

    /// `set_paragraph_format`'s `line_spacing` is the file's one
    /// `"type": "number"` schema parameter — #232 R6's motivating bug for
    /// `optionalDouble`. A present-but-mistyped value must be rejected and
    /// named, same contract as an integer/boolean parameter.
    func testSetParagraphFormatRejectsStringLineSpacingNamingTheParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232r6-line-spacing-reject"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_paragraph_format",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "line_spacing": .string("2")]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("line_spacing"), resultText(result))
    }

    /// The exact `line_spacing` motivating bug, end to end: before the R6
    /// fix, `args["line_spacing"]?.doubleValue` only matched the `.double`
    /// JSON case, so a whole-valued `line_spacing` (JSON `2`, which decodes
    /// to `.int` on this platform) fell through to `nil` and the call
    /// silently applied NO spacing at all — not even a rejection, just a
    /// documented, correctly-typed, in-range value thrown away. Reads the
    /// applied `Spacing.line` back off the in-memory document (same
    /// "observe the actual document state" style as this file's
    /// `headerFlags` helper) rather than trusting the tool's own success
    /// string, since the pre-fix bug's whole point was that the call
    /// reported success while doing nothing.
    func testSetParagraphFormatAppliesWholeValuedIntLineSpacing() async throws {
        let server = await WordMCPServer()
        let id = "s232r6-line-spacing-apply"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_paragraph_format",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "line_spacing": .int(2)]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let doc = await server.openDocuments[id]
        let paragraphs = doc?.getParagraphs() ?? []
        XCTAssertFalse(paragraphs.isEmpty)
        // 2 (whole-valued) * 240 (1/240-point units) = 480 — see the
        // `Int(lineSpacing * 240)` conversion at the `set_paragraph_format`
        // call site.
        XCTAssertEqual(paragraphs.first?.properties.spacing?.line, 480)
    }

    // MARK: - R7 (`rev232b` review M2): `line_spacing` trap avoidance
    //
    // `set_paragraph_format`'s `line_spacing` used to feed straight into
    // `Int(lineSpacing * 240)` with no finiteness/range check. `Int(_:
    // Double)` TRAPS the whole process — SIGTRAP, not a catchable Swift
    // error — when the Double doesn't fit. Reproduced against the real
    // release/debug binary over stdio (not reachable through XCTest, since
    // a trap kills the test process too): `line_spacing:40000000000000000`
    // and `line_spacing:1e300` both crashed the server (`Fatal error:
    // Double value cannot be converted to Int because the result would be
    // greater than Int.max`, exit -5); `line_spacing:-1e300` crashed the
    // same way with "...less than Int.min". Confirmed fixed the same way,
    // post-fix: all three now return a normal `isError: true` response
    // instead of killing the process (see the R7 RED/GREEN section of the
    // report for the exact stdio transcripts). These tests exercise
    // `Self.twipsLine(fromLineSpacingMultiplier:)` — the validation
    // extracted from that call site — directly, since XCTest itself cannot
    // observe "the process didn't crash" as a pass/fail signal the way a
    // thrown Swift error can be asserted on.

    func testTwipsLineRejectsNonFiniteAndNonPositiveValues() {
        for bad: Double in [.nan, .infinity, -.infinity, 0, -1, -1e300] {
            do {
                _ = try WordMCPServer.twipsLine(fromLineSpacingMultiplier: bad)
                XCTFail("expected invalidParameter for \(bad)")
            } catch WordError.invalidParameter(let key, _) {
                XCTAssertEqual(key, "line_spacing")
            } catch {
                XCTFail("expected WordError.invalidParameter, got \(error)")
            }
        }
    }

    /// The two exact crash inputs from the independent review's stdio
    /// reproduction — both are finite, positive Doubles (so they pass the
    /// first guard), but overflow `Int32` once multiplied by 240.
    func testTwipsLineRejectsValuesThatWouldOverflowTheOOXMLTypedRange() {
        for bad: Double in [40_000_000_000_000_000, 1e300] {
            do {
                _ = try WordMCPServer.twipsLine(fromLineSpacingMultiplier: bad)
                XCTFail("expected invalidParameter for \(bad)")
            } catch WordError.invalidParameter(let key, let reason) {
                XCTAssertEqual(key, "line_spacing")
                // R8: message text corrected — no longer cites "Open XML
                // SDK 型別為 Int32Value" (found inaccurate; see `twipsLine`'s
                // doc comment), cites MS-OI29500 §17.18.81 instead.
                XCTAssertTrue(reason.contains("32 位元整數"), reason)
            } catch {
                XCTFail("expected WordError.invalidParameter, got \(error)")
            }
        }
    }

    /// Ordinary in-range values must still convert exactly as before —
    /// this fix must not narrow what a normal caller can express.
    func testTwipsLineAcceptsOrdinaryValues() throws {
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 1.0), 240)
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 1.5), 360)
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 2.0), 480)
        // The largest value that still fits Int32 once multiplied by 240,
        // and one twip past it — a boundary check, not just an interior one.
        let maxOk = Double(Int32.max) / 240
        XCTAssertNoThrow(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: maxOk))
        XCTAssertThrowsError(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: maxOk * 1.01))
    }

    /// R8 (`rev232b` review of #232 R7, LOW "1.15 寫出 275 而不是 276"):
    /// `Int(scaled)` truncated (round-toward-zero) instead of rounding.
    func testTwipsLineRoundsToNearestInsteadOfTruncating() throws {
        // `1.15 * 240` happens to land on EXACTLY `276.0` in IEEE 754 double
        // arithmetic (verified directly: `1.15 * 240 == 276.0`), so it does
        // NOT actually exercise the truncation-vs-rounding difference —
        // `2.05` does: `2.05 * 240 == 491.99999999999994` (representation
        // error from `2.05` itself not being exactly representable), so
        // truncating gives `491` while the mathematically correct value is
        // `492`. Verified end to end (real binary, `set_paragraph_format`
        // → `save_document` → read back `word/document.xml`'s `w:line`)
        // before this fix wrote `491`; confirmed via `1e5x1e5`-style sweep
        // of two-decimal multipliers that many other values share this
        // shape (`4.10`, `8.20`, `8.45`, …) — `2.05` is simply the first.
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 2.05), 492)
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 4.10), 984)
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 2.0), 480)
        XCTAssertEqual(try WordMCPServer.twipsLine(fromLineSpacingMultiplier: 1.5), 360)
    }

    /// #232 R7 (review LOW-4): `optionalDouble` itself must reject NaN and
    /// ±Infinity for ANY number-typed parameter, not just as a side effect
    /// of `line_spacing`'s own range check — bringing it to the same
    /// baseline `optionalInt` already documents ("never silently truncated
    /// or trapped"). JSON itself cannot encode either value, so this is only
    /// reachable in-process, exactly like the review's own probe found.
    func testOptionalDoubleRejectsNaNAndInfinity() async throws {
        let server = await WordMCPServer()
        for bad: Double in [.nan, .infinity, -.infinity] {
            do {
                _ = try await server.optionalDouble(["line_spacing": .double(bad)], "line_spacing")
                XCTFail("expected invalidParameter for \(bad)")
            } catch WordError.invalidParameter(let key, _) {
                XCTAssertEqual(key, "line_spacing")
            }
        }
    }

    /// End-to-end confirmation that the two exact review-reported crash
    /// inputs now fail cleanly through the full tool-call path (not just at
    /// the `twipsLine` unit level) — same call shape as the stdio
    /// reproduction, driven through `invokeToolForTesting` instead of raw
    /// JSON over a pipe.
    func testSetParagraphFormatRejectsLineSpacingValuesThatWouldTrap() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-line-spacing-trap"
        try await openFixtureDocument(server, id: id)
        for bad: Value in [.double(40_000_000_000_000_000), .double(1e300), .double(-1e300)] {
            let result = await server.invokeToolForTesting(
                name: "set_paragraph_format",
                arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "line_spacing": bad]
            )
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("line_spacing"), "\(bad): \(resultText(result))")
        }
    }

    // MARK: - R7 (`rev232b` review LOW-3): `bulk_resolve_comments.comment_ids`
    //
    // Element-level `value.intValue` only matched `.int` — the same
    // inconsistency R6 fixed for `anchorPresence` (`looksLikeIntAnchor`),
    // just for a batch array element instead of a single anchor parameter.
    // A whole-valued `.double` element (only reachable in-process — JSON
    // integers decode to `.int` on this platform) used to be rejected as
    // `invalid_id` even though it names a real comment. Per-item failures
    // now also carry the array `index`, since the old `"comment_id":null`
    // gave no way to tell which element in a multi-id call had failed.

    func testBulkResolveCommentsAcceptsWholeValuedDoubleId() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-bulk-resolve-whole-double"
        try await openFixtureDocument(server, id: id)
        try await insertFixtureComment(server, id: id)
        let doc = await server.openDocuments[id]
        guard let realId = doc?.comments.comments.first?.id else {
            XCTFail("fixture comment was not created")
            return
        }
        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string(id), "comment_ids": .array([.double(Double(realId))])]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("\"resolved\":1"), resultText(result))
        XCTAssertFalse(resultText(result).contains("invalid_id"), resultText(result))
    }

    func testBulkResolveCommentsReportsIndexOfInvalidId() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-bulk-resolve-index"
        try await openFixtureDocument(server, id: id)
        try await insertFixtureComment(server, id: id)
        let doc = await server.openDocuments[id]
        guard let realId = doc?.comments.comments.first?.id else {
            XCTFail("fixture comment was not created")
            return
        }
        let result = await server.invokeToolForTesting(
            name: "bulk_resolve_comments",
            arguments: ["doc_id": .string(id), "comment_ids": .array([
                .int(realId), .double(Double(realId) + 0.5), .string("x"),
            ])]
        )
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"resolved\":1"), text)
        XCTAssertTrue(text.contains("\"index\":1"), text)   // fractional double, position 1
        XCTAssertTrue(text.contains("\"index\":2"), text)   // string, position 2
    }

    // MARK: - R7 (`rev232b` review M3) + R8 (`rev232b` review M-R7-1):
    // `insert_floating_image` position is expressed as EITHER an EMU
    // offset OR an alignment keyword per axis. R7 modeled this as one
    // parameter accepting two JSON types (`horizontal_position`/
    // `vertical_position`, `"type": ["integer","string"]`); R8 split each
    // axis into an integer offset parameter and a separate string
    // alignment parameter (`horizontal_align`/`vertical_align`) instead,
    // since a `"type"` array is not portable OpenAPI 3.0 (see the R8 doc
    // comment on `insertFloatingImage` itself for the full reasoning).

    /// Extracts `word/document.xml` from a saved `.docx` and returns it as a
    /// string, for asserting on the literal `<wp:posOffset>`/`<wp:align>`
    /// elements the OOXML writer emits — the thing M3 is actually about
    /// (which XML element gets written), not just which Swift enum case a
    /// value lands in.
    private func savedDocumentXML(_ server: WordMCPServer, docId: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s232r7-floatimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("out.docx").path
        let save = await server.invokeToolForTesting(name: "save_document", arguments: ["doc_id": .string(docId), "path": .string(path)])
        XCTAssertNotEqual(save.isError, true, resultText(save))
        let unzipped = try ZipHelper.unzip(URL(fileURLWithPath: path))
        defer { ZipHelper.cleanup(unzipped) }
        return try String(contentsOf: unzipped.appendingPathComponent("word/document.xml"), encoding: .utf8)
    }

    private func insertFloatingImageFixture(_ server: WordMCPServer, id: String, extraArgs: [String: Value]) async -> CallTool.Result {
        var args: [String: Value] = [
            "doc_id": .string(id), "path": .string(R5FixtureFile.existingFilePath),
            "width": .int(100_000), "height": .int(100_000),
        ]
        for (k, v) in extraArgs { args[k] = v }
        return await server.invokeToolForTesting(name: "insert_floating_image", arguments: args)
    }

    /// R8: alignment keywords now go through the separate `horizontal_align`/
    /// `vertical_align` string parameters, not the integer `horizontal_position`/
    /// `vertical_position`. Still resolves to `<wp:align>`, not `<wp:posOffset>`.
    func testInsertFloatingImageAcceptsAlignmentKeywordsAndWritesWpAlign() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-floatimg-align"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let result = await insertFloatingImageFixture(server, id: id, extraArgs: [
            "horizontal_align": .string("center"), "vertical_align": .string("bottom"),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let xml = try await savedDocumentXML(server, docId: id)
        XCTAssertTrue(xml.contains("<wp:align>center</wp:align>"), xml)
        XCTAssertTrue(xml.contains("<wp:align>bottom</wp:align>"), xml)
        XCTAssertFalse(xml.contains("<wp:posOffset>"), xml)
    }

    /// R8: providing BOTH the offset and the alignment for the same axis is
    /// rejected as conflicting, not silently resolved by picking one.
    func testInsertFloatingImageRejectsBothOffsetAndAlignForSameAxis() async throws {
        let server = await WordMCPServer()
        let id = "s232r8-floatimg-conflict"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let horizontal = await insertFloatingImageFixture(server, id: id, extraArgs: [
            "horizontal_position": .int(457_200), "horizontal_align": .string("center"),
        ])
        XCTAssertEqual(horizontal.isError, true, resultText(horizontal))
        let vertical = await insertFloatingImageFixture(server, id: id, extraArgs: [
            "vertical_position": .int(457_200), "vertical_align": .string("bottom"),
        ])
        XCTAssertEqual(vertical.isError, true, resultText(vertical))
    }

    /// A JSON integer is still an EMU offset, written to `<wp:posOffset>`,
    /// exactly as before this fix — the string-keyword path is additive,
    /// not a replacement.
    func testInsertFloatingImageAcceptsIntegerOffsetAndWritesWpPosOffset() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-floatimg-offset"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let result = await insertFloatingImageFixture(server, id: id, extraArgs: [
            "horizontal_position": .int(457_200), "vertical_position": .int(914_400),
        ])
        XCTAssertNotEqual(result.isError, true, resultText(result))
        let xml = try await savedDocumentXML(server, docId: id)
        XCTAssertTrue(xml.contains("<wp:posOffset>457200</wp:posOffset>"), xml)
        XCTAssertTrue(xml.contains("<wp:posOffset>914400</wp:posOffset>"), xml)
        XCTAssertFalse(xml.contains("<wp:align>"), xml)
    }

    /// R8: unknown alignment keywords are rejected via `horizontal_align`
    /// now (the parameter that's actually meant to carry them).
    func testInsertFloatingImageRejectsUnknownAlignmentKeyword() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-floatimg-badkw"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let result = await insertFloatingImageFixture(server, id: id, extraArgs: ["horizontal_align": .string("middle")])
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("horizontal_align"), resultText(result))
    }

    /// R8: `horizontal_position` is a plain `optionalInt` again — a string
    /// there is now an ordinary #232-style type error, not an "unknown
    /// alignment keyword" (that's `horizontal_align`'s job).
    func testInsertFloatingImageRejectsStringOnTheIntegerPositionParameter() async throws {
        let server = await WordMCPServer()
        let id = "s232r8-floatimg-wrongparam"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let result = await insertFloatingImageFixture(server, id: id, extraArgs: ["horizontal_position": .string("center")])
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("horizontal_position"), resultText(result))
    }

    func testInsertFloatingImageRejectsBoolArrayAndObjectPosition() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-floatimg-badtype"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        for bad: Value in [.bool(true), .array([.int(1)]), .object([:])] {
            let result = await insertFloatingImageFixture(server, id: id, extraArgs: ["vertical_position": bad])
            XCTAssertEqual(result.isError, true, "\(bad): \(resultText(result))")
            XCTAssertTrue(resultText(result).contains("vertical_position"), "\(bad): \(resultText(result))")
        }
    }

    /// A whole-valued double offset is tolerated the same way `optionalInt`
    /// tolerates one elsewhere in this file; a fractional double is not a
    /// valid EMU offset (EMU is already an integer unit) and must be named.
    func testInsertFloatingImageAcceptsWholeValuedDoubleRejectsFractionalOffset() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-floatimg-doubleoffset"
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        let ok = await insertFloatingImageFixture(server, id: id, extraArgs: ["horizontal_position": .double(180_000)])
        XCTAssertNotEqual(ok.isError, true, resultText(ok))
        let bad = await insertFloatingImageFixture(server, id: id, extraArgs: ["horizontal_position": .double(180_000.5)])
        XCTAssertEqual(bad.isError, true, resultText(bad))
        XCTAssertTrue(resultText(bad).contains("horizontal_position"), resultText(bad))
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

    // MARK: - R4: remaining conditional / short-circuited reads

    /// `set_page_margins`'s custom top/right/bottom/left used to be parsed
    /// only in the `else` branch of the `preset` gate — a mistyped `top`
    /// supplied ALONGSIDE `preset` was silently never read.
    func testSetPageMarginsRejectsStringTopEvenWithPreset() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-page-margins"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_page_margins",
            arguments: ["doc_id": .string(id), "preset": .string("normal"), "top": .string("1000")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("top"), resultText(result))
    }

    /// `format_text`'s `run_index` used to be parsed only inside the
    /// `if asRevision` block — a mistyped `run_index` supplied without
    /// `as_revision:true` was silently never read.
    func testFormatTextRejectsStringRunIndexEvenWithoutAsRevision() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-format-text-run-index"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "format_text",
            arguments: ["doc_id": .string(id), "paragraph_index": .int(0), "run_index": .string("0")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("run_index"), resultText(result))
    }

    /// `accept_revision`'s `revision_id` used to be parsed only in the
    /// `else` branch of the `all` gate — a mistyped `revision_id` supplied
    /// alongside `all:true` was silently never read.
    func testAcceptRevisionRejectsStringRevisionIdEvenWithAllTrue() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-accept-revision"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "accept_revision",
            arguments: ["doc_id": .string(id), "all": .bool(true), "revision_id": .string("1")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("revision_id"), resultText(result))
    }

    /// Same shape as above, for `reject_revision`.
    func testRejectRevisionRejectsStringRevisionIdEvenWithAllTrue() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-reject-revision"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "reject_revision",
            arguments: ["doc_id": .string(id), "all": .bool(true), "revision_id": .string("1")]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("revision_id"), resultText(result))
    }

    /// `reply_to_comment`'s `comment_id ?? parent_comment_id` used to
    /// short-circuit on a non-nil `comment_id`, so a mistyped
    /// `parent_comment_id` supplied alongside a valid `comment_id` was
    /// silently never validated.
    func testReplyToCommentRejectsStringParentCommentIdEvenWithValidCommentId() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-reply-comment"
        try await openFixtureDocument(server, id: id)
        try await insertFixtureComment(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "reply_to_comment",
            arguments: [
                "doc_id": .string(id), "comment_id": .int(0), "parent_comment_id": .string("0"),
                "text": .string("reply"),
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("parent_comment_id"), resultText(result))
    }

    /// `merge_cells`'s `end_row`/`end_col` used to be parsed only inside
    /// their own `direction` switch case — a mistyped `end_row` supplied
    /// with `direction:"horizontal"` (which never reads `end_row`) was
    /// silently never validated.
    func testMergeCellsRejectsStringEndRowEvenWithHorizontalDirection() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-merge-cells"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "merge_cells",
            arguments: [
                "doc_id": .string(id), "table_index": .int(0), "direction": .string("horizontal"),
                "row": .int(0), "col": .int(0), "end_col": .int(1), "end_row": .string("1"),
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("end_row"), resultText(result))
    }

    /// `insert_paragraph`'s `into_table_cell.row` used to be unreachable
    /// (never evaluated, so never type-checked) when `table_index` in the
    /// same dict was absent — a chained `guard let a = ..., let b = ...`
    /// short-circuits on the first nil. Independent parsing means a
    /// wrong-typed `row` is now caught and named even though `table_index`
    /// is missing from the same dict.
    func testInsertParagraphNamesRowTypeErrorEvenWhenTableIndexIsAbsentFromIntoTableCell() async throws {
        let server = await WordMCPServer()
        let id = "s232r4-into-table-cell-precision"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string(id),
                "text": .string("cell text"),
                "into_table_cell": .object(["row": .string("0"), "col": .int(0)]),
            ]
        )
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(resultText(result).contains("row"), resultText(result))
    }

    /// #232 R6 (review LOW-2, `update_style`): `q_format`/`hidden`/
    /// `semi_hidden` are now parsed BEFORE `doc.updateStyle()` is called
    /// (not only afterward, inside the `firstIndex(where:)` gate). Before
    /// this fix, calling with a nonexistent `style_id` AND a mistyped
    /// `q_format` on the same call reported only "style not found" — the
    /// caller would fix the id, resubmit, and only then discover the
    /// (already-present) type error. This isn't a silent-success bug (the
    /// call was always going to fail), but the error now names the actual
    /// problem instead of masking it behind an unrelated one.
    func testUpdateStyleNamesQFormatTypeErrorEvenWhenStyleIdDoesNotExist() async throws {
        let server = await WordMCPServer()
        let id = "s232r6-update-style-precision"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "update_style",
            arguments: [
                "doc_id": .string(id), "style_id": .string("NoSuchStyle"),
                "q_format": .string("true"),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("q_format"), resultText(result))
    }

    /// #232 R6 (review LOW-2, `insert_caption`): `paragraph_index`/
    /// `after_table_index` are now parsed BEFORE the anchor-presence check
    /// below. `detectPresentAnchors` treats a wrong-typed anchor as simply
    /// "not present" (it has to — it also tolerates anchors the caller
    /// didn't intend to use), so a call whose ONLY anchor is a mistyped
    /// `paragraph_index` used to be preempted by the generic "at least one
    /// anchor required" refusal — again, not silent success (the call was
    /// always going to fail), but a confusing message when the caller DID
    /// supply an anchor, just with the wrong JSON type.
    func testInsertCaptionNamesParagraphIndexTypeErrorEvenAsTheOnlyAnchor() async throws {
        let server = await WordMCPServer()
        let id = "s232r6-insert-caption-precision"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: [
                "doc_id": .string(id), "label": .string("Figure"),
                "paragraph_index": .string("0"),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("paragraph_index"), resultText(result))
        XCTAssertFalse(resultText(result).contains("at least one anchor required"), resultText(result))
    }

    // MARK: - R7 (independent re-review `rev232b`, M1): regression coverage
    // for the 7 sites R6 actually fixed
    //
    // R6's own new tests (`optionalDouble` unit tests, `line_spacing`
    // end-to-end, the two message-precision tests above, `anchorPresence`)
    // never called any of the 7 sites R6's diff itself touched
    // (`create_numbering_definition.levels[].start`, the 5 early-return
    // tools' `summarize`, `checkpoint.allow_orphan_images`). R6's report
    // claimed these were "verified via the `gatedParameterProbes` table" —
    // that claim was wrong: no row in that table exercises any of these 7
    // sites. `rev232b`'s mutation test proved it by reverting all 7 to their
    // pre-R6 (`afe0b55`) shape and re-running the full suite: all 481
    // existing tests still passed. These 4 test functions close that gap.
    // They are standalone functions, NOT rows in `gatedParameterProbes`
    // below, because that table shares ONE fixture document per test run
    // (`openFixtureDocument`, which always has an "Anchor" paragraph + a
    // 2×2 table) — these 7 sites specifically need an EMPTY document (no
    // paragraphs/tables/footnotes/endnotes/formatted text) or a document
    // with a known on-disk source path, neither of which the shared fixture
    // can provide without changing what every other row in that table sees.

    /// `create_numbering_definition`'s `levels[].start` (R6 HIGH 1): an item
    /// missing the required `num_format`/`lvl_text` used to `continue` before
    /// `start` was ever parsed. Confirmed by mutation test: reverting this
    /// site to its pre-R6 shape leaves every existing test green.
    func testCreateNumberingDefinitionRejectsStringStartOnItemMissingRequiredFields() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-numdef-start"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "create_numbering_definition",
            arguments: [
                "doc_id": .string(id),
                "levels": .array([
                    .object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")]),
                    .object(["ilvl": .int(1), "start": .string("5")]),   // missing num_format/lvl_text
                ]),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(Self.namesParameter(resultText(result), "start"), resultText(result))
    }

    /// `get_paragraphs`/`get_tables`/`list_footnotes`/`list_endnotes`'
    /// `summarize` (R6 HIGH 2a): all four used to return their "no X in
    /// document" string before `summarize` was parsed, on a document with
    /// none of that content. Confirmed by mutation test.
    func testEarlyReturnToolsRejectStringSummarizeWithNoContent() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-early-return-empty"
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))

        for tool in ["get_paragraphs", "get_tables", "list_footnotes", "list_endnotes"] {
            let result = await server.invokeToolForTesting(
                name: tool, arguments: ["doc_id": .string(id), "summarize": .string("yes")]
            )
            XCTAssertEqual(result.isError, true, "\(tool): \(resultText(result))")
            XCTAssertTrue(Self.namesParameter(resultText(result), "summarize"), "\(tool): \(resultText(result))")
        }
    }

    /// `list_all_formatted_text`'s `summarize` (R6 HIGH 2a, fifth site): same
    /// shape as the four tools above, but its "no results" precondition is
    /// "document has content, none of it matches `format_type`" rather than
    /// "document is empty" — needs its own fixture. Confirmed by mutation test.
    func testListAllFormattedTextRejectsStringSummarizeWithNoMatches() async throws {
        let server = await WordMCPServer()
        let id = "s232r7-formatted-text-no-match"
        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string(id)])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let para = await server.invokeToolForTesting(
            name: "insert_paragraph", arguments: ["doc_id": .string(id), "text": .string("plain, unformatted")]
        )
        XCTAssertNotEqual(para.isError, true, resultText(para))

        let result = await server.invokeToolForTesting(
            name: "list_all_formatted_text",
            arguments: ["doc_id": .string(id), "format_type": .string("bold"), "summarize": .string("yes")]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(Self.namesParameter(resultText(result), "summarize"), resultText(result))
    }

    /// `checkpoint`'s `allow_orphan_images` (R6 HIGH 2b): the hand-written
    /// `allowOrphanImagesFlag` reader used to only be called inside the
    /// `explicitTarget` branch, so a call WITHOUT an explicit `path` (using
    /// the document's known on-disk source path instead) never read it at
    /// all. Needs a document with a real `documentOriginalPaths` entry —
    /// `create_document` alone doesn't set one, so this opens a saved file
    /// under a fresh `doc_id` first, mirroring how a real caller would reach
    /// the implicit-path branch. Confirmed by mutation test; also confirms
    /// the sidecar the old code silently used to write is NOT written once
    /// this errors out first.
    func testCheckpointRejectsStringAllowOrphanImagesWithImplicitPath() async throws {
        let server = await WordMCPServer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s232r7-checkpoint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.docx").path

        let create = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("s232r7-cp-src")])
        XCTAssertNotEqual(create.isError, true, resultText(create))
        let save = await server.invokeToolForTesting(
            name: "save_document", arguments: ["doc_id": .string("s232r7-cp-src"), "path": .string(path)]
        )
        XCTAssertNotEqual(save.isError, true, resultText(save))
        let reopen = await server.invokeToolForTesting(
            name: "open_document", arguments: ["doc_id": .string("s232r7-cp-open"), "path": .string(path)]
        )
        XCTAssertNotEqual(reopen.isError, true, resultText(reopen))

        let result = await server.invokeToolForTesting(
            name: "checkpoint",
            arguments: ["doc_id": .string("s232r7-cp-open"), "allow_orphan_images": .string("yes")]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(Self.namesParameter(resultText(result), "allow_orphan_images"), resultText(result))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".autosave.docx"), "sidecar must not be written when the call errors out first")
    }

    // MARK: - R5 (team lead directive): "一律驗證" — table-driven sweep
    //
    // Every integer/boolean parameter that appears in `args` must be
    // type-checked regardless of whether THIS call would end up using it.
    // R2/R4 fixed the first batch of conditional/gated reads found by
    // manual audit and each got its own named, hand-written test (still
    // present above — they document each site's specific shape in prose).
    // R5 closed the remaining sites found via a second, more systematic
    // sweep (chained multi-binding guards, `if`/`else`/`switch`-gated
    // blocks, sibling-field-gated array items) — instead of one more
    // hand-written test per site, this table exists so a FUTURE regression
    // on any of these specific gates is caught mechanically: add a row here
    // instead of a whole new test function next time.

    private struct GatedParameterProbe {
        let description: String
        let tool: String
        let args: [String: Value]
        let expectedNamedKey: String
    }

    private static let gatedParameterProbes: [GatedParameterProbe] = [
        GatedParameterProbe(
            description: "insert_paragraph.index gated by anchor-priority dispatch (a higher-priority anchor took the branch that never reads index)",
            tool: "insert_paragraph",
            args: ["text": .string("x"), "after_text": .string("Anchor"), "index": .string("0")],
            expectedNamedKey: "index"
        ),
        GatedParameterProbe(
            description: "insert_image_from_path.index gated the same way",
            tool: "insert_image_from_path",
            args: ["path": .string(R5FixtureFile.existingFilePath), "after_text": .string("Anchor"),
                   "width": .int(10), "height": .int(10), "index": .string("0")],
            expectedNamedKey: "index"
        ),
        GatedParameterProbe(
            description: "set_latent_styles item's ui_priority gated by that same item's missing 'name'",
            tool: "set_latent_styles",
            args: ["latent_styles": .array([.object(["ui_priority": .string("1")])])],
            expectedNamedKey: "ui_priority"
        ),
        GatedParameterProbe(
            description: "set_latent_styles item's semi_hidden gated by that same item's missing 'name'",
            tool: "set_latent_styles",
            args: ["latent_styles": .array([.object(["semi_hidden": .string("true")])])],
            expectedNamedKey: "semi_hidden"
        ),
        // #232 R6 (review LOW-3): set_latent_styles has four gated fields,
        // not two — R5 only added rows for ui_priority/semi_hidden. These
        // two close the gap for unhide_when_used/q_format, which are parsed
        // (and were fixed) at the exact same call site.
        GatedParameterProbe(
            description: "set_latent_styles item's unhide_when_used gated by that same item's missing 'name'",
            tool: "set_latent_styles",
            args: ["latent_styles": .array([.object(["unhide_when_used": .string("true")])])],
            expectedNamedKey: "unhide_when_used"
        ),
        GatedParameterProbe(
            description: "set_latent_styles item's q_format gated by that same item's missing 'name'",
            tool: "set_latent_styles",
            args: ["latent_styles": .array([.object(["q_format": .string("true")])])],
            expectedNamedKey: "q_format"
        ),
        GatedParameterProbe(
            description: "replace_text_batch item's regex gated by that same item's missing 'find'/'replace'",
            tool: "replace_text_batch",
            args: ["replacements": .array([.object(["regex": .string("no")])])],
            expectedNamedKey: "regex"
        ),
        GatedParameterProbe(
            description: "search_text_batch item's case_sensitive gated by that same item's missing 'query'",
            tool: "search_text_batch",
            args: ["queries": .array([.object(["case_sensitive": .string("no")])])],
            expectedNamedKey: "case_sensitive"
        ),
        // #232 R6 (review LOW-3): replace_text_batch reads TWO gated fields
        // (regex AND match_case) at that call site — R5 only added a row for
        // regex, leaving match_case itself unswept.
        GatedParameterProbe(
            description: "replace_text_batch item's match_case gated by that same item's missing 'find'/'replace'",
            tool: "replace_text_batch",
            args: ["replacements": .array([.object(["match_case": .string("no")])])],
            expectedNamedKey: "match_case"
        ),
    ]

    /// #232 R6 (review LOW-3): a plain `text.contains(probe.expectedNamedKey)`
    /// is too loose — for `expectedNamedKey == "index"` it would ALSO match
    /// inside an unrelated message like `insert_paragraph: received
    /// conflicting anchors: after_text + index`, which names an anchor list,
    /// not the parameter that failed to type-check. A sweep row using such a
    /// check could pass even after a regression silently reverted the fix
    /// (as long as SOME other message happens to contain the same substring).
    /// This mirrors the two literal shapes error text can actually take:
    /// - single-call tools route the throw through `WordError.errorDescription`
    ///   (`Invalid parameter 'key': reason`, via `invokeToolForTesting`'s
    ///   `error.localizedDescription` catch) — see `WordError.invalidParameter`.
    /// - the two batch tools catch the per-item error and interpolate the
    ///   raw `Error` value directly (`"\(error)"`, NOT `localizedDescription`),
    ///   which prints Swift's default enum-with-payload form:
    ///   `invalidParameter("key", "reason")`.
    /// Both forms name the key in a structurally distinct position (quoted,
    /// immediately adjacent to `Invalid parameter ` / `invalidParameter(`),
    /// so matching either pattern — but not a bare substring — is precise.
    private static func namesParameter(_ text: String, _ key: String) -> Bool {
        text.contains("Invalid parameter '\(key)'") || text.contains("invalidParameter(\"\(key)\"")
    }

    func testGatedParametersAreValidatedRegardlessOfWhetherTheCallWouldUseThem() async throws {
        let server = await WordMCPServer()
        let id = "s232r5-gated-sweep"
        try await openFixtureDocument(server, id: id)

        for probe in Self.gatedParameterProbes {
            var args = probe.args
            args["doc_id"] = .string(id)
            let result = await server.invokeToolForTesting(name: probe.tool, arguments: args)
            let text = resultText(result)
            // `replace_text_batch`/`search_text_batch` never set `isError`
            // for a per-item problem — they report the batch call itself as
            // successful and embed the per-item failure in the result text
            // (see the R1 per-item-isolation tests above and the control
            // test below) — accept either shape as "reported as a failure".
            let reportedAsFailure = result.isError == true || text.contains("FAIL")
            XCTAssertTrue(reportedAsFailure, "\(probe.description): \(text)")
            XCTAssertTrue(
                Self.namesParameter(text, probe.expectedNamedKey),
                "\(probe.description): expected error to name '\(probe.expectedNamedKey)', got: \(text)"
            )
        }
    }

    /// `replace_text_batch`/`search_text_batch` report per-item failures in
    /// the result STRING, not via `isError` (batch tools never set `isError`
    /// for a per-item problem — see the R1 per-item-isolation tests above),
    /// so the sweep's `result.isError == true || text.contains("FAIL")`
    /// fallback is the only failure signal available for their rows.
    ///
    /// #232 R6 (review LOW-4): this is a control, not a regression replay —
    /// it does NOT re-run the sweep rows against a reverted fix, so it
    /// cannot by itself prove those rows would catch a future regression
    /// (the original comment overclaimed that). What it DOES establish is
    /// narrower but still necessary: that `reportedAsFailure`'s two
    /// conditions are not vacuously true. If `isError` were somehow always
    /// unset for these tools, or if `text` always contained the substring
    /// "FAIL" regardless of outcome, every sweep row for `replace_text_batch`
    /// / `search_text_batch` would "pass" without the assertion having
    /// tested anything. Probing with the CORRECT type for every field the
    /// sweep rows above exercise (`regex`, `match_case`, `case_sensitive`)
    /// and asserting success text — not "FAIL" — rules that out.
    func testGatedParameterSweepRowsForBatchToolsActuallyDistinguishRightFromWrongType() async throws {
        let server = await WordMCPServer()
        let id = "s232r5-gated-sweep-batch-control"
        try await openFixtureDocument(server, id: id)

        let replaceResult = await server.invokeToolForTesting(
            name: "replace_text_batch",
            arguments: ["doc_id": .string(id), "replacements": .array([
                .object([
                    "find": .string("Anchor"), "replace": .string("Anchored"),
                    "regex": .bool(false), "match_case": .bool(true),
                ]),
            ])]
        )
        XCTAssertTrue(resultText(replaceResult).contains("1 applied, 0 failed"), resultText(replaceResult))

        let searchResult = await server.invokeToolForTesting(
            name: "search_text_batch",
            arguments: ["doc_id": .string(id), "queries": .array([
                .object(["query": .string("Anchored"), "case_sensitive": .bool(false)]),
            ])]
        )
        XCTAssertTrue(resultText(searchResult).contains("Found 1 match"), resultText(searchResult))
    }

    /// `set_latent_styles` has no per-item failure-reporting mechanism (unlike
    /// the two batch tools above) — a malformed item used to be silently
    /// `continue`-skipped and the call as a whole still reported success. The
    /// R5 fix means a malformed item now makes the WHOLE call fail, not just
    /// that one entry: this is a real behavior-mode change (documented in
    /// CHANGELOG.md).
    ///
    /// #232 R6 (review MEDIUM): the previous version of this comment
    /// described this as unlike "the other R5 fixes", implying
    /// `insert_paragraph`/`insert_image_from_path`'s `index` fix was merely
    /// a message-precision improvement — it is NOT. Before the fix, a call
    /// like `insert_paragraph(after_text: "Anchor", index: "0")` succeeded
    /// and actually inserted the paragraph (the mistyped `index` was simply
    /// never read, since `after_text` took priority); after the fix the same
    /// call fails outright. That is the identical "success → failure"
    /// severity class as this test pins for `set_latent_styles`, just
    /// without an array/per-item dimension to it (a single-call tool either
    /// succeeds or fails as a whole; there's no "reject the whole call vs.
    /// only the bad item" distinction to draw). Only `replace_text_batch`'s
    /// `regex`/`match_case` and `search_text_batch`'s `case_sensitive` are
    /// genuinely message-precision-only among the R5 fixes: that per-item
    /// call was already going to fail either way (missing `find`/`replace`
    /// or `query`), the fix only changes WHY it's reported as having failed.
    /// This test pins that specific consequence: one valid item plus one
    /// item with a mistyped `ui_priority` must reject the entire call, not
    /// silently apply only the valid one.
    func testSetLatentStylesRejectsTheWholeCallWhenAnyItemHasAMistypedField() async throws {
        let server = await WordMCPServer()
        let id = "s232r5-latent-styles-atomic"
        try await openFixtureDocument(server, id: id)
        let result = await server.invokeToolForTesting(
            name: "set_latent_styles",
            arguments: [
                "doc_id": .string(id),
                "latent_styles": .array([
                    .object(["name": .string("Heading1"), "ui_priority": .int(1)]),
                    .object(["ui_priority": .string("bad")]),   // missing name AND mistyped ui_priority
                ]),
            ]
        )
        XCTAssertEqual(result.isError, true, resultText(result))
        XCTAssertTrue(resultText(result).contains("ui_priority"), resultText(result))
    }
}

/// A file that exists on disk with arbitrary bytes — `insert_image_from_path`
/// checks existence before this test's `index` probe is ever reached, but
/// with explicit `width`/`height` never actually decodes it as an image
/// (`resolveImageDimensions` short-circuits), so its content doesn't matter.
private enum R5FixtureFile {
    private static var createdURL: URL?

    static let existingFilePath: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s232r5-fixture-\(UUID().uuidString).bin")
        try? Data("not actually an image".utf8).write(to: url)
        createdURL = url
        return url.path
    }()

    /// #232 R6 (review LOW-6): called from the test class's `class func
    /// tearDown()` once all tests in the class have run. `createdURL` is nil
    /// until `existingFilePath` has actually been accessed at least once, so
    /// this is a no-op (not an error) for any test target configuration that
    /// filters out every test touching the fixture.
    static func cleanUp() {
        guard let url = createdURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
