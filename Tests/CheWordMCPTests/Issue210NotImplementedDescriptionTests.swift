import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// PsychQuant/che-word-mcp#210 — `tools/list` had gone half-honest: the three
/// watermark write-side tools (`insert_watermark` / `insert_image_watermark` /
/// `remove_watermark`, #201) say up front that they are not implemented, but
/// the five document-protection tools (`protect_document` /
/// `unprotect_document` / `set_document_password` / `remove_document_password`
/// / `restrict_editing_region`, #172) still advertised themselves as if they
/// worked — the runtime was honest (throws `ToolNotImplemented`), only the
/// pre-call advertisement was not. A caller who reads `tools/list` before
/// calling has no way to know which half of the surface is real without
/// trying every tool once.
///
/// This test enumerates every tool this server is KNOWN to implement as a
/// `ToolNotImplemented` stub (the list below is exactly the `tool:` values
/// passed to `ToolNotImplemented(...)` call sites in Server.swift — see the
/// `grep` in the doc comment on that struct) and pins that its `tools/list`
/// description discloses the fact before the tool is ever called. Adding a
/// ninth stub without updating this list is itself the sweep this issue asked
/// for — a new entry SHALL be added here in the same change that adds the
/// `ToolNotImplemented` throw.
final class Issue210NotImplementedDescriptionTests: XCTestCase {

    /// Every tool name that currently throws `ToolNotImplemented` at runtime.
    /// Kept as a literal list (not derived by scanning source) so this test
    /// fails loudly — not silently narrows its own coverage — if a future
    /// refactor changes how stubs are registered.
    /// #208: `insert_watermark` / `insert_image_watermark` / `remove_watermark`
    /// have been removed from this list — they no longer throw
    /// `ToolNotImplemented` (see `WatermarkToolsHonestFailureTests`, which now
    /// pins their real behavior).
    private static let notImplementedTools: Set<String> = [
        "protect_document",
        "unprotect_document",
        "set_document_password",
        "remove_document_password",
        "restrict_editing_region",
    ]

    func testEveryNotImplementedToolDisclosesItInItsDescription() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        for name in Self.notImplementedTools {
            guard let tool = byName[name] else {
                XCTFail("expected tools/list to contain '\(name)' (a known ToolNotImplemented stub) but it was not found")
                continue
            }
            let description = tool.description ?? ""
            XCTAssertTrue(
                description.contains("未實作") || description.lowercased().contains("not implemented"),
                "'\(name)' throws ToolNotImplemented at runtime but its tools/list description does not disclose that. Got: \(description)"
            )
            XCTAssertTrue(
                description.contains("isError"),
                "'\(name)' description SHALL say the call returns isError, not just that it is unimplemented. Got: \(description)"
            )
        }
    }

    /// A tool NOT in the stub list must not accidentally read like a stub —
    /// guards against the description text drifting onto tools that actually
    /// work (the inverse mistake).
    func testAnOrdinaryToolDoesNotClaimToBeUnimplemented() async throws {
        let server = await WordMCPServer()
        let tools = await server.toolsForTesting()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        guard let tool = byName["insert_paragraph"] else {
            XCTFail("expected tools/list to contain 'insert_paragraph'")
            return
        }
        let description = tool.description ?? ""
        XCTAssertFalse(description.contains("未實作"), "Got: \(description)")
    }
}
