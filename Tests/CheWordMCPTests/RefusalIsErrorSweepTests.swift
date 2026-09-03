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
        let files = try fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "sweep found no Swift sources under \(sourcesDir.path)")
        var offenders: [Offender] = []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // single-line: return "Error: …"
                if line.hasPrefix("return \"Error:") {
                    offenders.append(Offender(file: url.lastPathComponent, line: i + 1, text: line))
                    continue
                }
                // multi-line: any """ literal whose first content line opens with Error:
                // (return-position or helper body — both reach the client as a string)
                if line.hasSuffix("\"\"\"") && !line.hasPrefix("\"\"\"") || line == "\"\"\"" && i > 0 && !lines[i - 1].trimmingCharacters(in: .whitespaces).hasSuffix("\"\"\"") {
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("Error:") {
                        // a literal that is thrown is fine; one that is returned or built as a String is not
                        let opener = line
                        let isThrown = opener.contains("throw ")
                        if !isThrown {
                            offenders.append(Offender(file: url.lastPathComponent, line: j + 1, text: lines[j]))
                        }
                    }
                }
            }
        }
        return offenders
    }

    func testNoRefusalIsStillReturnedAsAString() throws {
        let offenders = try Self.stringRefusalSites()
        XCTAssertEqual(offenders.count, 0,
                       "\(offenders.count) refusal(s) are still `return \"Error: …\"` strings (isError never set):\n"
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

    /// Positive control: a success reply must keep `isError == nil` — the fix
    /// is not "mark everything", it is "mark refusals".
    func testSuccessReplyKeepsIsErrorUnset() async throws {
        let server = await WordMCPServer()
        try await freshDoc(server)
        let r = try await call(server, "get_document_session_state", ["doc_id": .string("d")])
        XCTAssertNil(r.isError, "success reply must not carry isError. Got: \(text(r).prefix(80))")
        XCTAssertFalse(text(r).hasPrefix("Error: "))
        _ = try await call(server, "close_document", ["doc_id": .string("d"), "discard_changes": .bool(true)])
    }
}
