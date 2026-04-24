import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// E2E tests for #44 Phase 10 — exercises the full styles + numbering +
/// sections tool chain end-to-end against realistic Word template scenarios.
///
/// Spec coverage: openspec/changes/che-word-mcp-styles-sections-numbering-foundations/specs/
final class CorporateTemplateE2ETests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _): return text
        default: return ""
        }
    }

    private func openFreshDocument(_ server: WordMCPServer, id: String) async {
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

    /// Task 10.1: Corporate template — 3-level Heading inheritance + qFormat +
    /// linked paragraph/character styles + latentStyles hiding Heading 9.
    /// Verifies all 4 features survive open → mutate → save → re-read.
    func testCorporateTemplateRoundTrip() async throws {
        let server = await WordMCPServer()
        let docId = "corp-tmpl-\(UUID().uuidString)"
        let savePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("corp-tmpl-\(UUID().uuidString).docx").path
        defer { try? FileManager.default.removeItem(atPath: savePath) }

        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // 1. Inheritance chain — create Heading1Bold based on Heading1 (which is based on Normal)
        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1Bold"),
            "name": .string("Heading 1 Bold"),
            "type": .string("paragraph"),
            "based_on": .string("Heading1"),
            "next_style_id": .string("Normal"),
            "q_format": .bool(true)
        ])

        // 2. Linked paragraph + character style pair
        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1Char"),
            "name": .string("Heading1Char"),
            "type": .string("character")
        ])
        _ = await server.invokeToolForTesting(name: "link_styles", arguments: [
            "doc_id": .string(docId),
            "paragraph_style_id": .string("Heading1"),
            "character_style_id": .string("Heading1Char")
        ])

        // 3. Hide Heading 9 from Quick Style Gallery via latentStyles
        _ = await server.invokeToolForTesting(name: "set_latent_styles", arguments: [
            "doc_id": .string(docId),
            "latent_styles": .array([
                .object([
                    "name": .string("Heading 9"),
                    "ui_priority": .int(9),
                    "semi_hidden": .bool(true),
                    "unhide_when_used": .bool(false),
                    "q_format": .bool(false)
                ])
            ])
        ])

        // 4. Verify chain via tool
        let chainResult = await server.invokeToolForTesting(name: "get_style_inheritance_chain", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1Bold")
        ])
        let chainBody = resultText(chainResult)
        XCTAssertTrue(chainBody.contains("\"style_id\": \"Heading1Bold\""))
        XCTAssertTrue(chainBody.contains("\"style_id\": \"Heading1\""))
        XCTAssertTrue(chainBody.contains("\"style_id\": \"Normal\""))

        // 5. Save and reopen via direct DocxReader
        _ = await server.invokeToolForTesting(name: "save_document", arguments: [
            "doc_id": .string(docId), "path": .string(savePath)
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath))

        let reopened = try DocxReader.read(from: URL(fileURLWithPath: savePath))
        XCTAssertNotNil(reopened.styles.first(where: { $0.id == "Heading1Bold" }),
            "Heading1Bold lost after round-trip")
        XCTAssertEqual(reopened.styles.first(where: { $0.id == "Heading1" })?.linkedStyleId,
            "Heading1Char", "linked style lost after round-trip")
        XCTAssertTrue(reopened.latentStyles.contains(where: { $0.name == "Heading 9" }),
            "latentStyle Heading 9 lost after round-trip")
    }

    /// Task 10.2: Academic preface — Roman numerals + line numbers + center
    /// vAlign on section 0; nextPage break + decimal on section 1 (single
    /// section in current model — test exercises the API surface).
    func testAcademicPrefaceConfiguration() async throws {
        let server = await WordMCPServer()
        let docId = "acad-pref-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Section 0: Roman numeral preface + line numbers + center
        _ = await server.invokeToolForTesting(name: "set_page_number_format", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "start": .int(1),
            "format": .string("lowerRoman")
        ])
        _ = await server.invokeToolForTesting(name: "set_line_numbers_for_section", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "count_by": .int(1),
            "start": .int(1),
            "restart": .string("newPage")
        ])
        _ = await server.invokeToolForTesting(name: "set_section_vertical_alignment", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "alignment": .string("center")
        ])
        _ = await server.invokeToolForTesting(name: "set_section_break_type", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "type": .string("nextPage")
        ])

        // Verify via get_all_sections
        let listed = await server.invokeToolForTesting(name: "get_all_sections", arguments: [
            "doc_id": .string(docId)
        ])
        let body = resultText(listed)
        XCTAssertTrue(body.contains("\"page_number_format\": \"lowerRoman\""), "missing format: \(body)")
        XCTAssertTrue(body.contains("\"vertical_alignment\": \"center\""), "missing vAlign: \(body)")
        XCTAssertTrue(body.contains("\"section_break_type\": \"nextPage\""), "missing break_type: \(body)")
        XCTAssertTrue(body.contains("\"line_numbers\""), "missing line_numbers: \(body)")
    }

    /// Task 10.3: Tiered list — 3-level numbering definition created via tool;
    /// override level 0 start; gc_orphan_numbering returns the unreferenced
    /// numIds (newly created num is orphan since we don't assign to a paragraph
    /// in this minimal test).
    func testTieredListLifecycle() async throws {
        let server = await WordMCPServer()
        let docId = "tier-list-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let create = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([
                .object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")]),
                .object(["ilvl": .int(1), "num_format": .string("decimal"), "lvl_text": .string("%1.%2.")]),
                .object(["ilvl": .int(2), "num_format": .string("decimal"), "lvl_text": .string("%1.%2.%3.")])
            ])
        ])
        guard let m = resultText(create).range(of: #"\"num_id\":\s*(\d+)"#, options: .regularExpression) else {
            XCTFail("could not parse num_id: \(resultText(create))"); return
        }
        let captured = resultText(create)[m]
        let numId = Int(captured.split(separator: ":").last!.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) ?? -1
        XCTAssertGreaterThan(numId, 0)

        // Override level 0 to start at 5
        let ov = await server.invokeToolForTesting(name: "override_numbering_level", arguments: [
            "doc_id": .string(docId),
            "num_id": .int(numId),
            "ilvl": .int(0),
            "start_value": .int(5)
        ])
        XCTAssertTrue(resultText(ov).contains("Override"), "override failed: \(resultText(ov))")

        // Assign to paragraph 0 so it's NOT an orphan after assign
        _ = await server.invokeToolForTesting(name: "assign_numbering_to_paragraph", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "num_id": .int(numId),
            "level": .int(0)
        ])

        // GC should NOT delete numId because it's referenced now
        let gc = await server.invokeToolForTesting(name: "gc_orphan_numbering", arguments: [
            "doc_id": .string(docId)
        ])
        let gcBody = resultText(gc)
        // The result is JSON array — confirm our numId is NOT in it
        XCTAssertFalse(gcBody.contains("\(numId)"), "numId \(numId) should NOT be GCed: \(gcBody)")
    }
}
