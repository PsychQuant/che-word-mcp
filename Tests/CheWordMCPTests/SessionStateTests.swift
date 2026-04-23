import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

final class SessionStateTests: XCTestCase {

    private func writeTempFile(bytes: Data, ext: String = "bin") throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sst-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url)
        return url.path
    }

    // MARK: 1.3 (a) — SHA256 deterministic

    func testComputeSHA256Deterministic() throws {
        let path = try writeTempFile(bytes: Data("hello".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let h1 = try SessionState.computeSHA256(path: path)
        let h2 = try SessionState.computeSHA256(path: path)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 32) // SHA256 = 32 bytes
    }

    func testComputeSHA256DifferentBytesDifferentHash() throws {
        let a = try writeTempFile(bytes: Data("a".utf8))
        let b = try writeTempFile(bytes: Data("b".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
        }
        XCTAssertNotEqual(try SessionState.computeSHA256(path: a),
                          try SessionState.computeSHA256(path: b))
    }

    // MARK: 1.3 (b) — readMtime

    func testReadMtimeReturnsFileModificationDate() throws {
        let path = try writeTempFile(bytes: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let mtime = try SessionState.readMtime(path: path)
        // Just-written file's mtime should be within a few seconds of now.
        let age = Date().timeIntervalSince(mtime)
        XCTAssertLessThan(abs(age), 5.0)
    }

    // MARK: 1.3 (c) — inSync for untouched file

    func testCheckDriftStatusInSyncForUntouchedFile() throws {
        let path = try writeTempFile(bytes: Data("content".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let knownHash = try SessionState.computeSHA256(path: path)
        let knownMtime = try SessionState.readMtime(path: path)

        XCTAssertEqual(
            SessionState.checkDriftStatus(path: path, knownHash: knownHash, knownMtime: knownMtime),
            .inSync
        )
    }

    // MARK: 1.3 (d) — driftedHash after byte modification

    func testCheckDriftStatusDriftedHashAfterByteChange() throws {
        let path = try writeTempFile(bytes: Data("v1".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let knownHash = try SessionState.computeSHA256(path: path)
        let knownMtime = try SessionState.readMtime(path: path)

        // External edit: overwrite with new content.
        try Data("v2-different".utf8).write(to: URL(fileURLWithPath: path))

        let status = SessionState.checkDriftStatus(
            path: path,
            knownHash: knownHash,
            knownMtime: knownMtime
        )
        XCTAssertEqual(status, .driftedHash)
    }

    // MARK: 1.3 (e) — driftedMtime if mtime changes but hash matches

    func testCheckDriftStatusDriftedMtimeWithSameHash() throws {
        let path = try writeTempFile(bytes: Data("same".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let knownHash = try SessionState.computeSHA256(path: path)
        // Fake an older mtime (yesterday) so the current on-disk mtime is newer
        // but the hash still matches.
        let fakeOldMtime = Date(timeIntervalSinceNow: -86400)

        let status = SessionState.checkDriftStatus(
            path: path,
            knownHash: knownHash,
            knownMtime: fakeOldMtime
        )
        XCTAssertEqual(status, .driftedMtime)
    }

    // MARK: Missing file — driftedHash (conservative)

    func testCheckDriftStatusMissingFileReturnsDriftedHash() {
        let path = "/tmp/definitely-not-here-\(UUID().uuidString)"
        let status = SessionState.checkDriftStatus(
            path: path,
            knownHash: Data(repeating: 0, count: 32),
            knownMtime: Date()
        )
        XCTAssertEqual(status, .driftedHash)
    }

    // MARK: SessionStateView equatable

    func testSessionStateViewEquatable() {
        let mtime = Date()
        let a = SessionStateView(
            sourcePath: "/x.docx",
            diskHash: Data([0x01, 0x02]),
            diskMtime: mtime,
            isDirty: false,
            trackChangesEnabled: false
        )
        let b = SessionStateView(
            sourcePath: "/x.docx",
            diskHash: Data([0x01, 0x02]),
            diskMtime: mtime,
            isDirty: false,
            trackChangesEnabled: false
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - 5.1 Integration tests (MCP-tool level)

    private func tempDocx(_ suffix: String = UUID().uuidString) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sst-int-\(suffix).docx")
        var document = WordDocument()
        document.appendParagraph(Paragraph(text: "initial"))
        try DocxWriter.write(document, to: url)
        return url.path
    }

    private func resultText(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        switch first {
        case .text(let t, _, _): return t
        default: return ""
        }
    }

    func testOpenSetsIsDirtyFalse() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let sst = await server.invokeToolForTesting(
            name: "get_session_state",
            arguments: ["doc_id": .string("d1")]
        )
        XCTAssertTrue(resultText(sst).contains("is_dirty: false"))
    }

    func testInsertParagraphFlipsIsDirty() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("edit")]
        )
        let sst = await server.invokeToolForTesting(
            name: "get_session_state",
            arguments: ["doc_id": .string("d1")]
        )
        XCTAssertTrue(resultText(sst).contains("is_dirty: true"))
    }

    func testRevertToDiskDropsEditsAndResetsDirty() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("edit")]
        )
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("d1")
            XCTAssertTrue(isDirty_)
        }

        _ = await server.invokeToolForTesting(
            name: "revert_to_disk",
            arguments: ["doc_id": .string("d1")]
        )
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("d1")
            XCTAssertFalse(isDirty_)
        }
    }

    func testCloseDirtyWithoutDiscardReturnsEDirtyDoc() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("edit")]
        )
        let closeResult = await server.invokeToolForTesting(
            name: "close_document",
            arguments: ["doc_id": .string("d1")]
        )
        let text = resultText(closeResult)
        XCTAssertTrue(text.contains("E_DIRTY_DOC"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("d1")
            XCTAssertTrue(isDirty_)
        }
    }

    func testCloseDirtyWithDiscardSucceeds() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("edit")]
        )
        let closeResult = await server.invokeToolForTesting(
            name: "close_document",
            arguments: [
                "doc_id": .string("d1"),
                "discard_changes": .bool(true)
            ]
        )
        XCTAssertTrue(resultText(closeResult).contains("Closed document"))
        do {
            let isDirty_ = await server.isDocumentDirtyForTesting("d1")
            XCTAssertFalse(isDirty_)
        }
    }

    func testCheckDiskDriftReportsNoDriftOnUntouched() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        let drift = await server.invokeToolForTesting(
            name: "check_disk_drift",
            arguments: ["doc_id": .string("d1")]
        )
        XCTAssertTrue(resultText(drift).contains("drifted: false"))
    }

    func testCheckDiskDriftReportsDriftAfterExternalEdit() async throws {
        let path = try tempDocx()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
        // External write: overwrite with different bytes
        try Data("bogus-content".utf8).write(to: URL(fileURLWithPath: path))
        let drift = await server.invokeToolForTesting(
            name: "check_disk_drift",
            arguments: ["doc_id": .string("d1")]
        )
        XCTAssertTrue(resultText(drift).contains("drifted: true"))
    }
}
