import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase A of `che-word-mcp-insert-crash-autosave-fix` (closes #41 partially).
///
/// Spec: `openspec/changes/che-word-mcp-insert-crash-autosave-fix/specs/che-word-mcp-session-state-api/spec.md`
/// Requirement: "WordMCPServer logs structured diagnostics under CHE_WORD_MCP_LOG_LEVEL env var"
///
/// 2 spec scenarios:
/// 1. Logging disabled by default — no env var → silent
/// 2. Debug logging captures handler entry/exit — env var = "debug" → expected events
final class StructuredLoggingTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuredLogging-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func tempDocxPath(_ name: String = "test.docx") throws -> String {
        let url = tempDir.appendingPathComponent(name)
        var doc = WordDocument()
        doc.appendParagraph(Paragraph(text: "ORIGINAL"))
        try DocxWriter.write(doc, to: url)
        return url.path
    }

    // MARK: - Scenario 1: Logging disabled by default

    func testLoggingDisabledByDefault() async throws {
        // Pre-condition: no CHE_WORD_MCP_LOG_LEVEL set in this process env.
        // (Tests run with whatever env launched them; we don't control here.)
        // The implementation reads env once at actor init via a private snapshot.
        // To assert default-off behavior, we rely on the test runner NOT setting the env var.
        if ProcessInfo.processInfo.environment["CHE_WORD_MCP_LOG_LEVEL"] == "debug" {
            throw XCTSkip("Test runner has CHE_WORD_MCP_LOG_LEVEL=debug; cannot assert default-off here.")
        }

        let path = try tempDocxPath()
        let server = await WordMCPServer()

        // Verify the actor's debug log gate is OFF when env var is unset.
        let debugEnabled = await server.isDebugLoggingEnabledForTesting()
        XCTAssertFalse(debugEnabled,
                       "Debug logging SHALL be disabled when CHE_WORD_MCP_LOG_LEVEL is unset")

        // Smoke: invoke a tool to ensure no crash; we can't easily capture stderr from xctest
        // without forking, so the env-gate assertion above is the substantive check.
        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1")]
        )
    }

    // MARK: - Scenario 2: Debug logging captures handler entry/exit

    func testDebugLoggingCapturesHandlerEntryExit() async throws {
        // We can't easily reach into stderr from XCTest without subprocess wrapping.
        // Instead, the implementation exposes a per-actor in-memory ring buffer
        // (`debugEventLogForTesting`) when debug logging is on, capturing the same
        // event records emitted to stderr. Test seeds CHE_WORD_MCP_LOG_LEVEL=debug
        // via a per-test override on actor init (see `WordMCPServer(forceDebugLogging:)`
        // initializer used only in tests).

        let path = try tempDocxPath()
        let server = await WordMCPServer(forceDebugLogging: true)

        let debugEnabled = await server.isDebugLoggingEnabledForTesting()
        XCTAssertTrue(debugEnabled, "Debug logging SHALL be enabled when forceDebugLogging: true")

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: ["path": .string(path), "doc_id": .string("d1"), "autosave_every": .int(3)]
        )
        _ = await server.invokeToolForTesting(
            name: "insert_paragraph",
            arguments: ["doc_id": .string("d1"), "text": .string("MUT")]
        )

        let events = await server.debugEventLogForTesting()
        let eventNames = events.map { $0.event }

        XCTAssertTrue(eventNames.contains("storeDocument.entry"),
                      "Logged events SHALL include storeDocument.entry; got \(eventNames)")
        XCTAssertTrue(eventNames.contains("storeDocument.exit"),
                      "Logged events SHALL include storeDocument.exit; got \(eventNames)")
    }
}
