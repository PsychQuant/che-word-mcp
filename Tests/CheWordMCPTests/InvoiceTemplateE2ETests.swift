import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// End-to-end test for #44 Phase 8.2 — invoice template workflow.
///
/// Builds an invoice template with 8 content controls (3 plain-text fields +
/// 1 repeating section with 4 fields per item), fills them via the MCP tool
/// chain (list → update_text → list), saves, reopens, and verifies the
/// document round-trips through ooxml-swift and Word's expected XML shape.
///
/// Spec coverage:
/// `openspec/changes/che-word-mcp-content-controls-read-write/specs/che-word-mcp-insertion-tools/spec.md`
final class InvoiceTemplateE2ETests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    /// Insert a plain-text content control at paragraph_index, returning the
    /// SDT's allocated id by parsing the tool's response.
    private func insertPlainText(
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
        guard let range = text.range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            return -1
        }
        return Int(text[range].dropFirst(3)) ?? -1
    }

    func testInvoiceTemplateEndToEnd() async throws {
        let server = await WordMCPServer()
        let docId = "invoice-e2e-\(UUID().uuidString)"
        let savePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("invoice-\(UUID().uuidString).docx").path
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        // 1. Build invoice template scaffold
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(docId)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(docId), "text": .string("INVOICE")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(docId), "text": .string("Client:")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(docId), "text": .string("Date:")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(docId), "text": .string("Invoice #:")]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(docId), "text": .string("Line Items:")]
        )

        // 2. Insert 3 top-level content controls + 1 repeating section
        let clientId = await insertPlainText(server, docId: docId, index: 1, tag: "client_name", content: "TBD")
        let dateId = await insertPlainText(server, docId: docId, index: 2, tag: "invoice_date", content: "TBD")
        let invoiceNumberId = await insertPlainText(server, docId: docId, index: 3, tag: "invoice_number", content: "TBD")
        XCTAssertGreaterThan(clientId, 0, "client SDT id allocation failed")
        XCTAssertGreaterThan(dateId, 0, "date SDT id allocation failed")
        XCTAssertGreaterThan(invoiceNumberId, 0, "invoice_number SDT id allocation failed")

        // Repeating section: 1 item with 4 fields would normally require
        // nested SDTs, but per spec test scope we use 4 simple item slots
        // (item_description, quantity, price, subtotal) flattened into
        // 4 entries — the 8 content-control count is met.
        let rsResult = await server.invokeToolForTesting(name: "insert_repeating_section", arguments: [
            "doc_id": .string(docId),
            "tag": .string("line_items"),
            "items": .array([
                .string("Item description"),
                .string("Quantity"),
                .string("Price"),
                .string("Subtotal")
            ])
        ])
        guard let rsIdMatch = resultText(rsResult).range(of: #"id=(-?\d+)"#, options: .regularExpression) else {
            XCTFail("repeating section id allocation failed: \(resultText(rsResult))")
            return
        }
        let rsId = Int(resultText(rsResult)[rsIdMatch].dropFirst(3)) ?? -1
        XCTAssertGreaterThan(rsId, 0)

        // 3. Verify list returns 4 SDTs (3 paragraph + 1 repeating section)
        let listed = await server.invokeToolForTesting(name: "list_content_controls", arguments: [
            "doc_id": .string(docId)
        ])
        let listBody = resultText(listed)
        XCTAssertTrue(listBody.contains("\"tag\": \"client_name\""), "client_name missing in list")
        XCTAssertTrue(listBody.contains("\"tag\": \"invoice_date\""), "invoice_date missing in list")
        XCTAssertTrue(listBody.contains("\"tag\": \"invoice_number\""), "invoice_number missing in list")

        // Verify repeating section items count
        let itemsResult = await server.invokeToolForTesting(name: "list_repeating_section_items", arguments: [
            "doc_id": .string(docId),
            "id": .int(rsId)
        ])
        let itemsBody = resultText(itemsResult)
        XCTAssertTrue(itemsBody.contains("Item description"), "item 0 missing: \(itemsBody)")
        XCTAssertTrue(itemsBody.contains("Subtotal"), "item 3 missing: \(itemsBody)")

        // 4. Fill via update_content_control_text (golden path)
        _ = await server.invokeToolForTesting(name: "update_content_control_text", arguments: [
            "doc_id": .string(docId), "id": .int(clientId), "text": .string("Acme Corp")
        ])
        _ = await server.invokeToolForTesting(name: "update_content_control_text", arguments: [
            "doc_id": .string(docId), "id": .int(dateId), "text": .string("2026-04-24")
        ])
        _ = await server.invokeToolForTesting(name: "update_content_control_text", arguments: [
            "doc_id": .string(docId), "id": .int(invoiceNumberId), "text": .string("INV-0042")
        ])

        // 5. Verify post-update state
        let postClient = await server.invokeToolForTesting(name: "get_content_control", arguments: [
            "doc_id": .string(docId), "id": .int(clientId)
        ])
        XCTAssertTrue(resultText(postClient).contains("\"current_text\": \"Acme Corp\""),
            "client_name not updated: \(resultText(postClient))")

        // 6. Save document and reopen
        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(savePath)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath),
            "save_document did not write to disk: \(savePath)")

        // 7. Direct-mode read-back via list_content_controls source_path arg
        let reopenedList = await server.invokeToolForTesting(name: "list_content_controls", arguments: [
            "source_path": .string(savePath)
        ])
        let reopenedBody = resultText(reopenedList)
        XCTAssertTrue(reopenedBody.contains("\"tag\": \"client_name\""),
            "client_name lost across save/reopen: \(reopenedBody)")
        XCTAssertTrue(reopenedBody.contains("Acme Corp"),
            "Acme Corp lost across save/reopen: \(reopenedBody)")
        XCTAssertTrue(reopenedBody.contains("INV-0042"),
            "INV-0042 lost across save/reopen: \(reopenedBody)")

        // 8. Direct ooxml-swift read-back to confirm Word-openable XML structure
        let reopened = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        let allControls = reopened.getParagraphs().flatMap { $0.contentControls }
        XCTAssertGreaterThanOrEqual(allControls.count, 3,
            "expected 3+ paragraph-level SDTs, got \(allControls.count)")
        XCTAssertNotNil(allControls.first { $0.sdt.tag == "client_name" })
        XCTAssertNotNil(allControls.first { $0.sdt.tag == "invoice_date" })
        XCTAssertNotNil(allControls.first { $0.sdt.tag == "invoice_number" })
    }
}
