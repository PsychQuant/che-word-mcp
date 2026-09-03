import XCTest
import MCP
@testable import CheWordMCP

/// #202 — a refusal returned as a plain string is a success on the wire.
///
/// `handleToolCall` sets `isError: true` only when a handler throws. Handlers
/// that refuse by `return "Error: …"` (and the multi-line `"""` gates such as
/// `E_DIRTY_DOC` and `E_IMAGE_CONSISTENCY`) come back as ordinary results, so a
/// client that branches on `isError` reads "refused to save" as "saved". The
/// convention this file pins: a refusal is thrown (`ToolRefusal`), the catch in
/// `handleToolCall` restores the `Error: ` prefix, and the client-visible text
/// does not change — only `isError` does.
///
/// Two layers, because each catches what the other cannot:
///  (A) a source-level sweep — no `return "Error:` and no return-position
///      multi-line literal opening with `Error:` may exist in Sources/; this is
///      what stops the next contributor from re-introducing the pattern.
///  (B) protocol-level cases through `handleToolCall` directly — representative
///      refusals must carry `isError == true` while their text still starts
///      with `Error: ` (the wording contract older tests rely on).
final class RefusalIsErrorSweepTests: XCTestCase {

    // MARK: - (A) source sweep

    private static var sourcesDir: URL {
        // Tests/CheWordMCPTests/<this file> → ../../Sources/CheWordMCP
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheWordMCP", isDirectory: true)
    }

    private struct Offender: CustomStringConvertible {
        let file: String; let line: Int; let text: String
        var description: String { "\(file):\(line)  \(text.trimmingCharacters(in: .whitespaces).prefix(90))" }
    }

