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
}
