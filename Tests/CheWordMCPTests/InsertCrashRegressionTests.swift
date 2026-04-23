import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// Phase A of `che-word-mcp-insert-crash-autosave-fix` (#41 investigation).
///
/// Smoke test for the 3rd-sequential-insert crash repro. Per the SDD's
/// `.note` smoke test precedent (`Tests/MacDocCLITests/NotePDFConvertTests.swift`),
/// the fixture lives in `test-files/` (gitignored) and the test `XCTSkip`s
/// when missing — clean clones don't fail the suite.
///
/// To run locally:
/// 1. Place an document fixture at:
///    `mcp/che-word-mcp/test-files/insert-crash-fixture.docx`
/// 2. Place 3 small PNG fixtures at:
///    `mcp/che-word-mcp/test-files/fig-{a,b,c}.png`
/// 3. The fixture should contain the anchor strings `ANCHOR_A`, `ANCHOR_B`, `ANCHOR_C`
///    in 3 different sections (mimicking #41's cross-section anchor pattern).
/// 4. Run: `CHE_WORD_MCP_LOG_LEVEL=debug swift test --filter InsertCrashRegressionTests`
///
/// If the fixture is present and 3rd insert crashes:
/// - Capture `sample $MCP_PID` snapshot before issuing the 3rd request
/// - Capture Console.app crash report path post-crash
/// - Document findings as inline `// FINDINGS:` comment in this file
final class InsertCrashRegressionTests: XCTestCase {

    private var fixtureDir: URL {
        // Walk up from this test file to find mcp/che-word-mcp/test-files/.
        // Per `.note` precedent: hardcode the project-relative path.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CheWordMCPTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // mcp/che-word-mcp/
            .appendingPathComponent("test-files")
    }

    private func fixtureOrSkip(_ name: String, kind: String) throws -> String {
        let path = fixtureDir.appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(kind) fixture not found at \(path); see file header for setup instructions.")
        }
        return path
    }

    // MARK: - Phase A repro test

    func testThirdSequentialInsertImageDoesNotCrash() async throws {
        let docFixture = try fixtureOrSkip("insert-crash-fixture.docx", kind: "document")
        let figA = try fixtureOrSkip("fig-a.png", kind: "image")
        let figB = try fixtureOrSkip("fig-b.png", kind: "image")
        let figC = try fixtureOrSkip("fig-c.png", kind: "image")

        // Force debug logging so the trace is captured even if test runner env doesn't set the var.
        let server = await WordMCPServer(forceDebugLogging: true)

        _ = await server.invokeToolForTesting(
            name: "open_document",
            arguments: [
                "path": .string(docFixture),
                "doc_id": .string("crash-repro"),
                "track_changes": .bool(true)
            ]
        )

        // 3 sequential inserts targeting cross-section anchors (mimics #41 pattern).
        for (idx, (anchor, png)) in [("ANCHOR_A", figA), ("ANCHOR_B", figB), ("ANCHOR_C", figC)].enumerated() {
            let r = await server.invokeToolForTesting(
                name: "insert_image_from_path",
                arguments: [
                    "doc_id": .string("crash-repro"),
                    "path": .string(png),
                    "before_text": .string(anchor),
                    "width": .int(800),
                    "height": .int(600)
                ]
            )
            // Pre-fix: 3rd call expected to crash (process termination, not just isError).
            // Post-fix: all 3 calls should succeed.
            XCTAssertFalse(r.isError == true,
                           "Sequential insert #\(idx + 1) returned error: anchor=\(anchor); response=\(r)")
        }

        // Verify state integrity post-3-inserts.
        let imageCount = await server.imageCountForTesting("crash-repro")
        XCTAssertNotNil(imageCount, "Document still open after 3 inserts")

        // Inspect the structured log trace — confirms instrumentation captured the run.
        let events = await server.debugEventLogForTesting()
        let entryCount = events.filter { $0.event == "insertImageFromPath.entry" }.count
        XCTAssertEqual(entryCount, 3, "Expected 3 insertImageFromPath.entry events; got \(entryCount)")
    }

    // MARK: - Findings (populated when fixture available locally)
    //
    // FINDINGS:
    // (No document fixture available in this session. The crash repro is
    //  gated behind local fixture setup per the Phase A "investigation may
    //  not yield repro" non-goal in the SDD proposal. Phases B/C/D ship
    //  regardless. If a future session encounters the crash with a real
    //  fixture, capture sample/Console.app artifacts and document here.)
}
