import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#221 H1 (`review-cwm450.md` finding, real-binary
/// reproduced) — `revert_to_disk`, `reload_from_disk`, and
/// `recover_from_autosave` all re-read a fresh `WordDocument` from disk and
/// directly OVERWRITE `openDocuments[docId]`, discarding whatever
/// `WordDocument` was there before without ever calling `.close()` on it.
/// The discarded copy owns its own extracted tempDir (`DocxReader.read`'s
/// `preservedArchive`) — swapping the dictionary value loses the only
/// reference to it, so nothing (not even a LATER `close_document` on the
/// same `docId`) can ever release it. Same root cause as #221's
/// `resolveDocument` fix, different call sites.
///
/// Follows the same "one specific path off `debugEventLogForTesting()`"
/// technique #221's own tests use (see
/// `Issue221ResolveDocumentDirectModeTempDirLeakTests` and
/// `DocumentProfileToolsTests`'s top-level doc comment for why a bare
/// before/after diff of the shared `$TMPDIR/che-word-mcp/` namespace is
/// racy and therefore not used here either).
final class Issue221H1RevertReloadRecoverTempDirLeakTests: XCTestCase {

    private func tempDocxPath(_ dir: URL, _ name: String = "test.docx", paragraph: String = "ORIGINAL") throws -> String {
        let url = dir.appendingPathComponent(name)
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: paragraph))
        try DocxWriter.write(doc, to: url)
        return url.path
    }

    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("issue221h1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func textOf(_ r: CallTool.Result) -> String {
        r.content.compactMap { item -> String? in
            if case let .text(t, _, _) = item { return t } else { return nil }
        }.joined(separator: "\n")
    }

    /// Extracts the single `archive_temp_dir` value from the ONE debug
    /// event matching `event`, failing loudly if there isn't exactly one —
    /// a test that silently tolerated zero or multiple matches could pass
    /// without ever having checked what it claims to check.
    private func archiveTempDir(event: String, from events: [WordMCPServer.DebugLogEvent]) throws -> String {
        let matches = events.filter { $0.event == event }
        XCTAssertEqual(matches.count, 1, "expected exactly one '\(event)' event, got \(matches.count)")
        let path = try XCTUnwrap(matches.first?.keyValues.first { $0.0 == "archive_temp_dir" }?.1)
        XCTAssertNotEqual(path, "nil", "'\(event)' must have successfully extracted an archive")
        return path
    }

    // MARK: - revert_to_disk

    /// RED (pre-fix): the tempDir extracted by the ORIGINAL `open_document`
    /// call is still on disk after `revert_to_disk` swaps in a fresh read
    /// AND the session is closed — `close_document` only ever closes
    /// whatever document is CURRENTLY in the dictionary (the one
    /// `revert_to_disk` just put there), not the one it replaced.
    func testRevertToDiskClosesThePreviouslyOpenDocument() async throws {
        let dir = try scratchDir()
        let path = try tempDocxPath(dir)
        let server = await WordMCPServer(forceDebugLogging: true)

        let opened = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        XCTAssertFalse(opened.isError == true, textOf(opened))

        let reverted = await server.invokeToolForTesting(
            name: "revert_to_disk", arguments: ["doc_id": .string("d1")]
        )
        XCTAssertFalse(reverted.isError == true, textOf(reverted))

        let events = await server.debugEventLogForTesting()
        let originalArchive = try archiveTempDir(event: "openDocument.archiveExtracted", from: events)
        let revertedArchive = try archiveTempDir(event: "revertToDisk.archiveExtracted", from: events)
        XCTAssertNotEqual(originalArchive, revertedArchive, "revert_to_disk must extract a NEW archive, not reuse the original's")

        // The CURRENTLY active document's archive is still legitimately in
        // use — only the DISCARDED (original) one should already be gone.
        XCTAssertTrue(FileManager.default.fileExists(atPath: revertedArchive), "the still-active document's archive must not be touched yet")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalArchive),
            "revert_to_disk must release the document it REPLACED — leaked at: \(originalArchive)"
        )

        let closed = await server.invokeToolForTesting(
            name: "close_document", arguments: ["doc_id": .string("d1")]
        )
        XCTAssertFalse(closed.isError == true, textOf(closed))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: revertedArchive),
            "close_document must release the CURRENTLY active document's archive too"
        )
    }

    /// Same shape, but `revert_to_disk` called twice — pins that EVERY
    /// intermediate document gets released, not just the first swap.
    func testRepeatedRevertToDiskDoesNotAccumulateLeakedTempDirs() async throws {
        let dir = try scratchDir()
        let path = try tempDocxPath(dir)
        let server = await WordMCPServer(forceDebugLogging: true)

        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        for _ in 0..<2 {
            let r = await server.invokeToolForTesting(name: "revert_to_disk", arguments: ["doc_id": .string("d1")])
            XCTAssertFalse(r.isError == true, textOf(r))
        }

        let events = await server.debugEventLogForTesting()
        let originalArchive = try archiveTempDir(event: "openDocument.archiveExtracted", from: events)
        let revertEvents = events.filter { $0.event == "revertToDisk.archiveExtracted" }
        XCTAssertEqual(revertEvents.count, 2)
        let firstRevertArchive = try XCTUnwrap(revertEvents[0].keyValues.first { $0.0 == "archive_temp_dir" }?.1)
        let secondRevertArchive = try XCTUnwrap(revertEvents[1].keyValues.first { $0.0 == "archive_temp_dir" }?.1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalArchive), "the original open's archive must be released — leaked at: \(originalArchive)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstRevertArchive), "the FIRST revert's archive must be released once superseded by the second — leaked at: \(firstRevertArchive)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRevertArchive), "the second (currently active) revert's archive must still be present")

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("d1")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondRevertArchive))
    }

    // MARK: - reload_from_disk

    /// RED (pre-fix): same shape as `revert_to_disk`, different tool.
    func testReloadFromDiskClosesThePreviouslyOpenDocument() async throws {
        let dir = try scratchDir()
        let path = try tempDocxPath(dir)
        let server = await WordMCPServer(forceDebugLogging: true)

        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let reloaded = await server.invokeToolForTesting(
            name: "reload_from_disk", arguments: ["doc_id": .string("d1")]
        )
        XCTAssertFalse(reloaded.isError == true, textOf(reloaded))

        let events = await server.debugEventLogForTesting()
        let originalArchive = try archiveTempDir(event: "openDocument.archiveExtracted", from: events)
        let reloadedArchive = try archiveTempDir(event: "reloadFromDisk.archiveExtracted", from: events)
        XCTAssertNotEqual(originalArchive, reloadedArchive)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalArchive),
            "reload_from_disk must release the document it REPLACED — leaked at: \(originalArchive)"
        )

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("d1")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloadedArchive))
    }

    // MARK: - recover_from_autosave

    /// RED (pre-fix): same shape, via the autosave-swap path. Fixture
    /// mirrors `AutosaveCheckpointTests.testRecoverFromAutosaveReplacesSession`
    /// — a hand-written `.autosave.docx` sidecar, no need to actually
    /// trigger a real autosave write.
    func testRecoverFromAutosaveClosesThePreviouslyOpenDocument() async throws {
        let dir = try scratchDir()
        let path = try tempDocxPath(dir)
        var richerDoc = WordDocument()
        richerDoc.appendParagraph(Paragraph(text: "FROM_AUTOSAVE"))
        try DocxWriter.write(richerDoc, to: URL(fileURLWithPath: path + ".autosave.docx"))

        let server = await WordMCPServer(forceDebugLogging: true)
        _ = await server.invokeToolForTesting(
            name: "open_document", arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let recovered = await server.invokeToolForTesting(
            name: "recover_from_autosave", arguments: ["doc_id": .string("d1")]
        )
        XCTAssertFalse(recovered.isError == true, textOf(recovered))

        let events = await server.debugEventLogForTesting()
        let originalArchive = try archiveTempDir(event: "openDocument.archiveExtracted", from: events)
        let recoveredArchive = try archiveTempDir(event: "recoverFromAutosave.archiveExtracted", from: events)
        XCTAssertNotEqual(originalArchive, recoveredArchive)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: originalArchive),
            "recover_from_autosave must release the document it REPLACED — leaked at: \(originalArchive)"
        )

        _ = await server.invokeToolForTesting(name: "close_document", arguments: ["doc_id": .string("d1"), "discard_changes": .bool(true)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredArchive))
    }
}
