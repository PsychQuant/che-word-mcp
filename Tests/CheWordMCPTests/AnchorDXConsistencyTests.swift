import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Spectra change `anchor-dx-consistency` (Bundle B → v3.16.0).
/// PsychQuant/che-word-mcp #71 + #72 + #70.
///
/// Spec: openspec/changes/anchor-dx-consistency/specs/che-word-mcp-insertion-tools/spec.md
/// (3 ADDED Requirements; this file pins each Scenario as XCTest sub-tests.)
final class AnchorDXConsistencyTests: XCTestCase {

    // MARK: - Phase 1: detectPresentAnchors helper unit tests
    // Smallest unit: helper directly. Integration tests follow as Phase 1.2-1.5
    // each wires the helper into one of the 4 #61-target tools.

    func testDetectPresentAnchorsReturnsEmptyWhenAllOmitted() {
        let args: [String: Value] = ["doc_id": .string("d"), "text": .string("x")]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, [] as [String])
    }

    func testDetectPresentAnchorsReturnsSingleWhenOneSet() {
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "text": .string("x"),
            "after_text": .string("foo")
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text"])
    }

    func testDetectPresentAnchorsReturnsAllSortedWhenMultipleSet() {
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "text": .string("x"),
            "after_text": .string("foo"),
            "index": .int(3)
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text", "index"])
    }

    func testDetectPresentAnchorsReturnsAllSortedWhenThreeSet() {
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "path": .string("/tmp/x.png"),
            "into_table_cell": .object(["table_index": .int(0), "row": .int(0), "col": .int(0)]),
            "after_text": .string("bar"),
            "before_text": .string("baz")
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text", "before_text", "into_table_cell"])
    }

    /// Sharp-edge: JSON `null`-typed args MUST NOT count as present.
    /// Audit (Confused Developer lens): LLM emitting `{"index": null}` should not
    /// trigger conflict; should be treated as if param were omitted.
    func testDetectPresentAnchorsTreatsNullValuesAsOmitted() {
        // MCP SDK Value uses .null for JSON null; .string(nil) isn't a thing.
        // We construct a dict that has the key but value is .null typed.
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "text": .string("x"),
            "after_text": .null,
            "index": .int(3)
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["index"], "null-typed after_text must NOT count as present")
    }

    /// Sharp-edge: wrong-type values MUST NOT count as present.
    /// Audit (Scoundrel lens): if attacker passes `{"index": "not-a-number"}` the helper
    /// must not treat it as present (would be confusing — dispatcher would also reject
    /// at .intValue extraction, so being uniform here is correct).
    func testDetectPresentAnchorsTreatsWrongTypesAsOmitted() {
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "text": .string("x"),
            "index": .string("not-a-number"),  // wrong type
            "after_text": .string("foo")
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text"], "wrong-type index must NOT count as present")
    }

    /// Modifier params (text_instance, position, style) MUST NOT count as anchors.
    /// Spec: "Modifier parameters ... are NOT anchors and do NOT count toward conflict detection."
    func testDetectPresentAnchorsIgnoresModifiers() {
        let args: [String: Value] = [
            "doc_id": .string("d"),
            "text": .string("x"),
            "after_text": .string("foo"),
            "text_instance": .int(2),
            "style": .string("Heading1")
        ]
        // Caller passes only anchor names in `anchors` — modifiers aren't included.
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text"])
    }

    /// Empty anchors whitelist returns empty regardless of args.
    func testDetectPresentAnchorsEmptyWhitelistReturnsEmpty() {
        let args: [String: Value] = [
            "after_text": .string("foo"),
            "index": .int(3)
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [])
        XCTAssertEqual(present, [] as [String])
    }

    /// Args present but key missing from whitelist → not counted (e.g., `paragraph_index` in
    /// insertParagraph's whitelist isn't there because that tool uses `index` instead).
    func testDetectPresentAnchorsRespectsWhitelist() {
        let args: [String: Value] = [
            "after_text": .string("foo"),
            "paragraph_index": .int(3)  // present but not in whitelist
        ]
        let present = WordMCPServer.detectPresentAnchors(args, anchors: [
            "into_table_cell", "after_image_id", "after_text", "before_text", "index"
        ])
        XCTAssertEqual(present, ["after_text"], "paragraph_index not in whitelist must be ignored")
    }

    // MARK: - Phase 1.2: insertParagraph conflict detection
    // Spec R1 Scenarios — pinned via real MCP dispatcher.

    /// Spec R1 Scenario "Two anchors → conflict error".
    func testInsertParagraphRejectsAfterTextPlusIndexConflict() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ip2")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p71ip2"),
                "text": .string("x"),
                "after_text": .string("foo"),
                "index": .int(3)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_paragraph: received conflicting anchors: after_text + index"),
            "expected conflict error, got: \(msg)"
        )
        XCTAssertTrue(msg.contains("Specify exactly one"), "expected guidance, got: \(msg)")
    }

    /// Spec R1 Scenario "One anchor → unchanged behavior".
    func testInsertParagraphSingleAnchorStillWorks() async throws {
        let url = try docxWithText(text: "foo")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ips")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p71ips"),
                "text": .string("inserted"),
                "after_text": .string("foo")
            ]
        )
        let msg = textOf(r)
        XCTAssertFalse(msg.hasPrefix("Error"), "single-anchor path should succeed, got: \(msg)")
        XCTAssertTrue(msg.contains("after text 'foo'"), "expected success message, got: \(msg)")
    }

    /// Spec R1 Scenario "Modifier params do NOT count" — text_instance + style alongside one anchor.
    func testInsertParagraphModifiersDoNotCountAsAnchors() async throws {
        let url = try docxWithRepeatedText(text: "foo", count: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ipm")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p71ipm"),
                "text": .string("inserted"),
                "after_text": .string("foo"),
                "text_instance": .int(2),  // modifier — not an anchor
                "style": .string("Heading1")  // modifier — not an anchor
            ]
        )
        let msg = textOf(r)
        XCTAssertFalse(msg.contains("conflicting anchors"), "text_instance/style must not trigger conflict, got: \(msg)")
        XCTAssertTrue(msg.contains("instance 2"), "expected text_instance=2 honored, got: \(msg)")
    }

    // MARK: - Phase 1.3: insertEquation display-mode conflict detection

    func testInsertEquationDisplayRejectsAfterTextPlusParagraphIndex() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ie2")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("p71ie2"),
                "latex": .string("x"),
                "display_mode": .bool(true),
                "after_text": .string("foo"),
                "paragraph_index": .int(0)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_equation: received conflicting anchors: after_text + paragraph_index"),
            "expected conflict error, got: \(msg)"
        )
    }

    func testInsertEquationInlineModePreservesExistingRejection() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71iei")]
        )

        // Inline mode + after_text → existing v3.15.1 rejection (NOT new conflict path).
        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("p71iei"),
                "latex": .string("x"),
                "display_mode": .bool(false),
                "after_text": .string("foo")
            ]
        )
        let msg = textOf(r)
        // Existing rejection path — should NOT contain the new "conflicting anchors" wording.
        XCTAssertFalse(msg.contains("conflicting anchors"), "inline rejection should be unchanged, got: \(msg)")
        XCTAssertTrue(msg.contains("anchor parameters") && msg.contains("display_mode=true"),
                      "expected v3.15.1 inline rejection, got: \(msg)")
    }

    // MARK: - Phase 1.4: insertImageFromPath conflict detection

    /// Spec R1 Scenario "Three anchors → all listed in error".
    func testInsertImageFromPathRejectsThreeAnchorsConflict() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ii3")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("p71ii3"),
                "path": .string(png.path),
                "into_table_cell": .object([
                    "table_index": .int(0), "row": .int(0), "col": .int(0)
                ]),
                "after_text": .string("bar"),
                "before_text": .string("baz")
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_image_from_path: received conflicting anchors: after_text + before_text + into_table_cell"),
            "expected 3-anchor conflict error sorted alphabetically, got: \(msg)"
        )
    }

    // MARK: - Phase 1.5: insertCaption conflict detection (caption-specific anchor set)

    /// Spec R1 Scenario for insert_caption: 2 anchors → conflict error in the unified format.
    /// (Replaces the v3.15.x "exactly one of … must be provided (got N)" message with the
    /// uniform "received conflicting anchors" format used by the other 3 #61-target tools.)
    func testInsertCaptionRejectsParagraphIndexPlusAfterTextConflict() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ic2")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: [
                "doc_id": .string("p71ic2"),
                "label": .string("Figure"),
                "caption_text": .string("Test"),
                "paragraph_index": .int(0),
                "after_text": .string("foo")
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_caption: received conflicting anchors: after_text + paragraph_index"),
            "expected uniform conflict error, got: \(msg)"
        )
    }

    /// insert_caption-specific: 0 anchors → still rejected (tool has no append default).
    /// Format is updated to the uniform tool-prefix style.
    func testInsertCaptionRejectsZeroAnchors() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ic0")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: [
                "doc_id": .string("p71ic0"),
                "label": .string("Figure"),
                "caption_text": .string("Test")
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(msg.hasPrefix("Error: insert_caption:"), "expected tool-prefixed error, got: \(msg)")
        XCTAssertTrue(msg.contains("anchor") || msg.contains("paragraph_index"),
                      "expected anchor guidance, got: \(msg)")
    }

    /// Spec R1 Scenario "Zero anchors → append fallback".
    func testInsertParagraphZeroAnchorsAppends() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p71ipz")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("p71ipz"), "text": .string("appended")]
        )
        let msg = textOf(r)
        XCTAssertFalse(msg.hasPrefix("Error"), "zero-anchor path should append, got: \(msg)")
        XCTAssertTrue(msg.contains("at index"), "expected index report, got: \(msg)")
    }

    // MARK: - Phase 2: text_instance validation
    // Spec R2 — text_instance MUST be ≥ 1 when explicitly specified.

    /// Spec R2 Scenario "text_instance: 0 rejected" for insert_paragraph.
    func testInsertParagraphRejectsZeroTextInstance() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72ip0")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p72ip0"),
                "text": .string("x"),
                "after_text": .string("foo"),
                "text_instance": .int(0)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_paragraph: text_instance must be ≥ 1, got 0"),
            "expected text_instance validation error, got: \(msg)"
        )
    }

    /// Spec R2 Scenario "text_instance: -3 rejected" for insert_paragraph.
    func testInsertParagraphRejectsNegativeTextInstance() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72ipn")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p72ipn"),
                "text": .string("x"),
                "after_text": .string("foo"),
                "text_instance": .int(-3)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_paragraph: text_instance must be ≥ 1, got -3"),
            "expected text_instance validation error, got: \(msg)"
        )
    }

    /// Spec R2 Scenario "text_instance omitted → defaults to 1" for insert_paragraph.
    func testInsertParagraphTextInstanceOmittedUsesDefault() async throws {
        let url = try docxWithText(text: "foo")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72ipd")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: [
                "doc_id": .string("p72ipd"),
                "text": .string("inserted"),
                "after_text": .string("foo")
            ]
        )
        let msg = textOf(r)
        XCTAssertFalse(msg.contains("text_instance"), "default path should not surface text_instance, got: \(msg)")
        XCTAssertTrue(msg.contains("after text 'foo'"), "expected success, got: \(msg)")
    }

    func testInsertEquationRejectsZeroTextInstance() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72ie0")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_equation",
            arguments: [
                "doc_id": .string("p72ie0"),
                "latex": .string("x"),
                "display_mode": .bool(true),
                "after_text": .string("foo"),
                "text_instance": .int(0)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_equation: text_instance must be ≥ 1, got 0"),
            "expected validation error, got: \(msg)"
        )
    }

    func testInsertImageFromPathRejectsZeroTextInstance() async throws {
        let url = try emptyDocxURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let png = try writeOnePixelPNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72ii0")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_image_from_path",
            arguments: [
                "doc_id": .string("p72ii0"),
                "path": .string(png.path),
                "after_text": .string("foo"),
                "text_instance": .int(0)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_image_from_path: text_instance must be ≥ 1, got 0"),
            "expected validation error, got: \(msg)"
        )
    }

    func testInsertCaptionRejectsNegativeTextInstance() async throws {
        let url = try docxWithText(text: "foo")
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer()

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(url.path), "doc_id": .string("p72icn")]
        )

        let r = await server.invokeToolForTesting(
            name: "insert_caption",
            arguments: [
                "doc_id": .string("p72icn"),
                "label": .string("Figure"),
                "caption_text": .string("Test"),
                "after_text": .string("foo"),
                "text_instance": .int(-1)
            ]
        )
        let msg = textOf(r)
        XCTAssertTrue(
            msg.contains("Error: insert_caption: text_instance must be ≥ 1, got -1"),
            "expected validation error, got: \(msg)"
        )
    }

    // MARK: - Phase 4.5: tool-prefix regression pin (grep on Server.swift source)
    // Spec R3 — all `return "Error: ..."` lines in 4 #61-target tools must be
    // tool-prefixed. Scoped to 4 target tools per design §3 *Phasing*; global
    // sweep is the separate `error-prefix-sweep` change's concern.

    func testFourTargetToolsHaveNoUnprefixedErrorReturns() throws {
        // Locate Server.swift via SOURCES env (set by Xcode/swift test) or relative path.
        let serverPath: URL = {
            if let src = ProcessInfo.processInfo.environment["SOURCE_ROOT"] {
                return URL(fileURLWithPath: src).appendingPathComponent("Sources/CheWordMCP/Server.swift")
            }
            // Fall back: walk up from test file location until we find Sources/.
            var url = URL(fileURLWithPath: #filePath)
            while url.pathComponents.count > 1 {
                url = url.deletingLastPathComponent()
                let candidate = url.appendingPathComponent("Sources/CheWordMCP/Server.swift")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return URL(fileURLWithPath: "/dev/null")
        }()

        let source = try String(contentsOf: serverPath)
        let lines = source.components(separatedBy: "\n")

        let targets: Set<String> = ["insertParagraph", "insertEquation", "insertImageFromPath", "insertCaption"]
        var inTargetFunc = false
        var currentTool: String? = nil

        // Map func name → tool name for the prefix check.
        let funcToTool: [String: String] = [
            "insertParagraph": "insert_paragraph",
            "insertEquation": "insert_equation",
            "insertImageFromPath": "insert_image_from_path",
            "insertCaption": "insert_caption",
        ]

        var unprefixed: [(line: Int, content: String, tool: String)] = []

        for (idx, line) in lines.enumerated() {
            // Detect entry into / exit from target functions.
            // Pattern: `    private func <name>(args:`
            if let match = line.range(of: #"^    private func (\w+)\(args"#, options: .regularExpression) {
                let funcName = String(line[match]).replacingOccurrences(of: "    private func ", with: "")
                                                 .replacingOccurrences(of: "(args", with: "")
                if targets.contains(funcName) {
                    inTargetFunc = true
                    currentTool = funcToTool[funcName]
                } else {
                    inTargetFunc = false
                    currentTool = nil
                }
                continue
            }
            guard inTargetFunc, let tool = currentTool else { continue }

            // Look for `return "Error: ...` that does NOT start with `Error: <tool>:`.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(#"return "Error:"#) else { continue }
            let expectedPrefix = #"return "Error: \#(tool):"#
            if !trimmed.hasPrefix(expectedPrefix) {
                unprefixed.append((line: idx + 1, content: trimmed, tool: tool))
            }
        }

        XCTAssertEqual(
            unprefixed.count, 0,
            "Found \(unprefixed.count) unprefixed `return \"Error: ...\"` lines in 4 #61-target tools "
            + "(Spec R3, Phase 3 sweep). Each must be `Error: <tool>: <body>`. Lines:\n"
            + unprefixed.map { "  Server.swift:\($0.line) [\($0.tool)] \($0.content)" }.joined(separator: "\n")
        )
    }

    // MARK: - Test helpers

    private func textOf(_ r: CallTool.Result) -> String {
        guard let content = r.content.first else { return "" }
        if case .text(let t) = content { return t.text }
        return ""
    }

    private func emptyDocxURL() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "seed")])))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-dx-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func docxWithText(text: String) throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-dx-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func docxWithRepeatedText(text: String, count: Int) throws -> URL {
        var doc = WordDocument()
        for _ in 0..<count {
            doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: text)])))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anchor-dx-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// Minimal 1x1 PNG (8-byte signature + IHDR + IDAT + IEND).
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
            .appendingPathComponent("anchor-dx-\(UUID().uuidString).png")
        try Data(png).write(to: url)
        return url
    }
}
