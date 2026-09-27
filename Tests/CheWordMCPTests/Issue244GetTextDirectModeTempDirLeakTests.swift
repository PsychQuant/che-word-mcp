import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#244 — sister leak to #221. `get_document_text`
/// (and its alias `get_text`, which it literally calls — `getDocumentText`
/// is `return try await getText(args: args)`) has its own hand-written
/// Direct Mode open: `DocxReader.read(from: sourceURL)` followed directly
/// by `document.getText()`, with no `close()` in between. Neither
/// `resolveDocument` (#221) nor `loadDocumentFromArgs` (#221 H2) is
/// involved — this tool never routes through either shared helper — so both
/// fixes left this one path uncovered. Every call leaves one fully unzipped
/// tempDir under `$TMPDIR/che-word-mcp/` until process exit.
///
/// Follows the same "one specific path off the debug event log" technique
/// #221/#221-H2's own tests use, to avoid racing the shared tempDir
/// namespace against other concurrently running processes.
final class Issue244GetTextDirectModeTempDirLeakTests: XCTestCase {

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    private func minimalDocxOnePara() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello leak")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue244_gettext_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    private func archiveTempDir(event: String, from events: [WordMCPServer.DebugLogEvent]) throws -> String {
        let matches = events.filter { $0.event == event }
        XCTAssertEqual(matches.count, 1, "expected exactly one '\(event)' event, got \(matches.count)")
        let path = try XCTUnwrap(matches.first?.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
        XCTAssertNotEqual(path, "nil")
        return path
    }

    /// RED (pre-fix): a single `get_text` (Direct Mode, `source_path`) call
    /// leaves its extracted tempDir on disk after the call returns.
    func testGetTextClosesDirectModeRead() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        let r = await server.invokeToolForTesting(
            name: "get_text", arguments: ["source_path": .string(url.path)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))
        XCTAssertTrue(textOf(r).contains("hello leak"), "sanity: the text must actually have been read")

        let events = await server.debugEventLogForTesting()
        let archive = try archiveTempDir(event: "getText.archiveExtracted", from: events)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archive),
            "get_text's Direct Mode (source_path) read must release its own tempDir — leaked at: \(archive)"
        )
    }

    /// Same underlying handler via its alias `get_document_text` — confirms
    /// the fix covers both names, since `getDocumentText` literally
    /// delegates to `getText`.
    func testGetDocumentTextAliasClosesDirectModeRead() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        let r = await server.invokeToolForTesting(
            name: "get_document_text", arguments: ["source_path": .string(url.path)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        let events = await server.debugEventLogForTesting()
        let archive = try archiveTempDir(event: "getText.archiveExtracted", from: events)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archive),
            "get_document_text (alias) must release its own tempDir — leaked at: \(archive)"
        )
    }

    /// RED (pre-fix, repeated-call shape): #244's own repro is "call it
    /// repeatedly against the same file, watch the leaked-dir count grow".
    /// Five calls must produce five archive-extracted events, each already
    /// released by the time this test inspects it.
    func testRepeatedGetTextCallsDoNotAccumulateLeakedTempDirs() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        for _ in 0..<5 {
            let r = await server.invokeToolForTesting(
                name: "get_text", arguments: ["source_path": .string(url.path)]
            )
            XCTAssertFalse(r.isError == true, textOf(r))
        }

        let events = await server.debugEventLogForTesting().filter { $0.event == "getText.archiveExtracted" }
        XCTAssertEqual(events.count, 5, "expected exactly five Direct Mode archive-extracted events")
        for event in events {
            let path = try XCTUnwrap(event.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path),
                "each repeated get_text call must release its own tempDir — leaked at: \(path)"
            )
        }
    }
}
