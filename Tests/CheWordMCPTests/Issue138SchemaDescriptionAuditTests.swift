import XCTest
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#138 — 41 vague `paragraph_index` schema
/// descriptions ("段落索引（從 0 開始）", no family qualifier) were left over
/// from before #113's convention doc landed, plus the doc's own Tool
/// Inventory only covered a fraction of the paragraph_index-using tools.
/// This is a guard test, not a fixture-based behavior test: it greps the
/// live schema source so a future PR can't silently reintroduce the vague
/// phrasing for a new tool.
final class Issue138SchemaDescriptionAuditTests: XCTestCase {

    /// No `paragraph_index` (or sibling) schema description may say only
    /// "段落索引（從 0 開始）" with no family qualifier — every description
    /// must name which of the three families (`body.children` insertion
    /// index / top-level paragraph ordinal / `get_paragraphs` readback
    /// index) the parameter belongs to, per
    /// `docs/paragraph-index-conventions.md`.
    func testSchemaDescriptionsHaveNoVagueParaIndex() throws {
        let source = try String(contentsOf: repoRoot().appendingPathComponent("Sources/CheWordMCP/Server.swift"), encoding: .utf8)
        XCTAssertFalse(
            source.contains("\"段落索引（從 0 開始）\""),
            "found a bare, family-less 段落索引（從 0 開始） schema description — every paragraph_index-shaped description must name its index family (body.children insertion index / top-level paragraph ordinal / get_paragraphs readback index), see docs/paragraph-index-conventions.md"
        )
    }

    /// The doc's Tool Inventory table (#138 Phase 3) must additionally cover
    /// the field-code family and the advanced-paragraph-formatting stub
    /// tools that #113's original table left out.
    func testDocInventoryCoversFieldCodeAndStubFamilies() throws {
        let docs = try String(contentsOf: repoRoot().appendingPathComponent("docs/paragraph-index-conventions.md"), encoding: .utf8)
        XCTAssertTrue(docs.contains("insert_if_field"), "field-code family (insert_if_field / insert_calculation_field / insert_date_field / insert_page_field / insert_merge_field / insert_sequence_field) must be in the inventory")
        XCTAssertTrue(docs.contains("insert_content_control"))
        XCTAssertTrue(docs.contains("insert_tab_stop"), "stub tools that never persist paragraph_index-scoped state still need their bounds-check family documented")
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}
