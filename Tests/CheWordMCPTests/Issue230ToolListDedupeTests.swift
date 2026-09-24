import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// #230: `set_header_row` was registered twice in `tools/list`, with two
/// mutually contradictory schemas. Swift's `switch` dispatch on the string
/// tool name only ever ran the first matching `case`, so the second schema
/// was dead: a caller who read it off `tools/list` and followed it got
/// silently different behavior from what the schema described.
///
/// This asserts the general invariant — `tools/list` must not contain two
/// entries with the same name for *any* tool, not just `set_header_row` —
/// so a future duplicate registration fails a test instead of shipping.
final class Issue230ToolListDedupeTests: XCTestCase {
    func testToolListHasNoDuplicateNames() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        XCTAssertFalse(tools.isEmpty, "sanity: tools/list should not be empty")

        var seen: [String: Int] = [:]
        for tool in tools {
            seen[tool.name, default: 0] += 1
        }
        let duplicates = seen.filter { $0.value > 1 }
        XCTAssertTrue(
            duplicates.isEmpty,
            "tools/list has duplicate tool names (name: count): \(duplicates)"
        )
    }

    /// Specific regression pin for #230: exactly one `set_header_row` entry,
    /// and its schema accepts both `row_index` and `row_count` (the two
    /// semantics the former duplicate schemas each offered) so a caller
    /// reading `tools/list` sees the merged contract, not a stale one.
    func testSetHeaderRowRegisteredExactlyOnceWithMergedSchema() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        let matches = tools.filter { $0.name == "set_header_row" }
        XCTAssertEqual(matches.count, 1, "set_header_row must be registered exactly once")

        guard let tool = matches.first else { return }
        let properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        XCTAssertNotNil(properties["row_index"], "merged schema must keep row_index")
        XCTAssertNotNil(properties["row_count"], "merged schema must keep row_count")

        let required = tool.inputSchema.objectValue?["required"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
        XCTAssertEqual(Set(required), ["doc_id", "table_index"],
                        "row_index/row_count must both stay optional so existing callers are unaffected")
    }
}
