import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase C of `che-word-mcp-insert-crash-autosave-fix` (closes #40).
///
/// Spec: `openspec/changes/che-word-mcp-insert-crash-autosave-fix/specs/che-word-mcp-session-state-api/spec.md`
/// MODIFIED requirement: "open_document supports autosave_every for periodic checkpoint"
///
/// Design B semantic: snapshot fires at the START of every mutating handler
/// (before the mutation runs), capturing pre-mutation state. With default
/// `autosave_every: 1`, every mutation triggers a snapshot of state-just-before-mutation
/// → crash on mutation K preserves mutations 1..K-1 in the autosave file.
///
/// 4 spec scenarios:
/// 1. Default autosave_every preserves prior mutations on crash mid-batch
/// 2. autosave fires before every Nth mutation (counter trajectory)
/// 3. autosave_every: 0 disables autosave
/// 4. Successful save_document cleans up .autosave.docx + resets counter
final class AutosaveDesignBTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveDesignB-\(UUID().uuidString)")
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

    private func paragraphCount(at path: String) throws -> Int {
        let doc = try DocxReader.read(from: URL(fileURLWithPath: path))
        return doc.body.children.reduce(0) { acc, c in
            if case .paragraph = c { return acc + 1 }
            return acc
        }
    }

    // MARK: - Scenario 1: Default autosave_every preserves prior mutations on crash mid-batch

    /// Design B with N=1 default: every mutation captures state-just-before
    /// in the autosave file. After 2 successful mutations + simulated crash
    /// during mutation 3 entry (i.e., before mutation 3 finishes), the
    /// autosave file should contain MUT_1 + MUT_2 (the snapshot taken at
    /// mutation 3's START).
    ///
    /// We can't actually crash the process mid-test, so we approximate by
    /// checking the autosave file's paragraph count BEFORE mutation 3 completes.
    /// Per Design B: at the moment mutation 3's snapshot dispatch returns,
    /// the file holds the post-MUT_2 state. After mutation 3 also completes
    /// (no crash), the IN-MEMORY state has 3 mutations but the autosave file
    /// still represents post-MUT_2 (next snapshot fires at start of mutation 4).
    func testDesignBPreservesPriorMutationsOnCrashMidBatch() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()  // default autosave_every = 1

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )

        let autosavePath = path + ".autosave.docx"

        // Mutation 1 — start: counter=0, no snapshot. After: counter=1.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_1")]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                       "After MUT_1: no autosave yet (counter=0 at start, no snapshot)")

        // Mutation 2 — start: counter=1, snapshot fires capturing post-MUT_1 (1 paragraph original + MUT_1 = 2 paras).
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_2")]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                      "After MUT_2: autosave exists from MUT_2's pre-snapshot")
        let postMut1Count = try paragraphCount(at: autosavePath)
        XCTAssertEqual(postMut1Count, 2,
                       "Snapshot at MUT_2 start SHALL contain post-MUT_1 state (ORIGINAL + MUT_1 = 2 paras)")

        // Mutation 3 — start: counter=2, snapshot fires capturing post-MUT_2 (3 paras).
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_3")]
        )
        let postMut2Count = try paragraphCount(at: autosavePath)
        XCTAssertEqual(postMut2Count, 3,
                       "Snapshot at MUT_3 start SHALL contain post-MUT_2 state (ORIGINAL + MUT_1 + MUT_2 = 3 paras)")
    }

    // MARK: - Scenario 2: autosave fires before every Nth mutation

    func testAutosaveFiresBeforeEveryNthMutation() async throws {
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

        // Per Design B + N=3:
        // Pre-mut1 (counter=0): no snapshot
        // Pre-mut2 (counter=1, 1%3≠0): no snapshot
        // Pre-mut3 (counter=2, 2%3≠0): no snapshot
        // Pre-mut4 (counter=3, 3%3=0): SNAPSHOT — captures post-MUT_3 state
        // Pre-mut5: no snapshot
        // Pre-mut6: no snapshot
        // Pre-mut7 (counter=6, 6%3=0): SNAPSHOT — captures post-MUT_6 state
        for i in 1...7 {
            _ = await server.invokeToolForTesting(
                name: "insert_paragraph",
                arguments: ["doc_id": .string("d1"), "text": .string("MUT_\(i)")]
            )
            switch i {
            case 1, 2, 3:
                XCTAssertFalse(FileManager.default.fileExists(atPath: autosavePath),
                               "After mutation \(i): no autosave yet (no snapshot fired before any of mut1-3)")
            case 4:
                XCTAssertTrue(FileManager.default.fileExists(atPath: autosavePath),
                              "After mutation 4: autosave exists from mut4's pre-snapshot")
                // Snapshot fired at mut4 start = post-MUT_3 state = ORIGINAL + 3 muts = 4 paras
                XCTAssertEqual(try paragraphCount(at: autosavePath), 4,
                               "After mut4: autosave SHALL hold ORIGINAL + 3 muts = 4 paras")
            case 5, 6:
                // Autosave file unchanged since mut4's snapshot
                XCTAssertEqual(try paragraphCount(at: autosavePath), 4,
                               "After mut\(i): autosave SHALL still hold post-MUT_3 state (no snapshot at mut\(i))")
            case 7:
                // Snapshot fired at mut7 start = post-MUT_6 state = 7 paras
                XCTAssertEqual(try paragraphCount(at: autosavePath), 7,
                               "After mut7: autosave SHALL hold post-MUT_6 state (overwritten)")
            default: break
            }
        }
    }

    // MARK: - Scenario 3: autosave_every: 0 disables autosave

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

        for i in 1...20 {
            _ = await server.invokeToolForTesting(
                name: "insert_paragraph",
                arguments: ["doc_id": .string("d1"), "text": .string("MUT_\(i)")]
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".autosave.docx"),
                       "autosave_every: 0 SHALL never create autosave file")
    }

    // MARK: - Scenario 4: save_document cleans up + resets counter

    func testSaveDocumentCleansUpAndResetsCounter() async throws {
        let path = try tempDocxPath()
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]  // default N=1
        )

        // Two mutations to ensure a snapshot exists.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_2")]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".autosave.docx"),
                      "Pre-condition: autosave file exists after mutations")

        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1")]
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".autosave.docx"),
                       "After save_document: autosave file SHALL be removed")

        // Subsequent mutation should NOT immediately create a snapshot
        // (counter was reset, so first new mutation has counter=0 at start = no snapshot).
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_3")]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".autosave.docx"),
                       "After save_document + 1 new mutation: no autosave yet (counter reset)")
    }
}
