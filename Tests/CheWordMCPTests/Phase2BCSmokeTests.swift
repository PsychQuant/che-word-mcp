import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Smoke tests for v3.4.0 Phase 2B (#29 #30) + Phase 2C (#24 #25 #31) tools.
/// Each test verifies tools return well-formed JSON output without crashing
/// on typical inputs. Spec scenarios covered exhaustively in the
/// `*-tools` capability specs.
final class Phase2BCSmokeTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func makeBaseFixture() throws -> URL {
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Phase 2BC smoke fixture"))
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: fixture)
        return fixture
    }

    // MARK: - Comment threads

    func testListCommentThreadsOnEmptyReturnsEmptyArray() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "list_comment_threads",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertEqual(resultText(result), "[]")
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testSyncExtendedCommentsReturnsCounts() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "sync_extended_comments",
            arguments: ["doc_id": .string("doc")]
        )
        let text = resultText(result)
        XCTAssertTrue(text.contains("\"added_extended\""))
        XCTAssertTrue(text.contains("\"removed_orphans\""))
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - People

    func testAddListDeletePersonRoundTrip() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        // Initially empty
        let listEmpty = await server.invokeToolForTesting(
            name: "list_people",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertEqual(resultText(listEmpty), "[]")
        // Add
        let added = await server.invokeToolForTesting(
            name: "add_person",
            arguments: ["doc_id": .string("doc"), "display_name": .string("Adam Kuo")]
        )
        XCTAssertTrue(resultText(added).contains("\"person_id\":\"Adam Kuo\""))
        // List should include
        let listOne = await server.invokeToolForTesting(
            name: "list_people",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(listOne).contains("Adam Kuo"))
        // Delete
        let deleted = await server.invokeToolForTesting(
            name: "delete_person",
            arguments: ["doc_id": .string("doc"), "person_id": .string("Adam Kuo")]
        )
        XCTAssertTrue(resultText(deleted).contains("\"comments_orphaned\":0"))
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testAddPersonDuplicateAppendsSuffix() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "add_person",
            arguments: ["doc_id": .string("doc"), "display_name": .string("Alice")]
        )
        let dup = await server.invokeToolForTesting(
            name: "add_person",
            arguments: ["doc_id": .string("doc"), "display_name": .string("Alice")]
        )
        XCTAssertTrue(resultText(dup).contains("Alice_2"))
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - Notes update

    func testGetEndnoteUnknownIdReturnsError() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_endnote",
            arguments: ["doc_id": .string("doc"), "endnote_id": .int(999)]
        )
        XCTAssertTrue(resultText(result).contains("Error"))
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - Web settings

    func testGetWebSettingsOnDocWithoutPartReturnsError() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        let result = await server.invokeToolForTesting(
            name: "get_web_settings",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(result).contains("no webSettings part"))
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testUpdateWebSettingsCreatesPart() async throws {
        let fixture = try makeBaseFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(fixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "update_web_settings",
            arguments: ["doc_id": .string("doc"), "rely_on_vml": .bool(true)]
        )
        let result = await server.invokeToolForTesting(
            name: "get_web_settings",
            arguments: ["doc_id": .string("doc")]
        )
        XCTAssertTrue(resultText(result).contains("\"rely_on_vml\":true"),
                      "expected rely_on_vml=true; got: \(resultText(result))")
        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    // MARK: - v3.5.0 dirty-tracking + presenceInfo round-trip scenarios (Task 2.8)

    /// Build a Reader-loaded fixture with multiple typed parts (fontTable + theme +
    /// settings) so we can verify that touching one archive part via the new
    /// markPartDirty contract leaves the others byte-equal.
    private func makeReaderLoadedFixture() throws -> URL {
        // Reuse scratch-mode DocxWriter then unzip-rezip to ensure
        // archiveTempDir is engaged on the next open_document call.
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "Phase 2BC dirty-tracking fixture"))
        let baseFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-rl-base-\(UUID().uuidString).docx")
        try DocxWriter.write(doc, to: baseFixture)
        defer { try? FileManager.default.removeItem(at: baseFixture) }

        // Re-zip via staging so archiveTempDir works (DocxReader requires
        // physical .docx archives).
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-rl-staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { ZipHelper.cleanup(staging) }
        try FileManager.default.unzipItem(at: baseFixture, to: staging)

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-rl-\(UUID().uuidString).docx")
        try ZipHelper.zip(staging, to: fixture)
        return fixture
    }

    func testUpdateWebSettingsThenSavePreservesFontTableByteEqual() async throws {
        let srcFixture = try makeReaderLoadedFixture()
        defer { try? FileManager.default.removeItem(at: srcFixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(srcFixture.path), "doc_id": .string("doc")]
        )
        // Engage update_web_settings — this calls writeArchivePart(... "word/webSettings.xml" ...).
        // v3.5.0 wiring: writeArchivePart now also calls doc.markPartDirty,
        // so save_document overlay mode preserves fontTable.xml byte-equal.
        _ = await server.invokeToolForTesting(
            name: "update_web_settings",
            arguments: ["doc_id": .string("doc"), "rely_on_vml": .bool(true)]
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-rl-dest-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )

        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-cmp-src-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-cmp-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.unzipItem(at: srcFixture, to: srcDir)
        try FileManager.default.unzipItem(at: dest, to: destDir)

        // fontTable.xml must be byte-equal — only webSettings.xml (a new part)
        // was added. Pre-v3.5.0 (no markPartDirty wiring) the writer would
        // skip webSettings BUT also re-emit fontTable from the hardcoded
        // 3-entry default, breaking byte equality.
        let ftSrc = try Data(contentsOf: srcDir.appendingPathComponent("word/fontTable.xml"))
        let ftDst = try Data(contentsOf: destDir.appendingPathComponent("word/fontTable.xml"))
        XCTAssertEqual(ftSrc, ftDst, "fontTable.xml must survive byte-equal after update_web_settings")

        // webSettings.xml exists in dest (it was created by update_web_settings)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destDir.appendingPathComponent("word/webSettings.xml").path),
            "webSettings.xml must be present in dest after update_web_settings"
        )

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }

    func testAddPersonThenSavePreservesAllOtherTypedParts() async throws {
        let srcFixture = try makeReaderLoadedFixture()
        defer { try? FileManager.default.removeItem(at: srcFixture) }
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(srcFixture.path), "doc_id": .string("doc")]
        )
        _ = await server.invokeToolForTesting(
            name: "add_person",
            arguments: ["doc_id": .string("doc"), "display_name": .string("Phase2BCTester")]
        )
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-add-person-dest-\(UUID().uuidString).docx")
        defer { try? FileManager.default.removeItem(at: dest) }
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("doc"), "path": .string(dest.path)]
        )

        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-add-cmp-src-\(UUID().uuidString)")
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2bc-add-cmp-dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: srcDir)
            try? FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.unzipItem(at: srcFixture, to: srcDir)
        try FileManager.default.unzipItem(at: dest, to: destDir)

        for part in ["word/document.xml", "word/styles.xml", "word/fontTable.xml", "word/settings.xml"] {
            let s = try Data(contentsOf: srcDir.appendingPathComponent(part))
            let d = try Data(contentsOf: destDir.appendingPathComponent(part))
            XCTAssertEqual(s, d, "\(part) must be byte-equal after add_person")
        }

        // people.xml exists with Phase2BCTester
        let peopleXML = try String(
            contentsOf: destDir.appendingPathComponent("word/people.xml"),
            encoding: .utf8
        )
        XCTAssertTrue(peopleXML.contains("Phase2BCTester"))

        _ = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("doc"), "discard_changes": .bool(true)]
        )
    }
}
