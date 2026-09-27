import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #192 — non-fatal advisories previously had NO channel back to the caller:
/// the existing `Warning: …` sites all wrote only to `FileHandle.standardError`,
/// which under MCP stdio transport lands in the client's own log file, never
/// in the tool result. A caller (model or user) could not see them.
///
/// Design (decided by the coordinator, applied here): an advisory rides as an
/// ADDITIONAL, independent text block in `CallTool.Result.content`, appended
/// AFTER the primary content block, with a fixed `Advisory: ` prefix.
/// `isError` is unaffected. A client that only reads `content.first` (most
/// clients) sees no change; a client that reads every block gets the
/// warning. stderr keeps writing the same line — this ADDS a channel, it
/// does not remove the existing one.
final class AdvisoryChannelTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvisoryChannel-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore write permission before cleanup — a still-locked-down
        // directory would make `removeItem` itself fail.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func tempDocxPath(_ name: String = "test.docx") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "ORIGINAL"))
        try DocxWriter.write(doc, to: url)
        return url.path
    }

    private func text(_ content: Tool.Content) -> String {
        if case .text(let t, _, _) = content { return t }
        return ""
    }

    private func firstText(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        return text(first)
    }

    // MARK: - End-to-end: the autosave-checkpoint-failure site named in #192

    /// The exact scenario #192's body names as the concrete existing failure:
    /// `dispatchAutosaveCheckpointIfDue`'s `catch` (Server.swift) only wrote
    /// stderr. This forces that catch to fire (checkpoint directory made
    /// unwritable right before the triggering mutation) and asserts the
    /// SAME call that hit it now carries the warning as a second content
    /// block — end-to-end proof the advisory channel actually reaches a
    /// caller, not just a unit test of the accumulator.
    func testAutosaveCheckpointFailureEmitsAdvisoryOnTheTriggeringCall() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("advc"), "autosave_every": .int(1),
        ])
        // storeDocument call #1 (counter 0→1): guard `counter > 0` fails, no
        // checkpoint dispatched yet — this call must NOT carry an advisory.
        let first = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string("advc"), "text": .string("first"),
        ])
        XCTAssertEqual(first.content.count, 1,
                       "no checkpoint fired yet (counter was 0) — no advisory expected: \(first.content)")

        // Remove write permission on the containing directory so creating
        // `<path>.autosave.docx` fails with EACCES — a real, not simulated,
        // checkpoint failure.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tempDir.path)

        // storeDocument call #2 (counter 1): guard passes (1 > 0 && 1 % 1 == 0)
        // — the checkpoint dispatch fires and its write fails.
        let r = try await server.handleToolCall(CallTool.Parameters(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("advc"), "text": .string("second")]
        ))

        XCTAssertNotEqual(r.isError, true,
                          "the mutation itself must still succeed — a checkpoint failure is advisory, not fatal: \(firstText(r))")
        XCTAssertTrue(firstText(r).contains("Inserted") || !firstText(r).hasPrefix("Advisory:"),
                      "the FIRST block must still be the ordinary success text: \(firstText(r))")
        XCTAssertEqual(r.content.count, 2,
                       "main result block + exactly one advisory block: \(r.content)")
        let advisory = text(r.content[1])
        XCTAssertTrue(advisory.hasPrefix("Advisory: "), "advisory block must carry the fixed prefix: \(advisory)")
        XCTAssertTrue(advisory.contains("autosave checkpoint failed"), "must name what happened: \(advisory)")
        XCTAssertTrue(advisory.contains("advc"), "must name which document: \(advisory)")
    }

    /// Positive control (mirrors the sweep-test pattern elsewhere in this
    /// suite): an ordinary call with nothing to warn about carries exactly
    /// one content block, unchanged from before #192.
    func testOrdinaryCallCarriesNoAdvisoryBlock() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "open_document", arguments: [
            "path": .string(path), "doc_id": .string("plain"),
        ])
        let r = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string("plain"), "text": .string("x"),
        ])
        XCTAssertEqual(r.content.count, 1, "no advisory happened — content must be exactly the one block: \(r.content)")
    }

    // MARK: - Shutdown flush stays stderr-only (not a tool call — no scope to attach an advisory to)

    /// `flushDirtyDocumentsOnShutdown`'s `Warning:` sites are NOT scoped to
    /// any in-flight tool call (shutdown happens after the transport ends),
    /// so there is no `CallTool.Result` for an advisory to ride on. #192
    /// explicitly keeps these stderr-only — this pins that they do not crash
    /// or otherwise misbehave when no advisory scope is active.
    func testShutdownFlushWithNoSavePathDoesNotCrashOutsideAToolCall() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("noscope")])
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string("noscope"), "text": .string("dirty, no source path"),
        ])
        // No CallTool scope active here — recordAdvisory (if reached via this
        // path) must be a safe no-op, not a crash.
        await server.flushDirtyDocumentsForTesting()
    }
}
