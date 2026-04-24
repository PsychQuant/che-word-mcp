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
///
/// Implementation tasks 5.1–8.1 will populate these tests.
final class ContentControlToolsTests: XCTestCase {

    // MARK: - Helpers

    private func tempURL(_ suffix: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cheword-cc-\(suffix).docx")
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        switch first {
        case .text(let text, _, _):
            return text
        default:
            return ""
        }
    }

    /// Opens a freshly-created empty document in the server and returns its doc_id.
    private func openFreshDocument(_ server: WordMCPServer, id: String = "cc-test") async {
        _ = await server.invokeToolForTesting(
            name: "create_document",
            arguments: ["doc_id": .string(id)]
        )
    }

    // MARK: - Task 5.1 placeholder

    /// See: `list_content_controls enumerates SDTs in a document`.
    /// Enabled by task 5.1.
    func testListContentControlsReturnsInsertedSDTsAfterTask51() async throws {
        throw XCTSkip("pending task 5.1: list_content_controls")
    }

    // MARK: - Task 5.2 placeholder

    /// See: `get_content_control fetches a single SDT by id, tag, or alias`.
    /// Enabled by task 5.2.
    func testGetContentControlByTagReturnsMatchAfterTask52() async throws {
        throw XCTSkip("pending task 5.2: get_content_control")
    }

    // MARK: - Task 5.3 placeholder

    /// See: `list_repeating_section_items enumerates items of a repeating section SDT`.
    /// Enabled by task 5.3.
    func testListRepeatingSectionItemsAfterTask53() async throws {
        throw XCTSkip("pending task 5.3: list_repeating_section_items")
    }

    // MARK: - Task 6.1 placeholder

    /// See: `update_content_control_text modifies plain-text SDT content`.
    /// Enabled by task 6.1.
    func testUpdateContentControlTextOnPlainTextSucceedsAfterTask61() async throws {
        throw XCTSkip("pending task 6.1: update_content_control_text")
    }

    // MARK: - Task 6.2 placeholder

    /// See: `replace_content_control_content replaces rich-text SDT content`.
    /// Enabled by task 6.2.
    func testReplaceContentControlContentWithParagraphAfterTask62() async throws {
        throw XCTSkip("pending task 6.2: replace_content_control_content")
    }

    // MARK: - Task 6.3 placeholder

    /// See: `delete_content_control removes SDT with optional content preservation`.
    /// Enabled by task 6.3.
    func testDeleteContentControlKeepContentTrueAfterTask63() async throws {
        throw XCTSkip("pending task 6.3: delete_content_control")
    }

    // MARK: - Task 6.4 placeholder

    /// See: `update_repeating_section_item modifies a single item's content`.
    /// Enabled by task 6.4.
    func testUpdateRepeatingSectionItemAfterTask64() async throws {
        throw XCTSkip("pending task 6.4: update_repeating_section_item")
    }

    // MARK: - Task 7.1 placeholder

    /// See: `insert_content_control accepts advanced SDT types and extended args`.
    /// Enabled by task 7.1.
    func testInsertContentControlDropdownWithListItemsAfterTask71() async throws {
        throw XCTSkip("pending task 7.1: insert_content_control extensions")
    }

    // MARK: - Task 7.2 placeholder

    /// See: `insert_repeating_section supports allow_insert_delete_sections arg`.
    /// Enabled by task 7.2.
    func testInsertRepeatingSectionAllowInsertDeleteFalseAfterTask72() async throws {
        throw XCTSkip("pending task 7.2: allow_insert_delete_sections arg")
    }

    // MARK: - Task 8.1 placeholder

    /// See: `list_custom_xml_parts returns empty stub`.
    /// Enabled by task 8.1.
    func testListCustomXmlPartsReturnsEmptyArrayAfterTask81() async throws {
        throw XCTSkip("pending task 8.1: list_custom_xml_parts stub")
    }

    // MARK: - Pre-existing sanity: scaffold compiles and server boots

    /// Sanity check that the test scaffold itself compiles and the MCP
    /// server can be instantiated. Independent of any task 5.1+ work.
    func testScaffoldBootsWordMCPServer() async {
        let server = await WordMCPServer()
        await openFreshDocument(server, id: "scaffold-boot")
        // Immediately discard the document so we don't trip the dirty-doc close guard.
        _ = await server.invokeToolForTesting(
            name: "discard_changes",
            arguments: ["doc_id": .string("scaffold-boot")]
        )
    }
}
