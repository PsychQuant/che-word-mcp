import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase 4 of `che-word-mcp-save-durability-stack` (closes #37).
///
/// Spec: `openspec/changes/che-word-mcp-save-durability-stack/specs/che-word-mcp-session-state-api/spec.md`
/// Covers 5 new ADDED requirements:
/// - `open_document supports autosave_every for periodic checkpoint`
/// - `checkpoint MCP tool for manual session state write`
/// - `recover_from_autosave MCP tool replaces session state with autosave bytes`
/// - `open_document detects existing autosave file`
/// - "Successful save_document cleans up .autosave.docx" (scenario under autosave_every requirement)
final class AutosaveCheckpointTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveCheckpoint-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
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

    private func resultText(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        switch first {
        case .text(let t, _, _): return t
        default: return ""
        }
    }

    // MARK: - Scenario 1: autosave fires at every Nth mutation

    func testAutosaveEveryNthMutation() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(path),
                "doc_id": .string("d1"),
                "autosave_every": .int(3)
            ]
        )

        let autosavePath = path + ".autosave.docx"
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                       "Pre-condition: no autosave before any mutation")

        // v3.7.0 Design B (#40): snapshot fires at the START of every Nth+1 mutation.
        // For N=3 + 7 mutations: snapshot fires at start of mut4 (counter==3) and mut7 (counter==6).
        for i in 1...7 {
            _ = await server.invokeToolForTesting(
                name: "insert_paragraph",
                arguments: ["doc_id": .string("d1"), "text": .string("MUT_\(i)")]
            )
            switch i {
            case 1, 2, 3:
                XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                               "After mutation \(i): no autosave yet (Design B: no snapshot fired in mut1-3)")
            case 4:
                XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                              "After mutation 4: autosave SHALL exist (snapshot fired at mut4 start, capturing post-MUT_3)")
            case 5, 6:
                XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                              "After mutation \(i): autosave from mut4 still exists")
            case 7:
                XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                              "After mutation 7: autosave SHALL be overwritten (snapshot fired at mut7 start, capturing post-MUT_6)")
            default: break
            }
        }
    }

    // MARK: - Scenario 2: autosave_every: 0 disables autosave

    func testAutosaveEveryZeroDisables() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(path),
                "doc_id": .string("d1"),
                "autosave_every": .int(0)
            ]
        )

        // 100 mutations — autosave should NEVER appear.
        for i in 1...100 {
            _ = await server.invokeToolForTesting(
                name: "insert_paragraph",
                arguments: ["doc_id": .string("d1"), "text": .string("MUT_\(i)")]
            )
        }

        let autosavePath = path + ".autosave.docx"
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                       "Autosave SHALL NEVER fire when autosave_every: 0")
    }

    // MARK: - Scenario 3: Successful save_document cleans up .autosave.docx

    func testSaveDocumentCleansUpAutosave() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(path),
                "doc_id": .string("d1"),
                "autosave_every": .int(1)   // every mutation → snapshot on next mutation start
            ]
        )

        // v3.7.0 Design B (#40): snapshot fires at START of mutation when counter > 0 && counter % N == 0.
        // For N=1: 1st mutation has counter=0 (no snapshot); 2nd mutation has counter=1 (snapshot fires).
        // Need 2 mutations to get an autosave file.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_2")]
        )

        let autosavePath = path + ".autosave.docx"
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                      "Pre-condition: autosave exists after 2 mutations (snapshot fired at MUT_2 start)")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1")]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                       "Autosave SHALL be cleaned up after successful save_document")
    }

    // MARK: - Scenario 4: Manual checkpoint writes to autosave path by default

    func testCheckpointDefaultPath() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("PRE_CHECKPOINT")]
        )
        _ = await server.invokeToolForTesting(
            name: "checkpoint",
            arguments: ["doc_id": .string("d1")]
        )

        let autosavePath = path + ".autosave.docx"
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                      "checkpoint default path SHALL be <source>.autosave.docx")

        // Checkpoint SHALL NOT clear is_dirty (unlike save_document).
        let dirty = await server.isDocumentDirtyForTesting("d1")
        XCTAssertTrue(dirty, "checkpoint SHALL NOT reset is_dirty")
    }

    // MARK: - Scenario 5: Manual checkpoint with explicit path

    func testCheckpointExplicitPath() async throws {
        let path = try tempDocxPath()
        let snapshotPath = tempDir.appendingPathComponent("snapshot-001.docx").path
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("snap")]
        )
        _ = await server.invokeToolForTesting(
            name: "checkpoint",
            arguments: ["doc_id": .string("d1"), "path": .string(snapshotPath)]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath),
                      "checkpoint SHALL write to explicit path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".autosave.docx"),
                       "checkpoint with explicit path SHALL NOT touch <source>.autosave.docx")
    }

    // MARK: - Scenario 6: open_document flags stale autosave

    func testOpenDocumentDetectsExistingAutosave() async throws {
        let path = try tempDocxPath()
        // Plant a stale autosave file (simulating prior crashed session).
        let autosavePath = path + ".autosave.docx"
        try Data("stale".utf8).write(to: URL(fileURLWithPath: autosavePath))

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let sst = await server.invokeToolForTesting(
            name: "get_session_state",
            arguments: ["doc_id": .string("d1")]
        )

        XCTAssertTrue(resultText(sst).contains("autosave_detected: true"),
                      "Session state SHALL include autosave_detected: true when stale file exists")
        XCTAssertTrue(resultText(sst).contains(autosavePath),
                      "Session state SHALL include autosave_path")
    }

    // MARK: - Scenario 7: open_document reports false when no autosave

    func testOpenDocumentReportsFalseAutosave() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let sst = await server.invokeToolForTesting(
            name: "get_session_state",
            arguments: ["doc_id": .string("d1")]
        )

        XCTAssertTrue(resultText(sst).contains("autosave_detected: false"),
                      "Session state SHALL include autosave_detected: false when no file exists")
    }

    // MARK: - Scenario 8: recover_from_autosave replaces session state

    func testRecoverFromAutosaveReplacesSession() async throws {
        let path = try tempDocxPath()

        // Create a separate "richer" autosave fixture with 12 paragraphs.
        var richerDoc = WordDocument()
        for i in 1...12 {
            richerDoc.appendParagraph(Paragraph(text: "RICH_\(i)"))
        }
        let autosavePath = path + ".autosave.docx"
        try DocxWriter.write(richerDoc, to: URL(fileURLWithPath: autosavePath))

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )

        // Pre-condition: in-memory doc has 1 paragraph (the original).
        // Recover from autosave (no dirty mutations yet, so no discard_changes needed).
        _ = await server.invokeToolForTesting(
            name: "recover_from_autosave",
            arguments: ["doc_id": .string("d1")]
        )

        // After recover: session SHALL have 12 paragraphs + is_dirty: true.
        let sst = await server.invokeToolForTesting(
            name: "get_session_state",
            arguments: ["doc_id": .string("d1")]
        )
        XCTAssertTrue(resultText(sst).contains("is_dirty: true"),
                      "After recover_from_autosave, is_dirty SHALL be true")

        // Autosave file still exists (cleanup deferred to next save).
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                      "Autosave file SHALL persist after recover (cleanup deferred to save_document)")

        // Verify in-memory doc actually has 12 paragraphs by saving + reading back.
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1")]
        )
        let saved = try DocxReader.read(from: URL(fileURLWithPath: path))
        let paraCount = saved.body.children.reduce(0) { acc, child in
            if case .paragraph = child { return acc + 1 }
            return acc
        }
        XCTAssertEqual(paraCount, 12,
                       "Saved doc SHALL contain 12 paragraphs (recovered from autosave)")
    }

    // MARK: - Scenario 9: recover_from_autosave refused on dirty session

    func testRecoverFromAutosaveRefusedOnDirty() async throws {
        let path = try tempDocxPath()
        let autosavePath = path + ".autosave.docx"
        try Data("stale".utf8).write(to: URL(fileURLWithPath: autosavePath))

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )

        // Make session dirty.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("DIRTY_MUT")]
        )

        // Try recover without discard_changes — must refuse.
        let r = await server.invokeToolForTesting(
            name: "recover_from_autosave",
            arguments: ["doc_id": .string("d1")]
        )

        XCTAssertTrue(r.isError == true || resultText(r).contains("E_DIRTY_DOC"),
                      "Recover SHALL be refused on dirty session without discard_changes; got: \(resultText(r))")
    }
}
