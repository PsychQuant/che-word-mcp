import XCTest

/// PsychQuant/che-word-mcp#234 (R8) — `swift test`-gated entry point for
/// `scripts/fuzz-extreme-params.py`.
///
/// The fuzzer itself spawns ~1500 fresh `CheWordMCP` subprocesses (one per
/// probe) against a REAL compiled debug binary, which takes on the order of
/// 10-100 seconds and needs a binary to already be built — not something
/// every `swift test` invocation should pay for. This test is therefore
/// SKIPPED by default; it only actually runs the fuzzer when `RUN_FUZZ=1`
/// is set in the environment:
///
/// ```bash
/// swift build   # ensure .build/debug/CheWordMCP is up to date first
/// RUN_FUZZ=1 swift test --filter FuzzExtremeParamsGateTests
/// ```
///
/// When to run this: before any release that touches integer/number
/// parameter handling in `Server.swift`, and whenever a new tool or a new
/// integer/number parameter is added to an existing tool. R8 found 5 crash
/// sites that had survived #234's own manual `grep`-based audit — the
/// fuzzer is the mechanical way to check nothing regressed, so re-running
/// it (not re-deriving a manual audit) is the intended workflow.
final class FuzzExtremeParamsGateTests: XCTestCase {
    func testFuzzExtremeParamsFindsZeroCrashes() throws {
        guard ProcessInfo.processInfo.environment["RUN_FUZZ"] == "1" else {
            throw XCTSkip("RUN_FUZZ=1 not set — see this file's doc comment for how/when to run the fuzzer.")
        }

        // Locate the repo root (this file lives at
        // <repo>/Tests/CheWordMCPTests/FuzzExtremeParamsGateTests.swift) by
        // walking up until Package.swift is found, so this works whether
        // `swift test` was invoked from the repo root or elsewhere.
        var repoRoot = URL(fileURLWithPath: #filePath)
        while repoRoot.pathComponents.count > 1 {
            repoRoot = repoRoot.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        let script = repoRoot.appendingPathComponent("scripts/fuzz-extreme-params.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("scripts/fuzz-extreme-params.py not found under \(repoRoot.path) — repo layout unexpected.")
        }

        // The debug binary must already be built (`swift build`); this
        // test does not build it itself, to keep "does the fuzzer find
        // crashes" and "does the project compile" as separate concerns.
        let binary = repoRoot.appendingPathComponent(".build/debug/CheWordMCP")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("'.build/debug/CheWordMCP' not found — run `swift build` first.")
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, binary.path, workDir.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(
            process.terminationStatus, 0,
            "fuzz-extreme-params.py found crashes and/or timeouts (exit \(process.terminationStatus)):\n\(stdout)\n\(stderr)"
        )
    }
}
