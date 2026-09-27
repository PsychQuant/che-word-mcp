import XCTest
import MCP
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#236 — `tools/list` had several spots outside the
/// OpenAPI 3.0 Schema Object subset that some MCP clients (e.g. a layer that
/// converts tools into Gemini `FunctionDeclaration`s) only accept a strict
/// subset of, and could reject a single tool — or the whole `tools/list`
/// response — over:
///
/// 1. 14 `"type": "array"` properties with no sibling `"items"` (OpenAPI
///    3.0.3 Schema Object: "items MUST be present if the type is array").
/// 2. `export_comment_threads_markdown.author_aliases` declaring
///    `additionalProperties` — valid OpenAPI 3.0, but not in Gemini's
///    `Schema` field list.
/// 3. `list_open_documents` declaring a top-level object schema with an
///    EMPTY `"properties": {}` — some transcoders reject this.
///
/// This is a guard test (scans the live `tools/list` schema output, not a
/// fixture-based behavior test), following the same shape as
/// `Issue138SchemaDescriptionAuditTests` — so any future tool that
/// reintroduces one of these three shapes fails a test immediately, without
/// needing to enumerate every tool by name again.
///
/// R2 (independent review F2) added a 5th check: `oneOf`/`anyOf`/`allOf`
/// schema composition keywords are valid JSON Schema / OpenAPI 3.0 but are
/// NOT in Gemini's `Schema` field list — the same subset concern as
/// `additionalProperties` above. `add_comment_reply`/`reply_to_comment`
/// (added in 4.6.0 #133, before this issue's scope) declared a top-level
/// `oneOf` enforcing "comment_id or parent_comment_id, exactly one"; that
/// was outside #236's original 14+1+1 audit and is fixed alongside this
/// test in the same change.
final class Issue236ToolSchemaOpenAPISubsetTests: XCTestCase {

    // MARK: - 1. Every `"type": "array"` schema node must declare `items`

    func testEveryArraySchemaDeclaresItems() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var violations: [String] = []
        for tool in tools {
            walkSchema(tool.inputSchema, path: tool.name) { path, node in
                guard case .object(let obj) = node, case .string("array")? = obj["type"] else { return }
                if obj["items"] == nil {
                    violations.append(path)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "tools/list has array schema(s) missing 'items' (OpenAPI 3.0 Schema Object requires items when type=array): \(violations.sorted())"
        )
    }

    // MARK: - 2. No schema anywhere declares `"type"` as a JSON array

    /// R8's fix for `insert_floating_image`'s old position parameters
    /// (splitting a `type: [integer, string]` union into two single-typed
    /// properties) already removed the only pre-existing offender; this
    /// locks that decision in so it can't quietly come back.
    func testNoSchemaDeclaresTypeAsAnArray() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var violations: [String] = []
        for tool in tools {
            walkSchema(tool.inputSchema, path: tool.name) { path, node in
                guard case .object(let obj) = node, let typeValue = obj["type"] else { return }
                if case .array = typeValue {
                    violations.append(path)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "tools/list has schema(s) with \"type\" as a JSON array (not valid OpenAPI 3.0 — type must be a single string): \(violations.sorted())"
        )
    }

    // MARK: - 3. `additionalProperties` is documented in prose, not declared as a keyword

    func testNoSchemaDeclaresAdditionalProperties() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var violations: [String] = []
        for tool in tools {
            walkSchema(tool.inputSchema, path: tool.name) { path, node in
                guard case .object(let obj) = node else { return }
                if obj["additionalProperties"] != nil {
                    violations.append(path)
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "tools/list has schema(s) declaring 'additionalProperties' — valid OpenAPI 3.0 but not in Gemini's Schema field list; document the free-form-key behavior in the property's description instead (#236): \(violations.sorted())"
        )
    }

    // MARK: - 4. No top-level tool schema declares an empty `properties: {}`

    func testNoToolDeclaresEmptyTopLevelProperties() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var violations: [String] = []
        for tool in tools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            if properties.isEmpty {
                violations.append(tool.name)
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "tool(s) declare a top-level 'properties': {} — omit the key entirely for a no-parameter tool instead, some client transcoders reject an explicit empty object (#236): \(violations.sorted())"
        )
    }

    // MARK: - 5. No schema anywhere declares oneOf / anyOf / allOf (R2, F2)

    func testNoSchemaDeclaresOneOfAnyOfOrAllOf() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()

        var violations: [String] = []
        for tool in tools {
            walkSchema(tool.inputSchema, path: tool.name) { path, node in
                guard case .object(let obj) = node else { return }
                for keyword in ["oneOf", "anyOf", "allOf"] where obj[keyword] != nil {
                    violations.append("\(path).\(keyword)")
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "tools/list has schema(s) declaring oneOf/anyOf/allOf — valid OpenAPI 3.0 schema composition but not in Gemini's Schema field list; enforce the constraint at runtime instead, keeping each alternative field individually optional in the schema (#236 F2): \(violations.sorted())"
        )
    }

    // MARK: - Helpers

    /// Walks a JSON-Schema-shaped `Value` tree, visiting every object node
    /// (the node itself, its `properties.*` children, and its `items`
    /// child), calling `visit` with a dotted path for diagnostics.
    private func walkSchema(_ node: Value, path: String, visit: (String, Value) -> Void) {
        visit(path, node)
        guard case .object(let obj) = node else { return }
        if case .object(let properties)? = obj["properties"] {
            for (key, child) in properties {
                walkSchema(child, path: "\(path).\(key)", visit: visit)
            }
        }
        if let items = obj["items"] {
            walkSchema(items, path: "\(path)[]", visit: visit)
        }
    }
}
