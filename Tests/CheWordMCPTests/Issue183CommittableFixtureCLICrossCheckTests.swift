import XCTest
import MCP
import OOXMLSwift
@testable import CheWordMCP

/// che-word-mcp#183 — the only test that drives BOTH binaries
/// (`ScriptPipelineParityTests.testCLICrossCheckAgainstMacdocBinary`) is
/// gated on BOTH `MACDOC_TEMPLATE_DIR` (a private JPA template) AND
/// `MACDOC_CLI_PATH` (the macdoc binary), so it never runs automatically —
/// "CLI and MCP faces agree on the same script" was, in practice,
/// unexercised in every ordinary `swift test` run, CI included.
///
/// This file implements the issue's own suggested direction — "A
/// committable minimal fixture would remove the MACDOC_TEMPLATE_DIR gate"
/// — WITHOUT touching `testCLICrossCheckAgainstMacdocBinary` itself: that
/// test's JPA-template-specific assertions (a stamped slot paragraph, the
/// documented coverage baseline) are worth keeping intact and untouched,
/// and restructuring 150 lines of gated, unrunnable-in-this-sandbox
/// integration logic to fall back conditionally is a correctness risk this
/// change chooses not to take. Instead: a SEPARATE, additive cross-check
/// against `ScriptPipelineFixtures.writeWordStyleFixture` (#168's
/// committable fixture), gated on `MACDOC_CLI_PATH` alone. Once #168's
/// fixture exists, the ONLY remaining external dependency for a real
/// cross-face byte-equal comparison is the CLI binary itself — no private
/// template required.
///
/// **Residue (explicitly not addressed here)**: #183's second complaint —
/// that no cross-face test covers the #180/#181 surfaces (the overwrite
/// gate, the failure-signal contract) — needs driving the macdoc CLI with
/// its `--force` flag and comparing termination status / stderr shape
/// against the MCP face's refusal, which requires verified knowledge of the
/// CLI's exact flag semantics this task did not have access to (the CLI
/// source lives in a separate repo, out of this task's scope). Left
/// DEFERRED; `ScriptPipelineParityTests.testExecuteScriptToolFailedVerificationIsAToolError`
/// and `testExecuteScriptToolRefusesExistingOutputWithoutOverwrite` cover
/// the MCP face alone, ungated, in the meantime.
final class Issue183CommittableFixtureCLICrossCheckTests: XCTestCase {

    private func resultText(_ result: CallTool.Result) -> String {
        guard let first = result.content.first else { return "" }
        if case .text(let text, _, _) = first { return text }
        return ""
    }

    private func makeScratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i183-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Spec scenario "CLI and MCP faces agree on the same script", against
    /// the committable #168 fixture instead of the private JPA template.
    /// Mirrors `ScriptPipelineParityTests.testCLICrossCheckAgainstMacdocBinary`
    /// parts (1) and (2) — script bytes identical, then executing both
    /// scripts yields byte-identical, Stage-B-equal-to-reference rebuilds —
    /// gated ONLY on `MACDOC_CLI_PATH`.
    func testCLIAndMCPFacesAgreeOnTheCommittableFixture() async throws {
        guard let cliPath = ProcessInfo.processInfo.environment["MACDOC_CLI_PATH"] else {
            throw XCTSkip("set MACDOC_CLI_PATH — this cross-check needs the macdoc binary "
                + "(no MACDOC_TEMPLATE_DIR needed: it uses the #168 committable fixture instead)")
        }
        let dir = try makeScratch()
        let fixture = dir.appendingPathComponent("fixture.docx")
        try ScriptPipelineFixtures.writeWordStyleFixture(to: fixture)

        // CLI surface: macdoc word reverse.
        let cliScript = dir.appendingPathComponent("cli.mdocx.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["word", "reverse", fixture.path, "--to-mdocx", cliScript.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        // Drain before waiting — a large combined stdout+stderr can fill the
        // pipe buffer and deadlock otherwise (same discipline
        // ScriptPipelineParityTests uses throughout its gated tests).
        let cliOutput = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "CLI export failed: \(cliOutput)")

        // MCP surface: export_script.
        let mcpScript = dir.appendingPathComponent("mcp.mdocx.swift")
        let server = await WordMCPServer()
        let export = await server.invokeToolForTesting(name: "export_script", arguments: [
            "source_path": .string(fixture.path),
            "output_path": .string(mcpScript.path),
        ])
        XCTAssertNotEqual(export.isError, true, resultText(export))

        // (1) Exported scripts byte-identical.
        let cliBytes = try Data(contentsOf: cliScript)
        let mcpBytes = try Data(contentsOf: mcpScript)
        XCTAssertEqual(cliBytes, mcpBytes,
                       "MCP and CLI must export byte-identical scripts (shared code path)")

        // (2) Executing both scripts yields byte-identical part sets,
        //     Stage-B equal to the reference — including the #168 fixture's
        //     injected typed-model-unmanaged raw-channel parts.
        let rebuiltFromMCP = dir.appendingPathComponent("rebuilt-mcp.docx")
        let rebuiltFromCLI = dir.appendingPathComponent("rebuilt-cli.docx")
        // Both scripts are executed through the SAME MCP execute_script
        // tool — `execute_script` just interprets a `.mdocx.swift` file
        // regardless of which face exported it, so the render/rebuild step
        // needs no separate CLI invocation (matching
        // `testCLICrossCheckAgainstMacdocBinary`'s exact pattern: only the
        // export/reverse direction is asked of the CLI binary).
        let execMCP = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(mcpScript.path),
            "output_path": .string(rebuiltFromMCP.path),
            "verify_byte_equal_against": .string(fixture.path),
        ])
        XCTAssertNotEqual(execMCP.isError, true, resultText(execMCP))
        XCTAssertTrue(resultText(execMCP).contains("\"verified\":true"), resultText(execMCP))
        let execCLI = await server.invokeToolForTesting(name: "execute_script", arguments: [
            "script_path": .string(cliScript.path),
            "output_path": .string(rebuiltFromCLI.path),
        ])
        XCTAssertNotEqual(execCLI.isError, true, resultText(execCLI))

        let partsMCP = try RawPartChannel.readAllParts(from: rebuiltFromMCP)
        let partsCLI = try RawPartChannel.readAllParts(from: rebuiltFromCLI)
        XCTAssertTrue(PartFidelity.stageB(reference: partsMCP, rebuilt: partsCLI),
                      "rebuilds from the two surfaces' scripts must be byte-identical")
        XCTAssertEqual(partsCLI["word/theme/theme1.xml"], partsMCP["word/theme/theme1.xml"],
                       "the injected theme part must survive both surfaces' rebuilds identically")
        XCTAssertEqual(partsCLI["word/webSettings.xml"], partsMCP["word/webSettings.xml"],
                       "the injected webSettings part must survive both surfaces' rebuilds identically")
    }
}
