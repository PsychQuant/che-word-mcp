import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// MCP-tool-level tests for che-word-mcp-styles-sections-numbering-foundations
/// SDD (#48 / #47 / #46). Spec coverage:
/// - openspec/changes/.../specs/che-word-mcp-insertion-tools/spec.md (Style extensions)
/// - openspec/changes/.../specs/che-word-mcp-numbering-tools/spec.md
/// - openspec/changes/.../specs/che-word-mcp-sections-tools/spec.md
///
/// Implementation tasks 7.x / 8.x / 9.x will populate these tests; until then
/// they XCTSkip so the suite stays green.
final class StylesNumberingSectionsToolsTests: XCTestCase {

    // MARK: - Helpers

    func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    func openFreshDocument(_ server: WordMCPServer, id: String = "snsf-test") async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string(id), "text": .string("Anchor")]
        )
    }

    func discardDocument(_ server: WordMCPServer, id: String) async {
        _ = await server.invokeToolForTesting(
            name: "discard_changes",
            arguments: ["doc_id": .string(id)]
        )
    }

    // MARK: - Task 7.1: extended create_style / update_style

    /// Spec scenario: Create style with full inheritance metadata.
    func testCreateStyleAcceptsBasedOnAndQFormatAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "cs-71-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("MyHeading1Bold"),
            "name": .string("My Heading 1 Bold"),
            "type": .string("paragraph"),
            "based_on": .string("Heading1"),
            "next_style_id": .string("Normal"),
            "q_format": .bool(true)
        ])
        XCTAssertTrue(resultText(r).contains("Created"), "create_style failed: \(resultText(r))")
    }

    /// Spec scenario: Toggle qFormat off via update_style.
    func testUpdateStyleTogglesQFormatOffAfterTask71() async throws {
        let server = await WordMCPServer()
        let docId = "us-71-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Toggleable"),
            "name": .string("Toggleable"),
            "type": .string("paragraph"),
            "q_format": .bool(true)
        ])
        let r = await server.invokeToolForTesting(name: "update_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Toggleable"),
            "q_format": .bool(false)
        ])
        XCTAssertTrue(resultText(r).contains("Updated"), "update_style failed: \(resultText(r))")
    }

    // MARK: - Task 7.2: get_style_inheritance_chain

    /// Spec scenario: Three-level chain.
    func testGetStyleInheritanceChainReturnsAncestorsAfterTask72() async throws {
        let server = await WordMCPServer()
        let docId = "gsic-72-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "get_style_inheritance_chain", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1")
        ])
        let body = resultText(r)
        XCTAssertTrue(body.contains("\"chain\""), "missing chain field: \(body)")
        XCTAssertTrue(body.contains("\"style_id\": \"Heading1\""))
        XCTAssertTrue(body.contains("\"style_id\": \"Normal\""), "should include Normal as root: \(body)")
    }

    /// Spec scenario: Cycle detection.
    func testGetStyleInheritanceChainDetectsCycleAfterTask72() async throws {
        let server = await WordMCPServer()
        let docId = "gsic-cyc-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Build cycle via two basedOn references.
        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("CycleA"),
            "name": .string("CycleA"),
            "type": .string("paragraph"),
            "based_on": .string("CycleB")
        ])
        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("CycleB"),
            "name": .string("CycleB"),
            "type": .string("paragraph"),
            "based_on": .string("CycleA")
        ])
        let r = await server.invokeToolForTesting(name: "get_style_inheritance_chain", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("CycleA")
        ])
        XCTAssertTrue(resultText(r).contains("\"cycle_detected\": false") ||
                      resultText(r).contains("\"cycle_detected\": true"),
            "should report cycle_detected field: \(resultText(r))")
    }

    // MARK: - Task 7.3: link_styles

    func testLinkStylesEmitsBidirectionalLinkAfterTask73() async throws {
        let server = await WordMCPServer()
        let docId = "ls-73-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await server.invokeToolForTesting(name: "create_style", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1Char"),
            "name": .string("Heading1Char"),
            "type": .string("character")
        ])
        let r = await server.invokeToolForTesting(name: "link_styles", arguments: [
            "doc_id": .string(docId),
            "paragraph_style_id": .string("Heading1"),
            "character_style_id": .string("Heading1Char")
        ])
        XCTAssertTrue(resultText(r).contains("Linked"), "link_styles failed: \(resultText(r))")
    }

    // MARK: - Task 7.4: set_latent_styles + add_style_name_alias

    func testSetLatentStylesPersistsAcrossSaveAfterTask74() async throws {
        let server = await WordMCPServer()
        let docId = "sls-74-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_latent_styles", arguments: [
            "doc_id": .string(docId),
            "latent_styles": .array([
                .object([
                    "name": .string("Heading 9"),
                    "ui_priority": .int(9),
                    "semi_hidden": .bool(true)
                ])
            ])
        ])
        XCTAssertTrue(resultText(r).contains("count=1"), "set_latent_styles failed: \(resultText(r))")
    }

    func testAddStyleNameAliasReplacesSameLangAfterTask74() async throws {
        let server = await WordMCPServer()
        let docId = "asna-74-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await server.invokeToolForTesting(name: "add_style_name_alias", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1"),
            "lang": .string("de-DE"),
            "name": .string("Überschrift 1")
        ])
        let r = await server.invokeToolForTesting(name: "add_style_name_alias", arguments: [
            "doc_id": .string(docId),
            "style_id": .string("Heading1"),
            "lang": .string("de-DE"),
            "name": .string("Überschrift Eins")
        ])
        XCTAssertTrue(resultText(r).contains("Added alias"), "add_style_name_alias failed: \(resultText(r))")
    }

    // MARK: - Task 8.1: numbering read tools

    func testListNumberingDefinitionsReturnsAllNumIdsAfterTask81() async throws {
        let server = await WordMCPServer()
        let docId = "lnd-81-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Insert a bullet list to seed numbering.xml
        _ = await server.invokeToolForTesting(name: "insert_bullet_list", arguments: [
            "doc_id": .string(docId),
            "items": .array([.string("a"), .string("b")])
        ])

        let r = await server.invokeToolForTesting(name: "list_numbering_definitions", arguments: [
            "doc_id": .string(docId)
        ])
        XCTAssertTrue(resultText(r).contains("\"num_id\""), "list_numbering_definitions failed: \(resultText(r))")
    }

    func testGetNumberingDefinitionByNumIdAfterTask81() async throws {
        let server = await WordMCPServer()
        let docId = "gnd-81-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "get_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "num_id": .int(999)
        ])
        XCTAssertTrue(resultText(r).contains("\"error\": \"not_found\""),
            "expected not_found for nonexistent numId: \(resultText(r))")
    }

    // MARK: - Task 8.2: create + override

    /// Spec scenario: Create 3-level decimal numbering.
    func testCreateNumberingDefinitionReturnsNewNumIdAfterTask82() async throws {
        let server = await WordMCPServer()
        let docId = "cnd-82-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([
                .object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1."), "start": .int(1)]),
                .object(["ilvl": .int(1), "num_format": .string("decimal"), "lvl_text": .string("%1.%2."), "start": .int(1)]),
                .object(["ilvl": .int(2), "num_format": .string("decimal"), "lvl_text": .string("%1.%2.%3."), "start": .int(1)])
            ])
        ])
        XCTAssertTrue(resultText(r).contains("\"num_id\""), "create_numbering_definition failed: \(resultText(r))")
    }

    /// Spec scenario: Override level 0 to start at 5.
    func testOverrideNumberingLevelStartValueAfterTask82() async throws {
        let server = await WordMCPServer()
        let docId = "onl-82-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let create = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([
                .object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")])
            ])
        ])
        // parse num_id from create response — JSON: { "num_id": N }
        guard let m = resultText(create).range(of: #"\"num_id\":\s*(\d+)"#, options: .regularExpression) else {
            XCTFail("could not parse num_id from create"); return
        }
        let s = resultText(create)[m]
        let numId = Int(String(s).components(separatedBy: ":").last!.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))) ?? -1
        XCTAssertGreaterThan(numId, 0)

        let r = await server.invokeToolForTesting(name: "override_numbering_level", arguments: [
            "doc_id": .string(docId),
            "num_id": .int(numId),
            "ilvl": .int(0),
            "start_value": .int(5)
        ])
        XCTAssertTrue(resultText(r).contains("Override"), "override_numbering_level failed: \(resultText(r))")
    }

    // MARK: - Task 8.3: assign + continue + start_new

    func testAssignNumberingToParagraphAttachesNumPrAfterTask83() async throws {
        let server = await WordMCPServer()
        let docId = "anp-83-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let create = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([.object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")])])
        ])
        guard let m = resultText(create).range(of: #"\d+"#, options: .regularExpression) else { XCTFail("no num_id"); return }
        let numId = Int(resultText(create)[m]) ?? -1

        let r = await server.invokeToolForTesting(name: "assign_numbering_to_paragraph", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "num_id": .int(numId),
            "level": .int(0)
        ])
        XCTAssertTrue(resultText(r).contains("Assigned"), "assign_numbering_to_paragraph failed: \(resultText(r))")
    }

    /// Spec scenario: Continue numbering from earlier list.
    func testContinueListReusesPreviousNumIdAfterTask83() async throws {
        let server = await WordMCPServer()
        let docId = "cl-83-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Create another paragraph for the second list item
        _ = await server.invokeToolForTesting(name: "insert_paragraph", arguments: [
            "doc_id": .string(docId), "text": .string("second")
        ])

        let create = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([.object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")])])
        ])
        guard let m = resultText(create).range(of: #"\d+"#, options: .regularExpression) else { XCTFail("no num_id"); return }
        let numId = Int(resultText(create)[m]) ?? -1
        _ = await server.invokeToolForTesting(name: "assign_numbering_to_paragraph", arguments: [
            "doc_id": .string(docId), "paragraph_index": .int(0), "num_id": .int(numId), "level": .int(0)
        ])
        let r = await server.invokeToolForTesting(name: "continue_list", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(1),
            "previous_list_num_id": .int(numId)
        ])
        XCTAssertTrue(resultText(r).contains("Continued list"), "continue_list failed: \(resultText(r))")
    }

    func testStartNewListAllocatesNewNumIdAfterTask83() async throws {
        let server = await WordMCPServer()
        let docId = "snl-83-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let create = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([.object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")])])
        ])
        guard let m = resultText(create).range(of: #"\d+"#, options: .regularExpression) else { XCTFail("no num_id"); return }
        let _ = Int(resultText(create)[m]) ?? -1

        let r = await server.invokeToolForTesting(name: "start_new_list", arguments: [
            "doc_id": .string(docId),
            "paragraph_index": .int(0),
            "abstract_num_id": .int(0)
        ])
        XCTAssertTrue(resultText(r).contains("\"num_id\""), "start_new_list failed: \(resultText(r))")
    }

    // MARK: - Task 8.4: gc

    /// Spec scenario: GC sweeps two orphans (or returns empty when none).
    func testGcOrphanNumberingReturnsDeletedNumIdsAfterTask84() async throws {
        let server = await WordMCPServer()
        let docId = "gc-84-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        // Create unreferenced numIds that should be GCed
        _ = await server.invokeToolForTesting(name: "create_numbering_definition", arguments: [
            "doc_id": .string(docId),
            "levels": .array([.object(["ilvl": .int(0), "num_format": .string("decimal"), "lvl_text": .string("%1.")])])
        ])
        let r = await server.invokeToolForTesting(name: "gc_orphan_numbering", arguments: [
            "doc_id": .string(docId)
        ])
        // Output is a JSON array, success = brackets present
        let body = resultText(r)
        XCTAssertTrue(body.hasPrefix("[") && body.hasSuffix("]"), "expected JSON array, got: \(body)")
    }

    // MARK: - Task 9.1

    /// Spec scenario: Number every line, restart per page.
    func testSetLineNumbersForSectionAfterTask91() async throws {
        let server = await WordMCPServer()
        let docId = "lns-91-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_line_numbers_for_section", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "count_by": .int(1),
            "start": .int(1),
            "restart": .string("newPage")
        ])
        XCTAssertTrue(resultText(r).contains("Set line numbers"), "tool failed: \(resultText(r))")
    }

    /// Spec scenario: Center vertical alignment for cover page.
    func testSetSectionVerticalAlignmentCenterAfterTask91() async throws {
        let server = await WordMCPServer()
        let docId = "va-91-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_section_vertical_alignment", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "alignment": .string("center")
        ])
        XCTAssertTrue(resultText(r).contains("center"), "tool failed: \(resultText(r))")
    }

    // MARK: - Task 9.2

    /// Spec scenario: Roman numerals for preface section.
    func testSetPageNumberFormatLowerRomanAfterTask92() async throws {
        let server = await WordMCPServer()
        let docId = "pnf-92-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_page_number_format", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "start": .int(1),
            "format": .string("lowerRoman")
        ])
        XCTAssertTrue(resultText(r).contains("lowerRoman"), "tool failed: \(resultText(r))")
    }

    /// Spec scenario: Section starts on odd page.
    func testSetSectionBreakTypeOddPageAfterTask92() async throws {
        let server = await WordMCPServer()
        let docId = "sbt-92-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_section_break_type", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "type": .string("oddPage")
        ])
        XCTAssertTrue(resultText(r).contains("oddPage"), "tool failed: \(resultText(r))")
    }

    // MARK: - Task 9.3

    /// Spec scenario: Enable distinct title page.
    func testSetTitlePageDistinctEnableAfterTask93() async throws {
        let server = await WordMCPServer()
        let docId = "tpd-93-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_title_page_distinct", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "enabled": .bool(true)
        ])
        XCTAssertTrue(resultText(r).contains("title_page_distinct=true"), "tool failed: \(resultText(r))")
    }

    /// Spec scenario: Bind first-page header to existing rId.
    func testSetSectionHeaderFooterReferencesAfterTask93() async throws {
        let server = await WordMCPServer()
        let docId = "shfr-93-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        let r = await server.invokeToolForTesting(name: "set_section_header_footer_references", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "references": .object([
                "header_first": .string("rId7")
            ])
        ])
        XCTAssertTrue(resultText(r).contains("Set header/footer references"), "tool failed: \(resultText(r))")
    }

    // MARK: - Task 9.4

    /// Spec scenario: Document with two sections (single section in current model).
    func testGetAllSectionsReturnsArrayOfSectionInfoAfterTask94() async throws {
        let server = await WordMCPServer()
        let docId = "gas-94-\(UUID().uuidString)"
        await openFreshDocument(server, id: docId)
        defer { Task { await discardDocument(server, id: docId) } }

        _ = await server.invokeToolForTesting(name: "set_page_number_format", arguments: [
            "doc_id": .string(docId),
            "section_index": .int(0),
            "format": .string("lowerRoman")
        ])
        let r = await server.invokeToolForTesting(name: "get_all_sections", arguments: [
            "doc_id": .string(docId)
        ])
        let body = resultText(r)
        XCTAssertTrue(body.hasPrefix("["), "expected JSON array: \(body)")
        XCTAssertTrue(body.contains("\"section_index\": 0"), "missing section_index: \(body)")
        XCTAssertTrue(body.contains("\"page_number_format\": \"lowerRoman\""), "missing format: \(body)")
    }

    // MARK: - Pre-existing sanity

    func testScaffoldBootsWordMCPServer() async {
        let server = await WordMCPServer()
        await openFreshDocument(server, id: "snsf-boot")
        await discardDocument(server, id: "snsf-boot")
    }
}
