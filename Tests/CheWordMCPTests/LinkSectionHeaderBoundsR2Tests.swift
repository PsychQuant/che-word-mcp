import XCTest
import MCP
@testable import CheWordMCP

/// R2 (LOW-MEDIUM, independent review of the #138/#139/#140/#141/#235
/// paragraph_index/range-validation batch): `insert_cross_reference` and
/// `set_text_direction` are the other two stub tools with an index-shaped
/// parameter — both got an upper bound so `Int.max` is rejected instead of
/// reported as success. `link_section_header_to_previous.section_index`
/// only checked the lower bound (`>= 1`), leaving it inconsistent with its
/// two siblings: a document has exactly one section in this library's
/// current single-section model (`doc.getAllSections()` always returns
/// exactly one `SectionInfo`), so any `section_index` above 1 does not name
/// a real section, yet was accepted and reported as a successful no-op.
final class LinkSectionHeaderBoundsR2Tests: XCTestCase {

    private func text(_ r: CallTool.Result) -> String {
        guard let first = r.content.first else { return "" }
        if case .text(let t, _, _) = first { return t }
        return ""
    }

    func testLinkSectionHeaderRejectsSectionIndexAboveTheOnlySection() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("r2sec")])

        let r = await server.invokeToolForTesting(
            name: "link_section_header_to_previous",
            arguments: ["doc_id": .string("r2sec"), "section_index": .int(9_223_372_036_854_775_807), "type": .string("default")]
        )
        XCTAssertEqual(r.isError, true, "section_index far beyond the document's 1 section (single-section model) must be rejected, not reported as a successful no-op; got: \(text(r))")
    }

    /// The one section that DOES exist (index 1) must still work — the new
    /// upper bound must not reject the legitimate no-op path.
    func testLinkSectionHeaderStillAcceptsTheOnlyValidSectionIndex() async throws {
        let server = await WordMCPServer()
        _ = await server.invokeToolForTesting(name: "create_document", arguments: ["doc_id": .string("r2sec2")])

        let r = await server.invokeToolForTesting(
            name: "link_section_header_to_previous",
            arguments: ["doc_id": .string("r2sec2"), "section_index": .int(1), "type": .string("default")]
        )
        XCTAssertNotEqual(r.isError, true, "section_index 1 is the only (and therefore valid) section; got: \(text(r))")
    }
}
