import XCTest
import MCP
import OOXMLSwift
import CommonCrypto
@testable import CheWordMCP

/// Phase 3 of `che-word-mcp-save-durability-stack` (closes #38).
///
/// Spec: `openspec/changes/che-word-mcp-save-durability-stack/specs/che-word-mcp-session-state-api/spec.md`
/// Requirement: "save_document supports keep_bak opt-in for rollback escape hatch".
///
/// 4 spec scenarios:
/// 1. `keep_bak: true` preserves pre-save bytes (asserts `<target>.bak` SHA256 matches original)
/// 2. `keep_bak` default opt-out (no `.bak` created)
/// 3. Consecutive saves overwrite `.bak` (second save's `.bak` matches first save's output, NOT original)
/// 4. First-time save with non-existent target produces no `.bak`
final class BakPreservationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BakPreservation-\(UUID().uuidString)")
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

    private func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Scenario 1: keep_bak true preserves pre-save bytes

    func testKeepBakTruePreservesPreSaveBytes() async throws {
        let path = try tempDocxPath()
        let originalSha = sha256(try Data(contentsOf: URL(fileURLWithPath: path)))

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUTATION")]
        )
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1"), "keep_bak": .bool(true)]
        )

        let bakPath = path + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath),
                      "<target>.bak SHALL exist after save with keep_bak: true")
        let bakSha = sha256(try Data(contentsOf: URL(fileURLWithPath: bakPath)))
        XCTAssertEqual(bakSha, originalSha,
                       "<target>.bak SHALL contain pre-save (original) bytes")

        let postSha = sha256(try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertNotEqual(postSha, originalSha,
                          "Target SHALL contain new bytes after save")
    }

    // MARK: - Scenario 2: keep_bak default opt-out

    func testKeepBakDefaultOptOut() async throws {
        let path = try tempDocxPath()

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUTATION")]
        )
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1")]   // no keep_bak arg
        )

        let bakPath = path + ".bak"
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath),
                       "<target>.bak SHALL NOT exist after save without keep_bak (default opt-out)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "Target SHALL exist after save")
    }

    // MARK: - Scenario 3: Consecutive saves overwrite .bak

    func testConsecutiveSavesOverwriteBak() async throws {
        let path = try tempDocxPath()
        let originalSha = sha256(try Data(contentsOf: URL(fileURLWithPath: path)))

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )

        // First save with keep_bak: bak should match the original.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_1")]
        )
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1"), "keep_bak": .bool(true)]
        )
        let bakPath = path + ".bak"
        let firstBakSha = sha256(try Data(contentsOf: URL(fileURLWithPath: bakPath)))
        XCTAssertEqual(firstBakSha, originalSha,
                       "First .bak SHALL contain original bytes")

        // Capture target after first save (becomes pre-save state for second save).
        let firstSaveSha = sha256(try Data(contentsOf: URL(fileURLWithPath: path)))

        // Second save with keep_bak: bak should now match the FIRST save output, NOT original.
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT_2")]
        )
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: ["doc_id": .string("d1"), "keep_bak": .bool(true)]
        )

        let secondBakSha = sha256(try Data(contentsOf: URL(fileURLWithPath: bakPath)))
        XCTAssertEqual(secondBakSha, firstSaveSha,
                       "Second .bak SHALL contain bytes from first save (overwritten)")
        XCTAssertNotEqual(secondBakSha, originalSha,
                          "Second .bak SHALL NOT contain original-original bytes")
    }

    // MARK: - Scenario 4: First-time save with non-existent target

    func testFirstTimeSaveNoBak() async throws {
        let savePath = tempDir.appendingPathComponent("new.docx").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath),
                       "Pre-condition: target SHALL NOT exist")

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("FRESH")]
        )
        _ = await server.invokeToolForTesting(
            name: "save_document",
            arguments: [
                "doc_id": .string("d1"),
                "path": .string(savePath),
                "keep_bak": .bool(true)
            ]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath),
                      "Target SHALL exist after first-time save")
        let bakPath = savePath + ".bak"
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath),
                       "<target>.bak SHALL NOT exist when target was new (nothing to back up)")
    }
}
