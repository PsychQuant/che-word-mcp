import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// MCP-tool-level tests for the content control CRUD suite added in
/// `che-word-mcp-content-controls-read-write` (#44, §1 of roadmap #43).
///
/// Specs covered (see `openspec/changes/.../specs/che-word-mcp-insertion-tools/spec.md`):
/// - list_content_controls enumerates SDTs in a document
/// - get_content_control fetches a single SDT by id, tag, or alias
/// - update_content_control_text modifies plain-text SDT content
/// - replace_content_control_content replaces rich-text SDT content
/// - delete_content_control removes SDT with optional content preservation
/// - insert_content_control accepts advanced SDT types and extended args
/// - insert_repeating_section supports allow_insert_delete_sections arg
/// - list_repeating_section_items enumerates items of a repeating section SDT
/// - update_repeating_section_item modifies a single item's content
/// - list_custom_xml_parts returns empty stub
final class ContentControlToolsTests: XCTestCase {

    // MARK: - Helpers

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    /// Opens a freshly-created empty document with one anchor paragraph
    /// (so insert_content_control at index 0..1 has somewhere to land).
    private func openFreshDocument(_ server: WordMCPServer, id: String = "cc-test") async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
    }

    private func discardDocument(_ server: WordMCPServer, id: String) async {
        _ = await server.invokeToolForTesting(
            name: "discard_changes",
            arguments: ["doc_id": .string(id)]
        )
    }

    /// Insert a plain-text content control at paragraph_index, returning the
    /// SDT's allocated id by parsing the tool's response.
    private func insertPlainTextControl(
        _ server: WordMCPServer,
        docId: String,
        index: Int,
        tag: String,
        content: String
    ) async -> Int {
        let r = await server.invokeToolForTesting(name: "insert_content_control", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(index),
            "type": .string("text"),
            "tag": .string(tag),
            "content": .string(content)
        ])
        let text = resultText(r)
        // Format: "Inserted text content control 'tag' (id=N) at paragraph X"
        guard let range = text.range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            return -1
        }
        let match = String(text[range])
        return Int(match.dropFirst(3)) ?? -1
    }

    // MARK: - Task 5.1: list_content_controls

    func testListContentControlsReturnsInsertedSDTsAfterTask51() async throws {
        let server = await WordMCPServer()
        let docId = "list-cc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await insertPlainTextControl(server, docId: docId, index: 1, tag: "client", content: "Acme")
        _ = await insertPlainTextControl(server, docId: docId, index: 2, tag: "city", content: "Taipei")

        let r = await server.invokeToolForTesting(name: "list_content_controls", arguments: [
            "doc_id": .string(docId)
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"tag\": \"client\""), "client SDT missing: \(body)")
        XCTAssertTrue(body.contains("\"tag\": \"city\""), "city SDT missing: \(body)")
        XCTAssertTrue(body.contains("\"current_text\": \"Acme\""), "Acme text missing: \(body)")
        XCTAssertTrue(body.contains("\"parent_sdt_id\": null"), "parent_sdt_id field missing for top-level SDT")
    }

    // MARK: - Task 5.2: get_content_control

    func testGetContentControlByTagReturnsMatchAfterTask52() async throws {
        let server = await WordMCPServer()
        let docId = "get-cc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await insertPlainTextControl(server, docId: docId, index: 1, tag: "client_name", content: "Acme")

        let r = await server.invokeToolForTesting(name: "get_content_control", arguments: [
            "doc_id": .string(docId),
            "tag": .string("client_name")
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"tag\": \"client_name\""), "tag missing: \(body)")
        XCTAssertTrue(body.contains("\"current_text\": \"Acme\""), "current_text missing: \(body)")
        XCTAssertTrue(body.contains("\"content_xml\""), "content_xml missing: \(body)")
    }

    func testGetContentControlNotFoundReturnsErrorAfterTask52() async throws {
        let server = await WordMCPServer()
        let docId = "get-cc-nf-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "get_content_control", arguments: [
            "doc_id": .string(docId),
            "tag": .string("nonexistent")
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"error\": \"not_found\""), "expected not_found, got: \(body)")
    }

    // MARK: - Task 5.3: list_repeating_section_items

    func testListRepeatingSectionItemsAfterTask53() async throws {
        let server = await WordMCPServer()
        let docId = "list-rs-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Insert a repeating section with 3 items
        let inserted = await server.invokeToolForTesting(name: "insert_repeating_section", arguments: [
            "doc_id": .string(docId),
            "tag": .string("line_items"),
            "items": .array([.string("Item A"), .string("Item B"), .string("Item C")])
        ])
        let insertedText = resultText(inserted)
        guard let idMatch = insertedText.range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            XCTFail("could not extract id from: \(insertedText)"); return
        }
        let id = Int(insertedText[idMatch].dropFirst(3)) ?? -1

        let r = await server.invokeToolForTesting(name: "list_repeating_section_items", arguments: [
            "doc_id": .string(docId),
            "id": .int(id)
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"text\": \"Item A\""), "Item A missing: \(body)")
        XCTAssertTrue(body.contains("\"text\": \"Item B\""), "Item B missing: \(body)")
        XCTAssertTrue(body.contains("\"text\": \"Item C\""), "Item C missing: \(body)")
    }

    // MARK: - Task 6.1: update_content_control_text

    func testUpdateContentControlTextOnPlainTextSucceedsAfterTask61() async throws {
        let server = await WordMCPServer()
        let docId = "upd-cc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let id = await insertPlainTextControl(server, docId: docId, index: 1, tag: "client", content: "TBD")
        XCTAssertGreaterThan(id, 0)

        _ = await server.invokeToolForTesting(name: "update_content_control_text", arguments: [
            "doc_id": .string(docId),
            "id": .int(id),
            "text": .string("Acme Corp")
        ])

        let r = await server.invokeToolForTesting(name: "get_content_control", arguments: [
            "doc_id": .string(docId), "tag": .string("client")
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"current_text\": \"Acme Corp\""),
            "updated text not visible: \(body)")
    }

    // MARK: - Task 6.2: replace_content_control_content

    func testReplaceContentControlContentWithParagraphAfterTask62() async throws {
        let server = await WordMCPServer()
        let docId = "rpl-cc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let id = await insertPlainTextControl(server, docId: docId, index: 1, tag: "x", content: "old")
        let newXML = "<w:p><w:r><w:t>Hello</w:t></w:r></w:p>"
        let r = await server.invokeToolForTesting(name: "replace_content_control_content", arguments: [
            "doc_id": .string(docId),
            "id": .int(id),
            "content_xml": .string(newXML)
        ])
        XCTAssertTrue(resultText(r).contains("Replaced"), "tool reported failure: \(resultText(r))")
    }

    func testReplaceContentControlContentRejectsNestedSdtAfterTask62() async throws {
        let server = await WordMCPServer()
        let docId = "rpl-bad-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let id = await insertPlainTextControl(server, docId: docId, index: 1, tag: "x", content: "y")
        let badXML = "<w:p/><w:sdt></w:sdt>"
        let r = await server.invokeToolForTesting(name: "replace_content_control_content", arguments: [
            "doc_id": .string(docId),
            "id": .int(id),
            "content_xml": .string(badXML)
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"error\": \"disallowed_element\""),
            "expected disallowed_element, got: \(body)")
        XCTAssertTrue(body.contains("\"element\": \"w:sdt\""),
            "element name missing: \(body)")
    }

    // MARK: - Task 6.3: delete_content_control

    func testDeleteContentControlKeepContentTrueAfterTask63() async throws {
        let server = await WordMCPServer()
        let docId = "del-cc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let id = await insertPlainTextControl(server, docId: docId, index: 1, tag: "wrap", content: "x")
        XCTAssertGreaterThan(id, 0)

        let r = await server.invokeToolForTesting(name: "delete_content_control", arguments: [
            "doc_id": .string(docId),
            "id": .int(id),
            "keep_content": .bool(true)
        ])
        XCTAssertTrue(resultText(r).contains("Deleted"), "delete failed: \(resultText(r))")

        // SDT should be gone after deletion
        let listAfter = await server.invokeToolForTesting(name: "list_content_controls", arguments: [
            "doc_id": .string(docId)
        ])
        XCTAssertFalse(resultText(listAfter).contains("\"tag\": \"wrap\""),
            "SDT still present after delete: \(resultText(listAfter))")
    }

    // MARK: - Task 6.4: update_repeating_section_item

    func testUpdateRepeatingSectionItemAfterTask64() async throws {
        let server = await WordMCPServer()
        let docId = "upd-rsi-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let inserted = await server.invokeToolForTesting(name: "insert_repeating_section", arguments: [
            "doc_id": .string(docId),
            "tag": .string("items"),
            "items": .array([.string("A"), .string("B"), .string("C")])
        ])
        guard let idMatch = resultText(inserted).range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            XCTFail("no id"); return
        }
        let id = Int(resultText(inserted)[idMatch].dropFirst(3)) ?? -1

        let r = await server.invokeToolForTesting(name: "update_repeating_section_item", arguments: [
            "doc_id": .string(docId),
            "parent_id": .int(id),
            "item_index": .int(1),
            "text": .string("B-updated")
        ])
        XCTAssertTrue(resultText(r).contains("Updated"), "update failed: \(resultText(r))")

        let listed = await server.invokeToolForTesting(name: "list_repeating_section_items", arguments: [
            "doc_id": .string(docId), "id": .int(id)
        ])
        let body = resultText(listed)
        XCTAssertTrue(body.contains("\"text\": \"B-updated\""), "B-updated missing: \(body)")
        XCTAssertTrue(body.contains("\"text\": \"A\""), "A missing: \(body)")
        XCTAssertTrue(body.contains("\"text\": \"C\""), "C missing: \(body)")
    }

    func testUpdateRepeatingSectionItemOutOfBoundsAfterTask64() async throws {
        let server = await WordMCPServer()
        let docId = "upd-rsi-oob-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let inserted = await server.invokeToolForTesting(name: "insert_repeating_section", arguments: [
            "doc_id": .string(docId),
            "tag": .string("oob"),
            "items": .array([.string("only")])
        ])
        guard let idMatch = resultText(inserted).range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            XCTFail("no id"); return
        }
        let id = Int(resultText(inserted)[idMatch].dropFirst(3)) ?? -1

        let r = await server.invokeToolForTesting(name: "update_repeating_section_item", arguments: [
            "doc_id": .string(docId),
            "parent_id": .int(id),
            "item_index": .int(99),
            "text": .string("nope")
        ])
        XCTAssertTrue(resultText(r).contains("\"error\": \"out_of_bounds\""),
            "expected out_of_bounds, got: \(resultText(r))")
    }

    // MARK: - Task 7.1: insert_content_control extensions

    func testInsertContentControlDropdownWithListItemsAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "ins-dd-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_content_control", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(1),
            "type": .string("dropDownList"),
            "tag": .string("priority"),
            "list_items": .array([
                .object(["value": .string("H"), "display_text": .string("High")]),
                .object(["value": .string("L"), "display_text": .string("Low")])
            ])
        ])
        XCTAssertTrue(resultText(r).contains("Inserted dropDownList"),
            "expected successful insert, got: \(resultText(r))")
    }

    func testInsertDropdownWithoutListItemsReturnsErrorAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "ins-dd-nf-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_content_control", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(1),
            "type": .string("dropDownList"),
            "tag": .string("priority")
        ])
        XCTAssertTrue(resultText(r).contains("Error"),
            "expected error for missing list_items, got: \(resultText(r))")
        XCTAssertTrue(resultText(r).contains("list_items"),
            "error should mention list_items: \(resultText(r))")
    }

    func testInsertContentControlRejectsRepeatingSectionAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "ins-reject-rs-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_content_control", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(1),
            "type": .string("repeatingSection"),
            "tag": .string("nope")
        ])
        XCTAssertTrue(resultText(r).contains("insert_repeating_section"),
            "expected redirect to insert_repeating_section, got: \(resultText(r))")
    }

    // MARK: - Task 7.2: insert_repeating_section allow_insert_delete_sections

    func testInsertRepeatingSectionAllowInsertDeleteFalseAfterTask72() async throws {
        let server = await WordMCPServer()
        let docId = "ins-rs-noins-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "insert_repeating_section", arguments: [
            "doc_id": .string(docId),
            "tag": .string("frozen"),
            "items": .array([.string("only")]),
            "allow_insert_delete_sections": .bool(false)
        ])
        XCTAssertTrue(resultText(r).contains("Inserted repeating section"),
            "insert failed: \(resultText(r))")
    }

    // MARK: - Task 8.1: list_custom_xml_parts stub

    func testListCustomXmlPartsReturnsEmptyArrayAfterTask81() async throws {
        let server = await WordMCPServer()
        let docId = "ls-cxp-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "list_custom_xml_parts", arguments: [
            "doc_id": .string(docId)
        ])
        XCTAssertEqual(resultText(r), "[]", "stub should return empty array")
    }

    // MARK: - Pre-existing sanity: scaffold compiles and server boots

    func testScaffoldBootsWordMCPServer() async {
        let server = await WordMCPServer()
        await openFreshDocument(server, id: "scaffold-boot")
        await discardDocument(server, id: "scaffold-boot")
    }
}
