import XCTest
import MCP
@testable import CheWordMCP

/// #214 — the sibling of #202's sweep, for a DIFFERENT string shape.
///
/// #202 (and `RefusalIsErrorSweepTests`) caught refusals spelled
/// `return "Error: …"`. This file catches a shape #202 never looked for:
/// a JSON-object LITERAL — `return "{ \"error\": … }"` — built and returned
/// before the enclosing handler ever calls `storeDocument`. The document was
/// never touched, but nothing was thrown, so `isError` was never set: a
/// client branching only on `isError` reads the refusal as success, same
/// defect class as #202, different syntax.
///
/// DA classified all 37 grep hits into two closed groups (issue #214 body):
///
///  - **5 read-side query misses** — a lookup came up empty; that is a
///    RESULT, not a refusal, and correctly stays a returned string.
///  - **32 write-side refusals** — a mutation guard fired before
///    `storeDocument`; these are now thrown as `StructuredRefusal`
///    (`Server.swift`), which rides the #182 `StructuredToolFailure`
///    mechanism: `isError: true`, body byte-for-byte unchanged.
///
/// This is a closed enumeration (`common-spec-prose-enumeration.md`), not a
/// judgment call: the whitelist below names every function allowed to still
/// `return` this shape. Anything else matching the pattern is an offender —
/// a future contributor must either throw it (join the 32) or add it to the
/// whitelist with a comment justifying why it is a 6th read-side case.
final class StructuredJSONRefusalSweepTests: XCTestCase {

    // MARK: - (A) source sweep

    /// The only functions allowed to `return` a `{ "error": … }` JSON
    /// literal — each is a lookup that legitimately reports "no match" as a
    /// normal (non-error) result. Closed list, not a heuristic: any other
    /// function hitting the pattern below is a defect (write-side refusal
    /// still masquerading as success), not a 6th member of this list.
    ///
    /// "walkBody" stands in for `getContentControl`'s two query-miss sites
    /// (not_found / multiple_matches): both `return`s are lexically inside a
    /// NESTED `func walkBody(...)` local to `getContentControl`, and the
    /// nearest-preceding-`func` scan below (matching the technique
    /// `RefusalIsErrorSweepTests` uses) finds that inner declaration, not the
    /// outer one. A second, unrelated `walkBody` nested in `listContentControls`
    /// contains no JSON-literal return, so this does not admit a stray site.
    private static let allowedReadSideFunctions: Set<String> = [
        "walkBody",                   // content-control queries ×2 (not_found / multiple_matches), nested in getContentControl
        "listRepeatingSectionItems",
        "getStyleInheritanceChain",
        "getNumberingDefinition",
    ]

