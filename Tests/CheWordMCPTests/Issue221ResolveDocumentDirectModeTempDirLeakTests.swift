import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#221 — `resolveDocument(args:)`'s Direct Mode
/// branch (`source_path`) calls `DocxReader.read(from:)`, which hands
/// ownership of its unzip tempDir to the returned `WordDocument` via
/// `preservedArchive` and documents "Caller MUST call `close()`" — but
/// `resolveDocument` reads the fields it needs and returns without ever
/// calling it. Every one of the 21 call sites in this file destructures the
/// `isTemporary` flag straight into `_` (`let (doc, _) = try await
/// resolveDocument(args: args)`), so none of THEM call `close()` either.
/// Each Direct Mode call on a long-running server leaves one fully
/// unzipped tempDir behind under `$TMPDIR/che-word-mcp/` until process exit.
///
/// Follows DocumentProfileToolsTests's precedent: read the ONE specific
/// archive path this call extracted off `debugEventLogForTesting()` and
/// assert on that exact path, rather than diffing the whole shared
/// `$TMPDIR/che-word-mcp/` namespace — a bare before/after diff of that
/// namespace is racy against any other concurrently running process
/// touching a real `.docx` (see that file's top-level doc comment and
/// `testSharedArchiveNamespaceSnapshotDiffIsFooledByAnUnrelatedConcurrentEntry`
/// for a deterministic demonstration of why).
final class Issue221ResolveDocumentDirectModeTempDirLeakTests: XCTestCase {

    private func minimalDocxOnePara() throws -> URL {
        var doc = WordDocument()
        doc.body.children.append(.paragraph(Paragraph(runs: [Run(text: "hello")])))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue221_direct_\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: url)
        return url
    }

    /// RED (pre-fix): a single read-only Direct Mode tool call
    /// (`get_document_info`, `source_path:`) leaves its extracted tempDir
    /// on disk after the call returns. (`get_document_text`/`get_text` is
    /// deliberately NOT used here — it has its own separate, hand-rolled
    /// Direct-Mode open that never goes through `resolveDocument` at all;
    /// a sibling leak outside #221's named scope.)
    func testSingleDirectModeCallDoesNotLeakItsTempDir() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        let r = await server.invokeToolForTesting(
            name: "get_document_info",
            arguments: ["source_path": .string(url.path)]
        )
        XCTAssertFalse(r.isError == true, textOf(r))

        let events = await server.debugEventLogForTesting().filter {
            $0.event == "resolveDocument.directModeArchiveExtracted"
        }
        XCTAssertEqual(events.count, 1, "expected exactly one Direct Mode archive-extracted event")
        let archivePath = try XCTUnwrap(events.first?.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
        XCTAssertNotEqual(archivePath, "nil", "the Direct Mode call must have successfully extracted an archive")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: archivePath),
            "a Direct Mode (source_path) call is read-only and must release its own extracted tempDir before returning — leaked at: \(archivePath)"
        )
    }

    /// RED (pre-fix): repeated Direct Mode calls against the same file each
    /// leak their own tempDir — this is the exact shape #199 verify R2
    /// measured empirically (8 Direct `list_images` calls → 8 leaked
    /// directories) and the issue names as its motivating example. Uses
    /// `list_images`, a DIFFERENT Direct-Mode tool than the single-call
    /// test above (`get_document_info`), to also confirm the fix is
    /// centralized in `resolveDocument` rather than tool-specific.
    func testRepeatedDirectModeCallsDoNotAccumulateLeakedTempDirs() async throws {
        let url = try minimalDocxOnePara()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = await WordMCPServer(forceDebugLogging: true)

        for _ in 0..<5 {
            let r = await server.invokeToolForTesting(
                name: "list_images",
                arguments: ["source_path": .string(url.path)]
            )
            XCTAssertFalse(r.isError == true, textOf(r))
        }

        let events = await server.debugEventLogForTesting().filter {
            $0.event == "resolveDocument.directModeArchiveExtracted"
        }
        XCTAssertEqual(events.count, 5, "expected exactly five Direct Mode archive-extracted events")
        for event in events {
            let archivePath = try XCTUnwrap(event.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
            XCTAssertNotEqual(archivePath, "nil")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: archivePath),
                "each Direct Mode call must release its own tempDir — leaked at: \(archivePath)"
            )
        }
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }
}