    /// Lists every refusal still expressed as a returned string.
    private static func stringRefusalSites() throws -> [Offender] {
        let fm = FileManager.default
        // Recursive: a future `Sources/CheWordMCP/Handlers/` split must not fall out of the lock
        // (verify R1, logic LOW-1 / requirements F3).
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
                // rule 1 — single-line: return "Error: …"
                if line.hasPrefix("return \"Error:") {
                    offenders.append(Offender(file: url.lastPathComponent, line: i + 1, text: line))
                    continue
                }
                // rule 3 — double prefix: a thrown literal must not carry the `Error: ` the catch adds
                // (verify R1, logic LOW-2).
                if line.hasPrefix("throw ToolRefusal(\"Error:") {
                    offenders.append(Offender(file: url.lastPathComponent, line: i + 1, text: line))
                    continue
                }
                // rule 4 — the indirect shape this PR had to fix by hand: a helper builds the refusal
                // text and the caller RETURNS it. Verify R1's DA reverted three such throws to returns
                // and the whole suite stayed green (mutations M1–M3); this rule is the lock for that
                // shape. The list names the known refusal builders; extend it when adding one.
                if line == "return refusal" || line.hasPrefix("return refusal ")
                    || line.hasPrefix("return formatSpliceError(") {
                    offenders.append(Offender(file: url.lastPathComponent, line: i + 1, text: line))
                    continue
                }
                // multi-line: any """ literal whose first content line opens with Error:
                // (return-position or helper body — both reach the client as a string)
                if line.hasSuffix("\"\"\"") && !line.hasPrefix("\"\"\"") || line == "\"\"\"" && i > 0 && !lines[i - 1].trimmingCharacters(in: .whitespaces).hasSuffix("\"\"\"") {
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("Error:") {
                        // Returned or built as a String → isError never set. Thrown → the catch adds a
                        // second `Error: ` (rule 3). Either way an offender (verify R1, logic LOW-2).
                        offenders.append(Offender(file: url.lastPathComponent, line: j + 1, text: lines[j]))
                    }
                }
            }
        }
        return offenders
    }

    func testNoRefusalIsStillReturnedAsAString() throws {
        let offenders = try Self.stringRefusalSites()
        XCTAssertEqual(offenders.count, 0,
                       "\(offenders.count) refusal site(s) fail the sweep — rules 1/2: a returned `Error:` literal (isError never set); "
                       + "rule 3: a thrown literal already starting with `Error:` (client would see `Error: Error:`); "
                       + "rule 4: helper-built refusal text returned instead of thrown:\n"
                       + offenders.prefix(30).map(\.description).joined(separator: "\n")
                       + (offenders.count > 30 ? "\n… (+\(offenders.count - 30) more)" : ""))
    }

    // MARK: - (B) protocol cases

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    /// Calls the real dispatch entry, not the test seam (`invokeToolForTesting`
    /// carries its own catch and cannot tell the two channels apart — #201 D4).
    private func call(_ server: WordMCPServer, _ name: String, _ args: [String: Value]) async throws -> CallTool.Result {
        try await server.handleToolCall(CallTool.Parameters(name: name, arguments: args))
    }

    private func assertRefused(_ r: CallTool.Result, _ label: String, expecting needle: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let t = text(r)
        XCTAssertTrue(t.contains(needle), "\(label): expected the refusal text to mention '\(needle)'. Got: \(t.prefix(200))", file: file, line: line)
        XCTAssertTrue(t.hasPrefix("Error: "), "\(label): the client-visible text must keep its 'Error: ' prefix. Got: \(t.prefix(80))", file: file, line: line)
        XCTAssertEqual(r.isError, true, "\(label): a refusal SHALL be isError: true on the wire, not a success result. Got isError=\(String(describing: r.isError))", file: file, line: line)
    }

    private func freshDoc(_ server: WordMCPServer, _ id: String = "d") async throws {
        _ = try await call(server, "create_document", ["doc_id": .string(id)])
        _ = try await call(server, "insert_paragraph", ["doc_id": .string(id), "text": .string("body")])
    }

    func testDirtyCloseRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "close_document", ["doc_id": .string("d")])
        assertRefused(r, "close_document (dirty, no discard)", expecting: "E_DIRTY_DOC")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testRecoverWithoutSourcePathRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "recover_from_autosave", ["doc_id": .string("d")])
        assertRefused(r, "recover_from_autosave (no source path)", expecting: "E_NO_AUTOSAVE")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testConflictingAnchorsRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "insert_paragraph",
                               ["doc_id": .string("d"), "text": .string("x"),
                                "after_text": .string("body"), "before_text": .string("body")])
        assertRefused(r, "insert_paragraph (conflicting anchors)", expecting: "conflicting anchors")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testInvalidScopeRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "replace_text",
                               ["doc_id": .string("d"), "find": .string("body"), "replace": .string("x"), "scope": .string("bogus")])
        assertRefused(r, "replace_text (invalid scope)", expecting: "invalid scope")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    func testUpdateCaptionWithoutChangesRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "update_caption", ["doc_id": .string("d"), "index": .int(0)])
        assertRefused(r, "update_caption (neither new_caption_text nor new_label)", expecting: "must provide new_caption_text or new_label")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    /// Verify R1 DA mutation M3: `throw ToolRefusal(formatSpliceError(…))` reverted to
    /// `return formatSpliceError(…)` kept the whole suite green. A refusal built by a
    /// helper and thrown by the caller must be pinned at the protocol level too.
    func testSpliceHelperBuiltRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "splice_omath_from_source",
                               ["doc_id": .string("d"), "source_doc_id": .string("d"),
                                "source_paragraph_index": .int(0), "target_paragraph_index": .int(0),
                                "position": .string("atStart")])
        assertRefused(r, "splice_omath_from_source (source paragraph without OMath)", expecting: "no OMath")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    /// R2 verify (regression M4e): `splice_paragraph_omath_from_source` was the one
    /// helper-built refusal site without a protocol pin. Same helper, other tool.
    /// (A source paragraph without OMath is a "Spliced 0 block(s)" success for this
    /// tool, not a refusal — the refusal path here is an out-of-range target.)
    func testSpliceParagraphHelperBuiltRefusalIsAnError() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        // A source paragraph WITH OMath — without one the tool splices nothing and
        // reports success without ever validating the target (noted on #215).
        let eq = try await call(server, "insert_equation", ["doc_id": .string("d"), "latex": .string("x^2")])
        XCTAssertNotEqual(eq.isError, true, "fixture: insert_equation must succeed. Got: \(text(eq).prefix(120))")
        let r = try await call(server, "splice_paragraph_omath_from_source",
                               ["doc_id": .string("d"), "source_doc_id": .string("d"),
                                "source_paragraph_index": .int(1), "target_paragraph_index": .int(99)])
        assertRefused(r, "splice_paragraph_omath_from_source (target paragraph out of range)", expecting: "out of range")
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }

    /// Positive control: a success reply must not be flagged — the fix is not
    /// "mark everything", it is "mark refusals". `nil` and `false` are both
    /// non-error on the wire, so the assertion is `!= true`, not `== nil`.
    func testSuccessReplyKeepsIsErrorUnset() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "get_document_session_state", ["doc_id": .string("d")])
        XCTAssertNotEqual(r.isError, true, "success reply must not be flagged as an error (nil and false are both non-error on the wire). Got: \(text(r).prefix(80))")
        XCTAssertFalse(text(r).hasPrefix("Error: "))
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }
}