    private static var sourcesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheWordMCP", isDirectory: true)
    }

    private struct Offender: CustomStringConvertible {
        let file: String; let line: Int; let enclosingFunction: String; let text: String
        var description: String {
            "\(file):\(line)  in \(enclosingFunction)()  \(text.trimmingCharacters(in: .whitespaces).prefix(90))"
        }
    }

    private static let funcDeclRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:private |internal |)func\s+([A-Za-z0-9_]+)\s*\("#)

    private static func enclosingFunctionName(for lines: [String], at index: Int) -> String {
        var name = "<top level>"
        for i in stride(from: index, through: 0, by: -1) {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)
            if let m = funcDeclRegex.firstMatch(in: line, range: range),
               let r = Range(m.range(at: 1), in: line) {
                name = String(line[r])
                break
            }
        }
        return name
    }

    /// Lists every `return "{ \"error\": …` JSON-literal refusal site whose
    /// enclosing function is NOT in the read-side whitelist.
    private static func jsonLiteralRefusalOffenders() throws -> [Offender] {
        let fm = FileManager.default
        var files: [URL] = []
        if let walker = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertFalse(files.isEmpty, "sweep found no Swift sources under \(sourcesDir.path)")
        var offenders: [Offender] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("return \"{ \\\"error\\\":") else { continue }
                let fn = enclosingFunctionName(for: lines, at: i)
                if !allowedReadSideFunctions.contains(fn) {
                    offenders.append(Offender(file: url.lastPathComponent, line: i + 1, enclosingFunction: fn, text: line))
                }
            }
        }
        return offenders
    }

    func testNoWriteSideJSONLiteralRefusalIsStillReturned() throws {
        let offenders = try Self.jsonLiteralRefusalOffenders()
        XCTAssertEqual(offenders.count, 0,
                       "\(offenders.count) JSON-literal refusal site(s) fail the sweep — a write-side handler "
                       + "`return`ed a `{ \"error\": … }` body instead of throwing `StructuredRefusal`, so `isError` "
                       + "is never set (#214). Either throw it (join the 32) or, if it is genuinely a read-side "
                       + "lookup miss, add its enclosing function to `allowedReadSideFunctions` with a comment:\n"
                       + offenders.map(\.description).joined(separator: "\n"))
    }

    /// The whitelist itself must still exist and still be exactly 4 read-side
    /// functions in the current source — catches the whitelist silently
    /// drifting out of sync (e.g. a read-side function renamed) as loudly as
    /// catches a new write-side offender.
    func testReadSideAllowlistFunctionsStillReturnJSONLiteral() throws {
        let fm = FileManager.default
        var files: [URL] = []
        if let walker = fm.enumerator(at: Self.sourcesDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        }
        var seen = Set<String>()
        for url in files {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("return \"{ \\\"error\\\":") else { continue }
                seen.insert(Self.enclosingFunctionName(for: lines, at: i))
            }
        }
        XCTAssertEqual(seen, Self.allowedReadSideFunctions,
                       "the set of functions still returning a JSON-literal refusal body drifted from the "
                       + "closed read-side whitelist. Got: \(seen.sorted()), expected: \(Self.allowedReadSideFunctions.sorted())")
    }

    // MARK: - (B) protocol-level cases

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    private func call(_ server: WordMCPServer, _ name: String, _ args: [String: Value]) async throws -> CallTool.Result {
        try await server.handleToolCall(CallTool.Parameters(name: name, arguments: args))
    }

    private func freshDoc(_ server: WordMCPServer, _ id: String = "d") async throws {
        _ = try await call(server, "create_document", ["doc_id": .string(id)])
        _ = try await call(server, "insert_paragraph", ["doc_id": .string(id), "text": .string("body")])
    }

    /// Body text is byte-for-byte what the old `return` produced — only
    /// `isError` flipped. One representative site per functional group
    /// (content-control / style / numbering / section / table), matching the
    /// groups DA classified.
    private func assertStructuredRefusal(_ r: CallTool.Result, _ label: String, expectedBody: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.isError, true, "\(label): a write-side refusal SHALL be isError: true. Got isError=\(String(describing: r.isError))", file: file, line: line)
        XCTAssertEqual(text(r), expectedBody, "\(label): body must be byte-for-byte unchanged — only isError flips (#214)", file: file, line: line)
    }

    func testUpdateContentControlTextRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "update_content_control_text", ["doc_id": .string("d"), "id": .int(999), "text": .string("x")])
        assertStructuredRefusal(r, "update_content_control_text (id not found)",
                                expectedBody: "{ \"error\": \"not_found\", \"id\": 999 }")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testLinkStylesRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "link_styles", ["doc_id": .string("d"), "paragraph_style_id": .string("NoSuchStyle"), "character_style_id": .string("Emphasis")])
        assertStructuredRefusal(r, "link_styles (paragraph style not found)",
                                expectedBody: "{ \"error\": \"not_found\", \"style_id\": \"NoSuchStyle\" }")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testAssignNumberingToParagraphRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "assign_numbering_to_paragraph",
                               ["doc_id": .string("d"), "paragraph_index": .int(0), "num_id": .int(999), "level": .int(0)])
        assertStructuredRefusal(r, "assign_numbering_to_paragraph (num_id not found)",
                                expectedBody: "{ \"error\": \"not_found\", \"num_id\": 999 }")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testSetLineNumbersForSectionRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "set_line_numbers_for_section",
                               ["doc_id": .string("d"), "section_index": .int(99), "count_by": .int(1)])
        assertStructuredRefusal(r, "set_line_numbers_for_section (section_index out of bounds)",
                                expectedBody: "{ \"error\": \"out_of_bounds\", \"section_index\": 99 }")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testSetTableIndentRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "set_table_indent",
                               ["doc_id": .string("d"), "table_index": .int(99), "value": .int(720)])
        assertStructuredRefusal(r, "set_table_indent (table_index out of bounds)",
                                expectedBody: "{ \"error\": \"out_of_bounds\", \"table_index\": 99 }")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    /// Positive control mirroring `RefusalIsErrorSweepTests`: a genuine
    /// read-side query miss must NOT be flagged — the fix targets write-side
    /// refusals only, not every JSON body that happens to contain "error".
    func testGetContentControlNotFoundStaysSuccess() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "get_content_control", ["doc_id": .string("d"), "id": .int(999)])
        XCTAssertNotEqual(r.isError, true, "a query miss is a RESULT, not a refusal — must stay isError-unset: \(text(r).prefix(120))")
        XCTAssertTrue(text(r).contains("\"error\": \"not_found\""))
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }
}
